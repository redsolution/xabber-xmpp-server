%%%-------------------------------------------------------------------
%%% File    : mod_notify.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%  Purpose : Extended event notifications
%%% Created : 18 March 2024 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% @copyright (C) 2024, Redsolution OÜ

%%%-------------------------------------------------------------------
-module(mod_notify).
-author('ilya.kalashnikov@redsolution.com').
-behaviour(gen_server).
-behaviour(gen_mod).

-compile([{parse_transform, ejabberd_sql_pt}]).


-define(FALLBACK, <<"This notification type is not supported by your client.">>).

%% gen_mod
-export([start/2, stop/1, reload/3, mod_opt_type/1,
  depends/2, mod_options/1]).

%% gen_server
-export([init/1, handle_call/3, handle_cast/2,
  handle_info/2, terminate/2, code_change/3]).

%% API
-export([send_notification/4, send_notification/5]).

%% Hooks
-export([process_iq/1]).

-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").

-record(state, {
  server_host =  <<>> :: binary(),
  hosts = [] :: [binary()],
  policy = <<>> :: binary()}
).

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
  fun(L) -> lists:map(fun iolist_to_binary/1, L) end;
mod_opt_type(policy) -> fun iolist_to_binary/1.

mod_options(_Host) ->
  [{host, <<"notifications.@HOST@">>},
    {hosts, []},
    {policy, <<"roster">>}
  ].

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host, Opts]) ->
  process_flag(trap_exit, true),
  Hosts = gen_mod:get_opt_hosts(Host, Opts),
  Policy = binary_to_atom(gen_mod:get_opt(policy, Opts), latin1),
  lists:foreach(
    fun(H) ->
      ejabberd_router:register_route(H, Host),
      ets:insert(server_components, {H, ?NS_XEN, Host, ?MODULE})
    end, Hosts),
  gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_XEN, ?MODULE, process_iq),
  {ok, #state{hosts = Hosts, policy = Policy, server_host= Host}}.

handle_call(get_state, _From, State) ->
  {reply, State, State};
handle_call(stop, _From, State) ->
  {stop, normal, ok, State};
handle_call(Request, From, State) ->
  ?ERROR_MSG("Got unexpected request from ~p: ~p", [From, Request]),
  {noreply, State}.

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

handle_info({route, #iq{lang = Lang} = Packet}, State) ->
  try xmpp:decode_els(Packet) of
    IQ ->
      case process_iq(IQ, State) of
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

terminate(_Reason, #state{hosts = Hosts, server_host = Host}) ->
  gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_XEN),
  lists:foreach(fun ejabberd_router:unregister_route/1, Hosts).

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%--------------------------------------------------------------------
%% Hooks.
%%--------------------------------------------------------------------
-spec process_iq(iq()) -> iq().
process_iq(#iq{to = To} = IQ) ->
  Proc = gen_mod:get_module_proc(To#jid.lserver, ?MODULE),
  State = gen_server:call(Proc, get_state),
  process_iq(IQ, State).

%%--------------------------------------------------------------------
%% API.
%%--------------------------------------------------------------------
-spec send_notification(binary(), jid(), jid(), xmpp_element() | xmlel()) -> ok.
send_notification(ServerHost , To, OFrom, Payload) ->
  send_notification(ServerHost , To, OFrom, Payload, xmpp:mk_text(?FALLBACK)).

-spec send_notification(binary(), jid(), jid(), xmpp_element() | xmlel(), binary()) -> ok.
send_notification(ServerHost , To, OFrom, Payload, Fallback) when is_binary(Fallback) ->
  send_notification(ServerHost , To, OFrom, Payload, xmpp:mk_text(Fallback));
send_notification(ServerHost , To, OFrom, #message{} = Payload, Fallback) ->
  Forwarded = #forwarded{sub_els = [Payload]},
  send_notification(ServerHost , To, OFrom, Forwarded, Fallback);
send_notification(ServerHost , To, OFrom, Payload, Fallback) ->
  Proc = gen_mod:get_module_proc(ServerHost, ?MODULE),
  State = gen_server:call(Proc, get_state),
  From = jid:make(hd(State#state.hosts)),
  Notification = #xen_notification{sub_els =  [xmpp:encode(Payload)]},
  notify(From, To, OFrom, Notification, Fallback).

%%--------------------------------------------------------------------
%% Internal functions.
%%--------------------------------------------------------------------

-spec process_iq(iq(), any()) -> iq() | none.
process_iq(#iq{type = get, sub_els = [#disco_info{}]} = IQ, _State) ->
  Info =  #disco_info{identities = [
    #identity{category = <<"component">>, type = <<"notification">>,
      name = <<"Notification service">>}],
    features = [?NS_DISCO_INFO, ?NS_DISCO_ITEMS, ?NS_XEN]
  },
  xmpp:make_iq_result(IQ,Info);
process_iq(#iq{type = get, sub_els = [#disco_items{}]} = IQ, _State) ->
  xmpp:make_iq_result(IQ, #disco_items{});
process_iq(#iq{type = set, from = From,
  sub_els = [#xen_prefs{default = Default, jids = JIDs}]} = IQ, _State) ->
  case ejabberd_router:is_my_host(From#jid.lserver) of
    true ->
      write_prefs(From, Default, JIDs),
      xmpp:make_iq_result(IQ);
    _ ->
      xmpp:make_error(IQ, xmpp:err_not_allowed())
  end;
process_iq(#iq{type = get, from = From, sub_els = [#xen_prefs{}]} = IQ, State) ->
  Policy = State#state.policy,
  case ejabberd_router:is_my_host(From#jid.lserver) of
    true ->
      get_prefs_result(IQ, Policy);
    _ ->
      xmpp:make_error(IQ, xmpp:err_not_allowed())
  end;
process_iq(#iq{lang = Lang, type = set, sub_els = [#notify{
  notification = #xen_notification{sub_els = []}}]} = IQ, _State) ->
  Txt = <<"Missing notification payload">>,
  xmpp:make_error(IQ, xmpp:err_bad_request(Txt, Lang));
process_iq(#iq{type = set, from = From,
  sub_els = [#notify{notification = Notification, fallback = Fallback,
    addresses = #addresses{list = [#address{type = to, jid = To}]}}]} = IQ, State) ->
  Policy = State#state.policy,
  OFrom = jid:remove_resource(From),
  case is_allowed(OFrom, To, Policy) of
    true ->
      MyHost = jid:make(hd(State#state.hosts)),
      notify(MyHost, To, OFrom, Notification, Fallback),
      xmpp:make_iq_result(IQ);
    _ ->
      xmpp:make_error(IQ, xmpp:err_not_allowed())
  end;
process_iq(#iq{type = set, sub_els = [#notify{}]} = IQ, _State) ->
  xmpp:make_error(IQ, xmpp:err_bad_request());
process_iq(#iq{type = set, sub_els = [#xabber_retract_message{}]} = IQ, _State) ->
  send_retract_result(IQ),
  none;
process_iq(IQ,_) ->
  xmpp:make_error(IQ, xmpp:err_bad_request()).

is_allowed(OFrom, To, Policy) ->
  case is_allowed(OFrom, To) of
    false ->
      check_prefs(OFrom, To, Policy);
    _ -> true
  end.


is_allowed(#jid{luser = U, lserver = S}, #jid{luser = U, lserver = S}) ->
  true;
is_allowed(#jid{luser = <<>>, lserver = S}, #jid{lserver = S}) ->
  lists:member(S, ejabberd_config:get_myhosts());
is_allowed(_, _) -> false.

check_prefs(OFrom, To, Policy) ->
  {LUser, LServer, _} = jid:tolower(To),
  Prefs = get_prefs(LUser, LServer),
  case lists:keyfind(OFrom, #xen_jid.jid, Prefs) of
    #xen_jid{rule = R} -> rule_to_bool(R);
    _ ->
      case get_default(LUser, LServer, Policy) of
        roster ->
          check_subscription(LUser, LServer, OFrom);
        DP -> rule_to_bool(DP)
      end
  end.

check_subscription(LUser, LServer, JID) ->
  {Sub, _, _} = mod_roster:get_jid_info(<<>>, LUser, LServer, JID),
  case Sub of
    both -> true;
    from -> true;
    _ -> false
  end.

send_retract_result(#iq{from = #jid{lserver = LServer}} = IQ) ->
  case ejabberd_router:is_my_host(LServer) of
    true ->
      Proc = gen_mod:get_module_proc(LServer, mod_retract),
      gen_server:cast(Proc, xmpp:make_iq_result(IQ));
    _ ->
      ok
  end.

get_prefs_result(IQ, Policy) ->
  {LUser, LServer, _} = jid:tolower(IQ#iq.from),
  Default = get_default(LUser, LServer, Policy),
  JIDs = get_prefs(LUser, LServer),
  R = #xen_prefs{default = Default, jids = JIDs},
  xmpp:make_iq_result(IQ, R).

get_prefs(LUser, LServer) ->
  sql_get_prefs(LUser, LServer).

write_prefs(User, Default, JIDs) ->
  Items = parse_jids(JIDs),
  sql_write_prefs(User#jid.luser, User#jid.lserver, Default, Items).

get_default(LUser, LServer, Policy) ->
  case sql_get_policy(LUser, LServer) of
    undefined -> Policy;
    P -> P
  end.

parse_jids(JIDs) ->
  lists:map(
    fun(#xen_jid{rule = R, jid = J})->
      {atom_to_binary(R, latin1), jid:to_string(jid:remove_resource(J))}
    end, JIDs).

-spec notify(jid(), jid(), jid(), xmlel(), <<>>) -> ok.
notify(From, To, OFrom, Notification, []) ->
  notify(From, To, OFrom, Notification, xmpp:mk_text(?FALLBACK));
notify(From, To, OFrom, Notification, Fallback) ->
  OFromAddr = #addresses{list = [
    #address{type = 'ofrom', jid = OFrom}
  ]},
  SubEls = [Notification, OFromAddr, #hint{type = 'store'}],
  Msg = #message{from = From, to =To,
    body = Fallback,
    type = chat, id = randoms:get_string(),
    sub_els = SubEls},
  ejabberd_router:route(Msg).

rule_to_bool(allow) -> true;
rule_to_bool(_) -> false.

%%--------------------------------------------------------------------
%% SQL functions.
%%--------------------------------------------------------------------
sql_get_prefs(LUser, LServer) ->
  Query = ?SQL("select @(jid)s, @(rule)s from xen_prefs where "
  " username=%(LUser)s and %(LServer)H"),
  case ejabberd_sql:sql_query(LServer, Query) of
    {selected, List} ->
      [#xen_jid{rule = binary_to_atom(R, latin1),
        jid = jid:from_string(J)} || {J, R} <- List];
    _ ->
      []
  end.

sql_write_prefs(LUser, LServer, Default, Items) ->
  case Default of
    undefined -> ok;
    remove -> sql_rm_policy(LUser, LServer);
    _ -> sql_set_policy(LUser, LServer, Default)
  end,
  sql_write_rules(LUser, LServer, Items).

sql_get_policy(LUser, LServer) ->
  Query = ?SQL("select @(policy)s from xen_policy where "
  " username=%(LUser)s and %(LServer)H"),
  case ejabberd_sql:sql_query(LServer, Query) of
    {selected, [{R}]} -> binary_to_atom(R, latin1);
    _ -> undefined
  end.

sql_set_policy(LUser, LServer, Default) when is_atom(Default)->
  sql_set_policy(LUser, LServer, atom_to_binary(Default, latin1));
sql_set_policy(LUser, LServer, Default) ->
  case ?SQL_UPSERT(LServer, "xen_policy",
    [ "!username=%(LUser)s",
      "!server_host=%(LServer)s",
      "policy=%(Default)s"]) of
    ok -> ok;
    _Err ->
      {error, db_failure}
  end.


sql_rm_policy(LUser, LServer) ->
  case ejabberd_sql:sql_query(LServer,
    ?SQL("delete from xen_policy where "
    " username=%(LUser)s and %(LServer)H")) of
    ok -> ok;
    _Err ->
      {error, db_failure}
  end.

sql_write_rules(LUser, LServer, Items) ->
  F = fun() ->
    lists:foreach(fun({<<"remove">>, SJID}) ->
      ejabberd_sql:sql_query_t(
        ?SQL("delete from xen_prefs where "
        " username=%(LUser)s and jid=%(SJID)s and %(LServer)H"));
      ({Rule, SJID})->
      ?SQL_UPSERT_T("xen_prefs",
        [ "!username=%(LUser)s",
          "!server_host=%(LServer)s",
          "!jid=%(SJID)s",
          "rule=%(Rule)s"])
                  end, Items)
      end,
  ejabberd_sql:sql_transaction(LServer, F).
