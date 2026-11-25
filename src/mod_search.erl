%%%-------------------------------------------------------------------
%%% Search index connection.
%%%-------------------------------------------------------------------
-module(mod_search).
-compile([{parse_transform, ejabberd_sql_pt}]).

-behaviour(gen_server).
-behaviour(gen_mod).

-export([start/2, stop/1, reload/3, depends/2, mod_options/1, mod_opt_type/1]).
-export([status/1, create_index/1, load_index/1, rebuild_index/1, load_status/1]).
-export([store_mam_message/6]).
-export([replace_message/4, retract_message/4, retract_all_messages/3, retract_archive/3]).
-export([process_iq/1, disco_sm_features/5]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("logger.hrl").
-include("ejabberd_commands.hrl").
-include("ejabberd_sql_pt.hrl").
-include("xmpp.hrl").

-define(CONNECT_TIMEOUT, 5000).
-define(RECONNECT_INTERVAL, 5000).
-define(LOAD_BATCH_SIZE, 1000).

-record(state, {host, opts, conn = undefined, monitor = undefined,
                reconnect_timer = undefined, load = idle}).

start(Host, Opts) ->
    case gen_mod:start_child(?MODULE, Host, Opts) of
        {ok, _Pid} = Result ->
            ejabberd_commands:register_commands(commands()),
            ejabberd_hooks:add(store_mam_message, Host, ?MODULE, store_mam_message, 100),
            ejabberd_hooks:add(replace_message, Host, ?MODULE, replace_message, 100),
            ejabberd_hooks:add(retract_message, Host, ?MODULE, retract_message, 100),
            ejabberd_hooks:add(retract_all_messages, Host, ?MODULE, retract_all_messages, 100),
            ejabberd_hooks:add(retract_archive, Host, ?MODULE, retract_archive, 100),
            ejabberd_hooks:add(disco_sm_features, Host, ?MODULE, disco_sm_features, 50),
            gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_MAM_2_SEARCH, ?MODULE, process_iq),
            Result;
        Error -> Error
    end.

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_MAM_2_SEARCH),
    ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE, disco_sm_features, 50),
    ejabberd_hooks:delete(store_mam_message, Host, ?MODULE, store_mam_message, 100),
    ejabberd_hooks:delete(replace_message, Host, ?MODULE, replace_message, 100),
    ejabberd_hooks:delete(retract_message, Host, ?MODULE, retract_message, 100),
    ejabberd_hooks:delete(retract_all_messages, Host, ?MODULE, retract_all_messages, 100),
    ejabberd_hooks:delete(retract_archive, Host, ?MODULE, retract_archive, 100),
    case gen_mod:is_loaded_elsewhere(Host, ?MODULE) of
        false -> ejabberd_commands:unregister_commands(commands());
        true -> ok
    end,
    gen_mod:stop_child(?MODULE, Host).

reload(Host, NewOpts, _OldOpts) ->
    gen_server:cast(gen_mod:get_module_proc(Host, ?MODULE), {reload, NewOpts}).

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [{server, <<"127.0.0.1">>},
     {port, 9306},
     {username, <<>>},
     {password, <<>>},
     {index, <<"xabber_messages">>},
     {morphology, <<"stem_enru">>}].

mod_opt_type(server) ->
    fun(V) when is_binary(V), V /= <<>> -> V end;
mod_opt_type(port) ->
    fun(V) when is_integer(V), V > 0, V =< 65535 -> V end;
mod_opt_type(username) ->
    fun(V) when is_binary(V) -> V end;
mod_opt_type(password) ->
    fun(V) when is_binary(V) -> V end;
mod_opt_type(index) ->
    fun(V) when is_binary(V) ->
        case re:run(V, <<"^[a-zA-Z_][a-zA-Z0-9_]*$">>, [{capture, none}]) of
            match -> V
        end
    end;
mod_opt_type(morphology) ->
    fun(V) when is_binary(V) -> V end.

commands() ->
    [#ejabberd_commands{name = search_create_index, tags = [search],
                        desc = "Create the configured search index",
                        module = ?MODULE, function = create_index,
                        args = [{host, binary}], result = {res, restuple}},
     #ejabberd_commands{name = search_load_index, tags = [search],
                        desc = "Load the host archive into the search index",
                        module = ?MODULE, function = load_index,
                        args = [{host, binary}], result = {res, restuple}},
     #ejabberd_commands{name = search_load_status, tags = [search],
                        desc = "Show the status of archive indexing",
                        module = ?MODULE, function = load_status,
                        args = [{host, binary}], result = {res, restuple}},
     #ejabberd_commands{name = search_rebuild_index, tags = [search],
                        desc = "Rebuild the host archive search index",
                        module = ?MODULE, function = rebuild_index,
                        args = [{host, binary}], result = {res, restuple}}].

status(Host) ->
    gen_server:call(gen_mod:get_module_proc(Host, ?MODULE), status).

create_index(Host) ->
    call(Host, create_index).

load_index(Host) ->
    call(Host, load_index).

rebuild_index(Host) ->
    call(Host, rebuild_index).

load_status(Host) ->
    call(Host, load_status).

disco_sm_features(empty, From, To, Node, Lang) ->
    disco_sm_features({result, []}, From, To, Node, Lang);
disco_sm_features({result, Features}, #jid{luser = User, lserver = Server},
                  #jid{luser = User, lserver = Server}, <<>>, _Lang) ->
    {result, [?NS_MAM_2_SEARCH | Features]};
disco_sm_features(Acc, _From, _To, _Node, _Lang) ->
    Acc.

process_iq(#iq{type = set, from = #jid{luser = User, lserver = Server},
               to = #jid{luser = User, lserver = Server},
               sub_els = [#mam_search_query{}]} = IQ) ->
    spawn(fun() -> ejabberd_router:route(process_search_iq(IQ)) end),
    ignore;
process_iq(#iq{lang = Lang} = IQ) ->
    xmpp:make_error(IQ, xmpp:err_bad_request(<<"Invalid search request">>, Lang)).

process_search_iq(#iq{from = #jid{luser = User, lserver = Server} = From,
                      to = To, lang = Lang,
                      sub_els = [#mam_search_query{id = QueryID, xdata = XData, rsm = RSM}]} = IQ) ->
    case parse_search_query(XData, RSM) of
        unsupported_full_jid ->
            xmpp:make_error(IQ, xmpp:err_feature_not_implemented(<<"Full JID search is not supported">>, Lang));
        {ok, Text, Opts} ->
            case proplists:get_value('conversation-type', Opts, ?NS_XABBER_CHAT) of
                ?NS_XABBER_CHAT ->
                    case search_iq_page(Server, User, Text, Opts) of
                        {ok, IDs, Complete} ->
                            case sql_search_archive(Server, User, IDs) of
                                {ok, Rows} ->
                                    send_search_results(IQ, Rows, IDs, Complete, From, To, QueryID);
                                {error, _} -> xmpp:make_error(IQ, xmpp:err_internal_server_error())
                            end;
                        {error, not_found} -> xmpp:make_error(IQ, xmpp:err_item_not_found());
                        {error, _} -> xmpp:make_error(IQ, xmpp:err_internal_server_error())
                    end;
                _ -> send_search_results(IQ, [], [], true, From, To, QueryID)
            end;
        error -> xmpp:make_error(IQ, xmpp:err_bad_request(<<"Invalid search form or RSM">>, Lang))
    end.

search_iq_page(Server, User, Text, Opts) ->
    case proplists:get_value(cursor, Opts) of
        undefined -> call(Server, {search_iq, User, Text, Opts});
        Cursor ->
            case sql_search_archive(Server, User, [Cursor]) of
                {ok, []} -> {error, not_found};
                {ok, _} -> call(Server, {search_iq, User, Text, Opts});
                {error, _} = Error -> Error
            end
    end.

parse_search_query(#xdata{type = submit, fields = Fields}, RSM) ->
    try
        #xdata_field{values = [?NS_MAM_2_SEARCH]} = lists:keyfind(<<"FORM_TYPE">>, #xdata_field.var, Fields),
        Form = mam_search_query:decode(Fields, [?NS_MAM_2_SEARCH], [<<"text">>]),
        Text = proplists:get_value(text, Form),
        true = is_binary(Text) andalso Text /= <<>>,
        {Limit, Direction, Cursor} = search_rsm(RSM),
        Start = proplists:get_value(start, Form),
        End = proplists:get_value('end', Form),
        StartUS = search_timestamp(Start),
        EndUS = search_timestamp(End),
        true = StartUS =:= undefined orelse EndUS =:= undefined orelse StartUS =< EndUS,
        Peer = proplists:get_value(with, Form),
        case Peer of
            #jid{lresource = Resource} when Resource /= <<>> -> unsupported_full_jid;
            _ -> {ok, Text, [{limit, Limit}, {direction, Direction}, {cursor, Cursor},
                             {peer, Peer}, {start, StartUS}, {'end', EndUS},
                             {'conversation-type', proplists:get_value('conversation-type', Form, ?NS_XABBER_CHAT)}]}
        end
    catch _:_ -> error
    end;
parse_search_query(_, _) -> error.

search_timestamp(undefined) -> undefined;
search_timestamp(Timestamp) -> misc:now_to_usec(Timestamp).

search_rsm(undefined) -> {50, asc, undefined};
search_rsm(#rsm_set{index = undefined, max = Max0, before = Before, 'after' = After}) ->
    Max = case Max0 of undefined -> 50; N when is_integer(N), N >= 0 -> min(N, 100) end,
    case {Before, After} of
        {undefined, undefined} -> {Max, asc, undefined};
        {<<>>, undefined} -> {Max, desc, undefined};
        {ID, undefined} when is_binary(ID) -> {Max, desc, search_cursor(ID)};
        {undefined, ID} when is_binary(ID), ID /= <<>> -> {Max, asc, search_cursor(ID)}
    end.

search_cursor(ID) ->
    Value = binary_to_integer(ID),
    true = Value >= 0,
    Value.

send_search_results(IQ, Rows, _IDs, Complete, From, To, QueryID) ->
    Archive = jid:remove_resource(To),
    Messages = lists:filtermap(fun({Timestamp, XML, Peer, Kind, Nick}) ->
        ID = integer_to_binary(Timestamp),
        case mod_mam_sql:make_archive_el(ID, XML, Peer, Kind, Nick, chat, From, Archive) of
            {ok, Forwarded} ->
                Packet = #message{from = To, to = From,
                    sub_els = [#mam_result{xmlns = ?NS_MAM_2, id = ID,
                                           queryid = QueryID, sub_els = [Forwarded]}]},
                {true, {ID, Packet}};
            _ -> false
        end
    end, Rows),
    lists:foreach(fun({_ID, Packet}) -> ejabberd_router:route(Packet) end, Messages),
    RSM = case Messages of
        [] -> #rsm_set{};
        _ ->
            {First, _} = hd(Messages),
            {Last, _} = lists:last(Messages),
            #rsm_set{first = #rsm_first{data = First}, last = Last}
    end,
    xmpp:make_iq_result(IQ, #mam_fin{xmlns = ?NS_MAM_2, id = QueryID,
                                     rsm = RSM, complete = Complete}).

call(Host, Request) ->
    try gen_server:call(gen_mod:get_module_proc(Host, ?MODULE), Request, 30000)
    catch exit:_ -> {error, <<"Search module unavailable">>}
    end.

store_mam_message(#message{meta = #{stanza_id := Timestamp}} = Pkt,
                  User, Server, Peer, chat, _Direction) ->
    case xmpp:get_meta(Pkt, conversation_type, undefined) of
        Type when Type == undefined; Type == ?NS_XABBER_CHAT ->
            gen_server:cast(gen_mod:get_module_proc(Server, ?MODULE),
                            {store_message, User, Server, Peer, Timestamp, Pkt});
        _ -> ok
    end,
    Pkt;
store_mam_message(Acc, _User, _Server, _Peer, _Type, _Direction) ->
    Acc.

replace_message(User, Server, ?NS_XABBER_CHAT,
                #replace{conversation = Peer, sid = #stanza_id{id = ID},
                         replacement = #replacement_message{message = Pkt}}) ->
    Timestamp = binary_to_integer(ID),
    gen_server:cast(gen_mod:get_module_proc(Server, ?MODULE),
                    {replace_message, User, Server, Peer, Timestamp, Pkt});
replace_message(_User, _Server, _Type, _Event) ->
    ok.

retract_message(_User, Server, ?NS_XABBER_CHAT,
                #retract_message{sid = #stanza_id{id = ID}}) ->
    gen_server:cast(gen_mod:get_module_proc(Server, ?MODULE),
                    {retract_message, Server, binary_to_integer(ID)});
retract_message(_User, _Server, _Type, _Event) ->
    ok.

retract_all_messages(User, Server, #retract_all{conversation = Peer, type = Type})
  when Type == <<>>; Type == ?NS_XABBER_CHAT ->
    BarePeer = jid:encode(jid:tolower(jid:remove_resource(Peer))),
    gen_server:cast(gen_mod:get_module_proc(Server, ?MODULE),
                    {retract_all_messages, User, Server, BarePeer});
retract_all_messages(_User, _Server, _Event) ->
    ok.

retract_archive(User, Server, #retract_archive{}) ->
    gen_server:cast(gen_mod:get_module_proc(Server, ?MODULE),
                    {retract_archive, User, Server}).

init([Host, Opts]) ->
    self() ! connect,
    {ok, #state{host = Host, opts = Opts}}.

handle_call(status, _From, #state{conn = Conn} = State) ->
    Status = case Conn of undefined -> disconnected; _ -> connected end,
    {reply, Status, State};
handle_call({search_iq, _, _, _}, _From, #state{conn = undefined} = State) ->
    {reply, {error, disconnected}, State};
handle_call({search_iq, User, Text, Opts}, _From,
            #state{host = Host, conn = Conn, opts = ModuleOpts} = State) ->
    Limit = proplists:get_value(limit, Opts),
    Direction = proplists:get_value(direction, Opts),
    PeerFilter = case proplists:get_value(peer, Opts) of
        undefined -> [];
        Peer -> [<<" AND bare_peer=">>, quote(jid:encode(jid:tolower(jid:remove_resource(Peer))))]
    end,
    CursorFilter = case {Direction, proplists:get_value(cursor, Opts)} of
        {_, undefined} -> [];
        {asc, Cursor} -> [<<" AND `timestamp` > ">>, integer_to_binary(Cursor)];
        {desc, Cursor} -> [<<" AND `timestamp` < ">>, integer_to_binary(Cursor)]
    end,
    DateFilters = [search_date_filter(<<" >= ">>, proplists:get_value(start, Opts)),
                   search_date_filter(<<" <= ">>, proplists:get_value('end', Opts))],
    Order = case Direction of asc -> <<" ASC">>; desc -> <<" DESC">> end,
    Query = [<<"SELECT `timestamp` FROM ">>, gen_mod:get_opt(index, ModuleOpts),
             <<" WHERE MATCH(">>, quote(Text), <<") AND server_host=">>, quote(Host),
             <<" AND username=">>, quote(User), PeerFilter, CursorFilter, DateFilters,
             <<" ORDER BY `timestamp`">>, Order, <<" LIMIT ">>, integer_to_binary(Limit + 1)],
    Reply = case p1_mysql_conn:squery(Conn, Query, self(), [{timeout, 10000}]) of
        {data, Result} ->
            AllIDs = [binary_to_integer(iolist_to_binary(ID)) || [ID] <- p1_mysql:get_result_rows(Result)],
            Page = lists:sublist(AllIDs, Limit),
            IDs = case Direction of asc -> Page; desc -> lists:reverse(Page) end,
            {ok, IDs, length(AllIDs) =< Limit};
        Error -> {error, Error}
    end,
    {reply, Reply, State};
handle_call(create_index, _From, #state{conn = undefined} = State) ->
    {reply, {error, <<"Search index is disconnected">>}, State};
handle_call(create_index, _From, #state{conn = Conn, opts = Opts, host = Host} = State) ->
    Index = gen_mod:get_opt(index, Opts),
    Morphology = gen_mod:get_opt(morphology, Opts),
    Query = [<<"CREATE TABLE IF NOT EXISTS ">>, Index,
             <<" (server_host string, username string, `timestamp` bigint, "
               "bare_peer string, txt text) morphology=">>, quote(Morphology)],
    Reply = case p1_mysql_conn:squery(Conn, Query, self(), [{timeout, 10000}]) of
        {updated, _} -> {ok, <<"Search index created or already exists">>};
        Error ->
            ?ERROR_MSG("Failed to create search index for ~s: ~p", [Host, Error]),
            {error, <<"Failed to create search index">>}
    end,
    {reply, Reply, State};
handle_call(load_index, _From, #state{load = {running, _, _, _}} = State) ->
    {reply, {error, <<"Archive indexing is already running">>}, State};
handle_call(load_index, _From, #state{conn = undefined} = State) ->
    {reply, {error, <<"Search index is disconnected">>}, State};
handle_call(load_index, _From, #state{host = Host} = State) ->
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() -> load_archive(Parent, Host) end),
    {reply, {ok, <<"Archive indexing started">>},
     State#state{load = {running, Pid, Ref, 0}}};
handle_call(rebuild_index, _From, #state{load = {running, _, _, _}} = State) ->
    {reply, {error, <<"Archive indexing is already running">>}, State};
handle_call(rebuild_index, _From, #state{conn = undefined} = State) ->
    {reply, {error, <<"Search index is disconnected">>}, State};
handle_call(rebuild_index, _From, #state{host = Host} = State) ->
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() -> rebuild_archive(Parent, Host) end),
    {reply, {ok, <<"Archive index rebuild started">>},
     State#state{load = {running, Pid, Ref, 0}}};
handle_call({clear_index, _Host}, {Pid, _},
            #state{conn = Conn, opts = Opts, load = {running, Pid, _, _}} = State)
  when Conn =/= undefined ->
    Query = [<<"DELETE FROM ">>, gen_mod:get_opt(index, Opts),
             <<" WHERE server_host=">>, quote(State#state.host)],
    Reply = case p1_mysql_conn:squery(Conn, Query, self(), [{timeout, 300000}]) of
        {updated, _} -> ok;
        Error -> {error, Error}
    end,
    {reply, Reply, State};
handle_call(load_status, _From, #state{load = Load} = State) ->
    {reply, {ok, load_status_text(Load)}, State};
handle_call({load_batch, _Rows}, _From, #state{conn = undefined} = State) ->
    {reply, {error, disconnected}, State};
handle_call({load_batch, Rows}, {Pid, _},
            #state{conn = Conn, opts = Opts, load = {running, Pid, _, _}} = State) ->
    Query = load_batch_query(gen_mod:get_opt(index, Opts), Rows),
    Reply = case p1_mysql_conn:squery(Conn, Query, self(), [{timeout, 30000}]) of
        {updated, _} -> ok;
        Error -> {error, Error}
    end,
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

handle_cast({reload, Opts}, State) ->
    State1 = disconnect(stop_load(State)),
    self() ! connect,
    {noreply, State1#state{opts = Opts}};
handle_cast({store_message, User, Server, Peer, Timestamp, Pkt}, State) ->
    case mod_xabber_entity:is_group(User, Server) of
        true -> ok;
        false -> store_message(User, Server, Peer, Timestamp, Pkt, State)
    end,
    {noreply, State};
handle_cast({replace_message, User, Server, Peer, Timestamp, Pkt}, State) ->
    case fxml:get_subtag_cdata(xmpp:encode(Pkt), <<"body">>) of
        <<>> -> delete_index(Server, [<<"id=">>, integer_to_binary(document_id(Server, Timestamp))], State);
        _ -> store_message(User, Server, Peer, Timestamp, Pkt, State)
    end,
    {noreply, State};
handle_cast({retract_message, Server, Timestamp}, State) ->
    delete_index(Server, [<<"id=">>, integer_to_binary(document_id(Server, Timestamp))], State),
    {noreply, State};
handle_cast({retract_all_messages, User, Server, Peer}, State) ->
    delete_index(Server, [<<"server_host=">>, quote(Server), <<" AND username=">>, quote(User),
                          <<" AND bare_peer=">>, quote(Peer)], State),
    {noreply, State};
handle_cast({retract_archive, User, Server}, State) ->
    delete_index(Server, [<<"server_host=">>, quote(Server), <<" AND username=">>, quote(User)], State),
    {noreply, State};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(connect, #state{conn = undefined, opts = Opts, host = Host} = State) ->
    Server = binary_to_list(gen_mod:get_opt(server, Opts)),
    Port = gen_mod:get_opt(port, Opts),
    User = binary_to_list(gen_mod:get_opt(username, Opts)),
    Password = binary_to_list(gen_mod:get_opt(password, Opts)),
    LogFun = fun(_, _, _) -> ok end,
    try p1_mysql_conn:start(Server, Port, User, Password, "manticore",
                            ?CONNECT_TIMEOUT, LogFun) of
        {ok, Conn} ->
            Monitor = erlang:monitor(process, Conn),
            ?INFO_MSG("Search index connected for ~s", [Host]),
            {noreply, State#state{conn = Conn, monitor = Monitor}};
        Error ->
            ?WARNING_MSG("Search index connection failed for ~s: ~p", [Host, Error]),
            {noreply, schedule_reconnect(State)}
    catch Class:Reason ->
        ?WARNING_MSG("Search index connection failed for ~s: ~p:~p",
                     [Host, Class, Reason]),
        {noreply, schedule_reconnect(State)}
    end;
handle_info(connect, State) ->
    {noreply, State};
handle_info({'DOWN', Monitor, process, Conn, Reason},
            #state{conn = Conn, monitor = Monitor, host = Host} = State) ->
    ?WARNING_MSG("Search index disconnected for ~s: ~p", [Host, Reason]),
    {noreply, schedule_reconnect(State#state{conn = undefined, monitor = undefined})};
handle_info({load_progress, Pid, Count}, #state{load = {running, Pid, Ref, _}} = State) ->
    {noreply, State#state{load = {running, Pid, Ref, Count}}};
handle_info({load_complete, Pid, Count}, #state{load = {running, Pid, Ref, _}} = State) ->
    erlang:demonitor(Ref, [flush]),
    {noreply, State#state{load = {complete, Count}}};
handle_info({'DOWN', Ref, process, Pid, Reason},
            #state{load = {running, Pid, Ref, Count}, host = Host} = State) ->
    ?ERROR_MSG("Archive indexing failed for ~s: ~p", [Host, Reason]),
    {noreply, State#state{load = {failed, Count}}};
handle_info({timeout, Timer, reconnect}, #state{reconnect_timer = Timer} = State) ->
    self() ! connect,
    {noreply, State#state{reconnect_timer = undefined}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    case State#state.load of
        {running, Pid, _, _} -> exit(Pid, shutdown);
        _ -> ok
    end,
    disconnect(State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

schedule_reconnect(#state{reconnect_timer = undefined} = State) ->
    Timer = erlang:start_timer(?RECONNECT_INTERVAL, self(), reconnect),
    State#state{reconnect_timer = Timer};
schedule_reconnect(State) ->
    State.

disconnect(#state{conn = Conn, monitor = Monitor, reconnect_timer = Timer} = State) ->
    case Timer of undefined -> ok; _ -> erlang:cancel_timer(Timer) end,
    case Monitor of undefined -> ok; _ -> erlang:demonitor(Monitor, [flush]) end,
    case Conn of undefined -> ok; _ -> p1_mysql_conn:stop(Conn) end,
    State#state{conn = undefined, monitor = undefined, reconnect_timer = undefined}.

stop_load(#state{load = {running, Pid, Ref, Count}} = State) ->
    exit(Pid, shutdown),
    erlang:demonitor(Ref, [flush]),
    State#state{load = {failed, Count}};
stop_load(State) ->
    State.

load_status_text(idle) -> <<"Not started">>;
load_status_text({running, _, _, Count}) ->
    iolist_to_binary(io_lib:format("Running: ~B messages", [Count]));
load_status_text({complete, Count}) ->
    iolist_to_binary(io_lib:format("Complete: ~B messages", [Count]));
load_status_text({failed, Count}) ->
    iolist_to_binary(io_lib:format("Failed after ~B messages; see server log", [Count])).

load_archive(Parent, Host) ->
    load_archive(Parent, Host, 0, 0).

rebuild_archive(Parent, Host) ->
    case gen_server:call(Parent, {clear_index, Host}, 310000) of
        ok -> load_archive(Parent, Host);
        Error -> error({index_clear_failed, Error})
    end.

load_archive(Parent, Host, After, Count) ->
    case sql_archive_batch(Host, After) of
        {ok, []} ->
            Parent ! {load_complete, self(), Count};
        {ok, Rows} ->
            case gen_server:call(Parent, {load_batch, Rows}, 45000) of
                ok ->
                    NewCount = Count + length(Rows),
                    Parent ! {load_progress, self(), NewCount},
                    {Last, _, _, _, _} = lists:last(Rows),
                    load_archive(Parent, Host, Last, NewCount);
                Error -> error({index_write_failed, Error})
            end;
        {error, Reason} -> error({archive_read_failed, Reason})
    end.

sql_archive_batch(Host, After) ->
    ChatType = ?NS_XABBER_CHAT,
    Limit = ?LOAD_BATCH_SIZE,
    case ejabberd_sql:sql_query(Host, ?SQL(
        "select @(a.timestamp)d, @(a.server_host)s, @(a.username)s, "
        "@(a.bare_peer)s, @(a.txt)s from archive a "
        "where a.server_host=%(Host)s and a.timestamp > %(After)d "
        "and a.conversation_type=%(ChatType)s "
        "and a.txt is not null and a.txt != '' "
        "and a.username not in (select g.localpart from groupchats g "
        "where g.server_host=%(Host)s) "
        "order by a.timestamp limit %(Limit)d")) of
        {selected, Rows} -> {ok, Rows};
        Error -> {error, Error}
    end.

search_date_filter(_Op, undefined) -> [];
search_date_filter(Op, Timestamp) -> [<<" AND `timestamp`">>, Op, integer_to_binary(Timestamp)].

sql_search_archive(_Host, _User, []) -> {ok, []};
sql_search_archive(Host, User, IDs) ->
    Array = iolist_to_binary([<<"{">>, lists:join(<<",">>, [integer_to_binary(ID) || ID <- IDs]), <<"}">>]),
    case ejabberd_sql:sql_query(Host, ?SQL(
        "select @(timestamp)d, @(xml)s, @(peer)s, @(kind)s, @(nick)s from archive "
        "where server_host=%(Host)s and username=%(User)s "
        "and timestamp=ANY(CAST(CAST(%(Array)s AS text) AS bigint[])) order by timestamp")) of
        {selected, Rows} -> {ok, Rows};
        Error -> {error, Error}
    end.

load_batch_query(Index, Rows) ->
    Values = lists:join(<<",">>, [index_row(Row) || Row <- Rows]),
    [<<"REPLACE INTO ">>, Index,
     <<" (id, server_host, username, `timestamp`, bare_peer, txt) VALUES ">>, Values].

store_message(User, Server, Peer, Timestamp, Pkt, #state{conn = Conn, opts = Opts}) ->
    Text = fxml:get_subtag_cdata(xmpp:encode(Pkt), <<"body">>),
    case {Text, Conn} of
        {<<>>, _} -> ok;
        {_, undefined} ->
            ?WARNING_MSG("Cannot index message for ~s: search index disconnected", [Server]);
        _ ->
            BarePeer = jid:encode(jid:tolower(jid:remove_resource(Peer))),
            Query = load_batch_query(gen_mod:get_opt(index, Opts),
                                     [{Timestamp, Server, User, BarePeer, Text}]),
            case p1_mysql_conn:squery(Conn, Query, self(), [{timeout, 10000}]) of
                {updated, _} -> ok;
                Error -> ?ERROR_MSG("Failed to index message for ~s: ~p", [Server, Error])
            end
    end.

delete_index(Server, _Where, #state{conn = undefined}) ->
    ?WARNING_MSG("Cannot delete indexed messages for ~s: search index disconnected", [Server]);
delete_index(Server, Where, #state{conn = Conn, opts = Opts}) ->
    Query = [<<"DELETE FROM ">>, gen_mod:get_opt(index, Opts), <<" WHERE ">>, Where],
    case p1_mysql_conn:squery(Conn, Query, self(), [{timeout, 10000}]) of
        {updated, _} -> ok;
        Error -> ?ERROR_MSG("Failed to delete indexed messages for ~s: ~p", [Server, Error])
    end.

index_row({Timestamp, Host, User, Peer, Text}) ->
    ID = document_id(Host, Timestamp),
    [<<"(">>, integer_to_binary(ID), <<",">>, quote(Host), <<",">>, quote(User),
     <<",">>, integer_to_binary(Timestamp), <<",">>, quote(Peer), <<",">>,
     quote(Text), <<")">>].

document_id(Host, Timestamp) ->
    Size = byte_size(Host),
    <<Value:64/unsigned, _/binary>> =
        crypto:hash(sha256, <<Size:32/unsigned, Host/binary, Timestamp:64/unsigned>>),
    1 + (Value rem 16#7fffffffffffffff).

quote(Value) ->
    Escaped = << <<(escape_char(Char))/binary>> || <<Char>> <= Value >>,
    [<<"'">>, Escaped, <<"'">>].

escape_char($') -> <<"\\'">>;
escape_char($\\) -> <<"\\\\">>;
escape_char(Char) -> <<Char>>.
