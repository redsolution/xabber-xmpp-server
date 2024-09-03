%%%-------------------------------------------------------------------
%%% File    : mod_http_iq.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : Make "IQ" query via HTTP
%%% Created : 13. Apr. 2021 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%%
%%%
%%% xabberserver, Copyright (C) 2007-2021   Redsolution OÜ
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------
-module(mod_http_iq).
-author('ilya.kalashnikov@redsolution.com').

-behaviour(gen_server).
-behaviour(gen_mod).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

%% gen_mod/supervisor callbacks.
-export([start/2,
  stop/1,
  reload/3,
  depends/2,
  mod_opt_type/1,
  mod_options/1
]).

%% ejabberd_http callback.
-export([process/2]).

%% api
-export([get_url/1]).

-include("logger.hrl").
-include("ejabberd_http.hrl").
-include("xmpp.hrl").

-record(state, {tab = undefined, url = undefined, host = <<>>}).

-define(TIMEOUT, 6000).

%%--------------------------------------------------------------------
%% gen_mod/supervisor callbacks.
%%--------------------------------------------------------------------
start(Host, Opts) ->
  gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
  gen_mod:stop_child(?MODULE, Host).

reload(Host, NewOpts, OldOpts) ->
  do_cast(Host,  {reload, Host, NewOpts, OldOpts}).

mod_opt_type(url) ->
  fun(<<"http://", _/binary>> = URL) -> URL;
    (<<"https://", _/binary>> = URL) -> URL;
    (undefined) -> undefined
  end.

mod_options(_Host) ->
  [
    {url, undefined}
  ].

depends(_Host, _Opts) ->
  [].

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Host, Opts]) ->
  process_flag(trap_exit, true),
  Tab = ets:new(iq_requests,[set,protected]),
  URL = misc:expand_keyword(<<"@HOST@">>, gen_mod:get_opt(url, Opts), Host),
  {ok, #state{tab = Tab, url = URL, host = Host}}.

handle_call(stop, _From, State) ->
  {stop, normal, ok, State};
handle_call(get_presence, _From, State) ->
  {reply,#presence{type = unavailable}, State};
handle_call(Req, From, State) ->
  ?WARNING_MSG("unexpected call: ~p from ~p", [Req, From]),
  {reply, ok, State}.
handle_cast({vcard_request, Server, User, ReqID, JID, Caller}, #state{tab = Tab} = State) ->
  make_session(User, Server, ReqID, Caller, Tab),
  Query = #vcard_temp{},
  IQ=#iq{type=get,
    id = ReqID,
    from = jid:make(User,Server,ReqID),
    to = JID,
    sub_els = [Query]},
  ejabberd_router:route(IQ),
  {noreply, State};
handle_cast({mam_request, Server, User, ReqID, StanzaID, Remote, Caller}, #state{tab = Tab} = State) ->
  make_session(User, Server, ReqID, Caller, Tab),
  To = case Remote of
         undefined -> jid:make(User,Server,<<>>);
         R -> jid:from_string(R)
       end,
  XData = #xdata{type = submit,
    fields = [
      #xdata_field{var = <<"FORM_TYPE">>, type='hidden', values = [<<"urn:xmpp:mam:1">>]},
      #xdata_field{var = <<"ids">>, values = [StanzaID]}
    ]},
  Query = #mam_query{id = ReqID, xmlns = <<"urn:xmpp:mam:2">>, xdata = XData},
  IQ=#iq{type=set,
    id = ReqID,
    from = jid:make(User,Server,ReqID),
    to = To,
    sub_els = [Query]},
  ejabberd_router:route(IQ),
  {noreply, State};
handle_cast({delete_session, ReqID}, #state{tab = Tab} = State) ->
  delete_session(Tab, ReqID),
  {noreply, State};
handle_cast(_Request, State = #state{}) ->
  {noreply, State}.

%% @private
%% @doc Handling all non call/cast messages
-spec(handle_info(Info :: timeout() | term(), State :: #state{}) ->
  {noreply, NewState :: #state{}} |
  {noreply, NewState :: #state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #state{}}).
handle_info({route, #presence{}}, State) ->
  {noreply, State};
handle_info({route, #iq{type = IQType}}, State) when IQType == set orelse  IQType == get ->
  {noreply, State};
handle_info({route, #iq{to= #jid{resource = ReqID}} = Pkt},
    #state{tab = Tab} = State) ->
  answer(Tab, ReqID, Pkt),
  {noreply, State};
handle_info({route, #message{to= #jid{resource = ReqID},
  sub_els = [#mam_result{queryid = ReqID}]}= Packet}, State) ->
  answer(State#state.tab,ReqID, Packet),
  {noreply, State};
handle_info({route, #message{to= #jid{lserver = LServer, resource = ReqID},
  sub_els = [SubEl | _]}= Packet}, State) ->
  Result = try xmpp:decode(SubEl) of
            #mam_result{queryid = ReqID} -> ok;
            _ -> pass
          catch
            _:_ -> pass
          end,
  case Result of
    ok ->
      answer(State#state.tab,ReqID, Packet);
    _ ->
      process_messages(LServer, Packet)
  end,
  {noreply, State};
handle_info({route, #message{to= #jid{lserver = LServer}}= Packet}, State) ->
  process_messages(LServer, Packet),
  {noreply, State};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, #state{tab = Tab}) ->
  Sessions = ets:tab2list(Tab),
  lists:foreach(fun({ReqID, _, {SID, User, Server}}) ->
    ejabberd_sm:close_session(SID, User, Server, ReqID) end, Sessions),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% HTTP API
%%%===================================================================
process(Path, #request{method = 'GET', data = Data, q = Q, headers = Headers} = Req) ->
  ?DEBUG("Request: ~p ~p ~p ~p~n",[Path,Data,Headers,Q]),
  case extract_auth(Req) of
    {error, Reason} ->
      {401, [],[atom_to_binary(Reason, latin1)]};
    Auth when is_map(Auth) ->
      {User, Server, <<"">>} = maps:get(usr, Auth),
      case check_host(Server) of
        true ->
          handle_reuest(Path, Req, User, Server);
        _ ->
          {400, [],[<<"unknown host">>]}
      end;
    _ ->
      {500, [],[<<"internal error">>]}
  end.

handle_reuest([<<"archive">>], #request{q = Q}, User, Server) ->
  To = proplists:get_value(<<"by">>, Q),
  StanzaID = proplists:get_value(<<"id">>, Q),
  handle_archive(Server, User, StanzaID, To);
handle_reuest([<<"vcard">>], #request{q = Q}, User, Server) ->
  Target = proplists:get_value(<<"jid">>, Q, error),
  handle_vcard(Server, User, Target);
handle_reuest(Path, _Req, _User, _Server) ->
  ?DEBUG("path no found: ~p~n", [Path]),
  {404, [], [<<"path no found">>]}.

handle_vcard(_Server, _User, error) ->
  {400, [], [<<"bad jid">>]};
handle_vcard(Server, User, Target) when is_binary(Target) ->
  JID = jid:from_string(Target),
  handle_vcard(Server, User, JID);
handle_vcard(Server, User, JID) ->
  ReqID = randoms:get_string(),
  do_cast(Server, {vcard_request,Server, User, ReqID, JID, self()}),
  loop(Server, ReqID).

handle_archive(_LServer, _LUser, undefined, _To) ->
  {400, [], [<<"no stanza id">>]};
handle_archive(LServer, LUser, StanzaID, To) ->
  ReqID = randoms:get_string(),
  do_cast(LServer, {mam_request,LServer,LUser,ReqID,StanzaID,To, self()}),
  loop(LServer, ReqID).

%%%===================================================================
%%% Internal functions
%%%===================================================================

extract_auth(#request{auth = HTTPAuth}) ->
  case HTTPAuth of
    {SJID, Pass} ->
      try jid:decode(SJID) of
        #jid{luser = User, lserver = Server, lresource = Res} ->
          case ejabberd_auth:check_password(User, <<"">>, Server, Pass) of
            true->
              #{usr => {User, Server, <<"">>}, caller_server => Server};
            _ ->
              %%{error, invalid_auth}
              %%To support legacy clients.
              %%todo: Remove it.
              check_token(User, Server, Res, Pass)
          end
      catch _:{bad_jid, _} ->
        {error, invalid_auth}
      end;
    {oauth, Token, _} ->
      case check_jwt(Token) of
        {error, not_jwt} ->
          case ejabberd_oauth:check_token(Token) of
            {ok, {U, S}, Scope} ->
              #{usr => {U, S, <<"">>}, oauth_scope => Scope, caller_server => S};
            {false, Reason} ->
              {error, Reason}
          end;
        Result ->
          Result
      end;
    _ ->
      {error, invalid_auth}
  end;
extract_auth(_) ->
  {error, invalid_auth}.

check_token(User, Server, Res, Token) ->
  case ejabberd_auth:user_exists(User, Server) of
    true ->
      case check_totp(User, Server, Res, Token) of
        {error, invalid_auth} ->
          check_hotp(User, Server, Res, Token);
        R -> R
      end;
    _ ->
      {error, invalid_auth}
  end.

check_jwt(Token) ->
  case binary:split(Token, <<".">>, [global]) of
    [_, P, _] ->
      Payload = try jiffy:decode(base64url:decode(P)) of
                  {V} -> V
                catch _:_ -> []
                end,
      UserDevID = proplists:get_value(<<"sub">>, Payload),
      Exp =  proplists:get_value(<<"exp">>, Payload),
      Now = erlang:system_time(second),
      try jid:decode(UserDevID) of
        #jid{luser = LUser, lserver = LServer, lresource = DevID} ->
          check_jwt(LUser, LServer, DevID, Token, Exp, Now)
      catch _:{bad_jid, _} ->
        {error, invalid_auth}
      end;
    _ ->
      {error, not_jwt}
  end.

check_jwt(_LUser, _LServer, _DevID, _Token, Exp, Now) when Exp < Now ->
  {error, invalid_auth};
check_jwt(LUser, LServer, DevID, Token, _, _) ->
  check_jwt(LUser, LServer, DevID, Token).

check_jwt(LUser, LServer, DevID, Token) ->
  case mod_xabber_push:get_jwk(LUser, LServer, DevID) of
    undefined -> {error, invalid_auth};
    JWK ->
      case  jose_jwt:verify(JWK, Token) of
        {true, _, _} ->
          #{usr => {LUser, LServer, <<"">>}, caller_server => LServer};
        _ ->
          {error, invalid_auth}
      end
  end.

check_totp(User, Server, Res, Token) ->
  Secrets = get_secrets(Server, jid:make(User,Server), Res),
  Now = seconds_since_epoch(0),
  lists:foldl(
    fun({Secret, _, _, Expire}, Acc) when Expire > Now->
    case hotp:valid_totp(Token, Secret) of
      true ->
        #{usr => {User, Server, <<"">>}, caller_server => Server};
      _ -> Acc
    end;
      (_, Acc) -> Acc
    end, {error, invalid_auth}, Secrets).

check_hotp(User, Server, _Res, Token) ->
  case mod_devices:check_token(true, User, Server, Token) of
    {ok, {DeviceID, NewCount}} ->
      mod_devices:set_count(User, Server, DeviceID, NewCount),
      #{usr => {User, Server, <<"">>}, caller_server => Server};
    _-> {error, invalid_auth}
  end.

make_session(User, Server, ReqID, Caller, Tab)->
  SID = {p1_time_compat:unique_timestamp(), self()},
  ets:insert(Tab, {ReqID,Caller, {SID, User, Server}}),
  ejabberd_sm:open_session(SID, User, Server, ReqID, 0, [{http_iq, true}]).


delete_session(Tab, ReqID) ->
  case ets:lookup(Tab,ReqID) of
    [{_, _, {SID, User, Server}}] ->
      ejabberd_sm:close_session(SID, User, Server, ReqID),
      ets:delete(Tab, ReqID);
    _ -> pass
  end.

answer(Tab, ReqID, Pkt) ->
  ?DEBUG("Pkt ~p~n",[Pkt]),
  case ets:lookup(Tab,ReqID) of
    [{ReqID, Pid, _ }] -> Pid ! {request_result, ReqID, Pkt};
    _ -> pass
  end.

loop(LServer, ReqID) ->
  loop(LServer, ReqID, []).

loop(LServer, ReqID, Acc) ->
  receive
    {request_result, ReqID, #message{} = Pkt} ->
      loop(LServer, ReqID, Acc ++ [Pkt]);
    {request_result, ReqID, #iq{} = Pkt} ->
      do_cast(LServer, {delete_session, ReqID}),
      {200, [],[make_string(Acc ++ [Pkt])]}
  after ?TIMEOUT ->
    do_cast(LServer, {delete_session, ReqID}),
    {408, [],[<<"Request Timeout">>]}
end.

process_messages(LServer, Packet) ->
  ejabberd_hooks:run_fold(offline_message_hook,
    LServer, {bounce, Packet}, []).

get_secrets(Server, JID, <<>>) ->
  mod_devices:select_secrets(Server, JID);
get_secrets(Server, JID, DevId) ->
  case mod_devices:select_secret(Server, JID, DevId) of
    {error, _} -> [];
    {S, C, E, _} -> [{S, C, DevId, E}]
  end.

check_host(Host) ->
  ejabberd_router:is_my_host(Host) andalso
    gen_mod:is_loaded(Host, ?MODULE).

make_string(Values) ->
  list_to_binary(lists:map(fun(X) -> fxml:element_to_binary(xmpp:encode(X)) end, Values)).

do_cast(LServer, Request) ->
  Proc = gen_mod:get_module_proc(LServer, ?MODULE),
  gen_server:cast(Proc, Request).

-spec seconds_since_epoch(integer()) -> non_neg_integer().
seconds_since_epoch(Diff) ->
  {Mega, Secs, _} = os:timestamp(),
  Mega * 1000000 + Secs + Diff.

%%%===================================================================
%%% API
%%%===================================================================

get_url(Host)->
  case gen_mod:get_module_opt(Host, ?MODULE, url) of
    O when is_binary(O) ->
      misc:expand_keyword(<<"@HOST@">>, O, Host);
    _ ->
      undefined
  end.
