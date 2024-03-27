%%%-------------------------------------------------------------------
%%% File    : mod_favorites.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%  Purpose : Saving favorite messages.
%%% Created : 16 Feb 2024 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% @copyright (C) 2024, Redsolution OÜ

%%%-------------------------------------------------------------------
-module(mod_favorites).
-author('ilya.kalashnikov@redsolution.com').
-behaviour(gen_server).
-behaviour(gen_mod).

-define(NS_FAVORITES, <<"urn:xabber:favorites:0">>).

%% API
-export([start/2, stop/1, reload/3]).

-export([init/1, handle_call/3, handle_cast/2,
  handle_info/2, terminate/2, code_change/3,
  mod_opt_type/1, depends/2, mod_options/1]).

-include("logger.hrl").
-include("xmpp.hrl").

-record(state, {hosts = [] :: [binary()]}).

%%====================================================================
%% gen_mod API
%%====================================================================
start(Host, Opts) ->
  gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
  gen_mod:stop_child(?MODULE, Host).

reload(Host, NewOpts, OldOpts) ->
  Proc = gen_mod:get_module_proc(Host, ?MODULE),
  gen_server:cast(Proc, {reload, Host, NewOpts, OldOpts}).

depends(_Host, _Opts) ->
  [].

mod_opt_type(host) -> fun iolist_to_binary/1;
mod_opt_type(hosts) ->
  fun(L) -> lists:map(fun iolist_to_binary/1, L) end.

mod_options(_Host) ->
  [{host, <<"favorites.@HOST@">>}, {hosts, []}].

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([Host, Opts]) ->
  process_flag(trap_exit, true),
  Hosts = gen_mod:get_opt_hosts(Host, Opts),
  lists:foreach(
    fun(H) ->
      ets:insert(server_components, {H, ?NS_FAVORITES, Host, ?MODULE}),
      ejabberd_router:register_route(H, Host)
    end, Hosts),
  {ok, #state{hosts = Hosts}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({check_router, Domain}, _From, State) ->
  {reply, lists:member(Domain, State#state.hosts), State};
handle_call(stop, _From, State) ->
  {stop, normal, ok, State};
handle_call(Request, From, State) ->
  ?ERROR_MSG("Got unexpected request from ~p: ~p", [From, Request]),
  {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({reload, Host, NewOpts, OldOpts}, State) ->
  NewMyHosts = gen_mod:get_opt_hosts(Host, NewOpts),
  OldMyHosts = gen_mod:get_opt_hosts(Host, OldOpts),
  lists:foreach(
    fun(H) ->
      ejabberd_router:unregister_route(H)
    end, OldMyHosts -- NewMyHosts),
  lists:foreach(
    fun(H) ->
      ejabberd_router:register_route(H, Host)
    end, NewMyHosts -- OldMyHosts),
  {noreply, State#state{hosts = NewMyHosts}};
handle_cast(Msg, State) ->
  ?WARNING_MSG("unexpected cast: ~p", [Msg]),
  {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------

handle_info({route, #iq{lang = Lang} = Packet}, State) ->
  try xmpp:decode_els(Packet) of
    IQ ->
      case process_iq(IQ) of
        none -> ok;
        Reply ->
          ejabberd_router:route(Reply)
      end,
      {noreply, State}
  catch _:{xmpp_codec, Why} ->
    Txt = xmpp:io_format_error(Why),
    Err = xmpp:err_bad_request(Txt, Lang),
    ejabberd_router:route_error(Packet, Err),
    {noreply, State}
  end;
handle_info({route, #message{}}, State) ->
  {noreply, State};
handle_info(Info, State) ->
  ?ERROR_MSG("Got unexpected info: ~p", [Info]),
  {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, #state{hosts = Hosts}) ->
  lists:foreach(fun ejabberd_router:unregister_route/1, Hosts).

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%--------------------------------------------------------------------
%% Hooks.
%%--------------------------------------------------------------------


%%--------------------------------------------------------------------
%% Internal functions.
%%--------------------------------------------------------------------

-spec process_iq(iq()) -> iq() | none.
process_iq(#iq{type = get, sub_els = [#disco_info{}]} = IQ) ->
  Info =  #disco_info{identities = [
    #identity{category = <<"component">>, type = <<"archive">>,
      name = <<"Saved messages">>}],
    features = [?NS_DISCO_INFO, ?NS_DISCO_ITEMS, ?NS_FAVORITES]
  },
  xmpp:make_iq_result(IQ,Info);
process_iq(#iq{type = get, sub_els = [#disco_items{}]} = IQ) ->
  xmpp:make_iq_result(IQ, #disco_items{});
process_iq(#iq{type = set, sub_els = [#xabber_replace{}]} = IQ) ->
  send_retract_result(IQ),
  none;
process_iq(#iq{type = set, sub_els = [#xabber_retract_message{}]} = IQ) ->
  send_retract_result(IQ),
  none;
process_iq(_) ->
  none.

send_retract_result(#iq{from = #jid{lserver = LServer}} = IQ) ->
  case ejabberd_router:is_my_host(LServer) of
    true ->
      Proc = gen_mod:get_module_proc(LServer, mod_retract),
      gen_server:cast(Proc, xmpp:make_iq_result(IQ));
    _ ->
      ok
  end.
