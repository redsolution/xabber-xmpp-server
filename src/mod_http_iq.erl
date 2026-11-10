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
-compile([{parse_transform, ejabberd_sql_pt}]).

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

%% gen_iq_handler callback.
-export([process_iq/1]).

%% Hook callbacks.
-export([disco_sm_features/5]).

%% api
-export([get_url/1, make_jwt/3]).

-include("logger.hrl").
-include("ejabberd_http.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").

-record(state, {tab = undefined, url = undefined, host = <<>>}).

-define(TIMEOUT, 6000).
-define(AC_ALLOW_METHODS,
  {<<"Access-Control-Allow-Methods">>,
    <<"GET, POST, OPTIONS">>}).
-define(AC_ALLOW_ORIGIN,
  {<<"Access-Control-Allow-Origin">>, <<"*">>}).
-define(AC_ALLOW_HEADERS,
  {<<"Access-Control-Allow-Headers">>,
    <<"Content-Type, Authorization">>}).
-define(AC_MAX_AGE,
  {<<"Access-Control-Max-Age">>, <<"86400">>}).
-define(CT_XML,
  {<<"Content-Type">>, <<"text/xml; charset=utf-8">>}).
-define(CT_PLAIN,
  {<<"Content-Type">>, <<"text/plain">>}).
-define(OPTIONS_HEADER,
  [?CT_PLAIN, ?AC_ALLOW_ORIGIN, ?AC_ALLOW_METHODS,
    ?AC_ALLOW_HEADERS, ?AC_MAX_AGE]).
-define(HEADER(CType),
  [CType, ?AC_ALLOW_ORIGIN, ?AC_ALLOW_HEADERS]).
-define(TOKEN_CACHE, http_iq_token_cache).

%%--------------------------------------------------------------------
%% gen_mod/supervisor callbacks.
%%--------------------------------------------------------------------
start(Host, Opts) ->
  init_cache(Host, Opts),
  register_hooks(Host),
  register_iq_handlers(Host),
  gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
  unregister_iq_handlers(Host),
  unregister_hooks(Host),
  case gen_mod:is_loaded_elsewhere(Host, ?MODULE) of
    true -> ok;
    false -> ets_cache:delete(?TOKEN_CACHE)
  end,
  gen_mod:stop_child(?MODULE, Host).

reload(Host, NewOpts, OldOpts) ->
  do_cast(Host,  {reload, Host, NewOpts, OldOpts}).

mod_opt_type(url) ->
  fun(<<"http://", _/binary>> = URL) -> URL;
    (<<"https://", _/binary>> = URL) -> URL;
    (undefined) -> undefined
  end;
mod_opt_type(jwt_ttl) ->
  fun(I) when is_integer(I), I > 0 -> I end;
mod_opt_type(O) when O == cache_life_time; O == cache_size ->
  fun(I) when is_integer(I), I > 0 -> I;
    (infinity) -> infinity
  end;
mod_opt_type(O) when O == use_cache; O == cache_missed ->
  fun(B) when is_boolean(B) -> B end.

mod_options(Host) ->
  [
    {url, undefined},
    {jwt_ttl, 30 * 24 * 60 * 60},
    {use_cache, ejabberd_config:use_cache(Host)},
    {cache_size, ejabberd_config:cache_size(Host)},
    {cache_missed, ejabberd_config:cache_missed(Host)},
    {cache_life_time, ejabberd_config:cache_life_time(Host)}
  ].

depends(_Host, _Opts) ->
  [].

%%%===================================================================
%%% Hooks and IQ handlers
%%%===================================================================

register_hooks(Host) ->
  ejabberd_hooks:add(disco_sm_features, Host, ?MODULE,
    disco_sm_features, 50).

unregister_hooks(Host) ->
  ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE,
    disco_sm_features, 50).

register_iq_handlers(Host) ->
  gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_HTTPIQ,
    ?MODULE, process_iq).

unregister_iq_handlers(Host) ->
  gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_HTTPIQ).

disco_sm_features(empty, From, To, Node, Lang) ->
  disco_sm_features({result, []}, From, To, Node, Lang);
disco_sm_features({result, Features},
    #jid{luser = LUser, lserver = LServer},
    #jid{luser = LUser, lserver = LServer}, <<"">>, _Lang) ->
  case get_url(LServer) of
    undefined -> {result, Features};
    _ -> {result, [?NS_HTTPIQ | Features]}
  end;
disco_sm_features(Acc, _From, _To, _Node, _Lang) ->
  Acc.

process_iq(#iq{from = #jid{luser = LUser, lserver = LServer},
  to = #jid{luser = LUser, lserver = LServer}} = IQ)  when LUser =/= <<>> ->
  case get_url(LServer) of
    undefined ->
      ?ERROR_MSG("~s is enabled on ~s but URL is not configured",
        [?MODULE, LServer]),
      xmpp:make_error(IQ, xmpp:err_service_unavailable());
    _ ->
      process_user_iq(IQ)
  end;
process_iq(IQ) ->
  xmpp:make_error(IQ, xmpp:err_forbidden()).

process_user_iq(#iq{type = set, lang = Lang} = IQ) ->
  Text = <<"Only IQ requests of type 'set' are allowed">>,
  xmpp:make_error(IQ, xmpp:err_not_allowed(Text, Lang));
process_user_iq(#iq{type = get, sub_els = [#httpiq_endpoints{}]} = IQ) ->
  make_endpoints_result(IQ);
process_user_iq(#iq{type = get, from = From, lang = Lang,
    sub_els = [#httpiq_token{} = Token]} = IQ) ->
  case validate_token_payload(Token, Lang) of
    {ok, Scopes} ->
      make_token_result(IQ, From, Token#httpiq_token{scopes = Scopes});
    {error, Error} ->
      xmpp:make_error(IQ, Error)
  end;
process_user_iq(IQ) ->
  xmpp:make_error(IQ, xmpp:err_not_allowed()).

make_endpoints_result(#iq{to = #jid{lserver = LServer}} = IQ) ->
  BaseURL = get_url(LServer),
  xmpp:make_iq_result(IQ, #httpiq_endpoints{
    protocols = httpiq_protocols(BaseURL)}).

make_token_result(#iq{to = #jid{lserver = LServer}, lang = Lang} = IQ,
    From, #httpiq_token{scopes = Scopes, ttl = RequestedTTL}) ->
  case get_device_id(From) of
    undefined ->
      xmpp:make_error(IQ, xmpp:err_not_allowed());
    DeviceID ->
      TTL = effective_ttl(LServer, RequestedTTL),
      case make_jwt(LServer, From, DeviceID, Scopes, TTL) of
        {ok, JWT, Exp} ->
          xmpp:make_iq_result(IQ, #httpiq_token{
            scopes = Scopes,
            ttl = TTL,
            expires = seconds_to_timestamp(Exp),
            value = JWT});
        {error, _} ->
          Text = <<"HTTP IQ token generation failed">>,
          xmpp:make_error(IQ, xmpp:err_internal_server_error(Text, Lang))
      end
  end.

httpiq_protocols(BaseURL) ->
  [#httpiq_protocol{
    var = Var,
    endpoints = httpiq_endpoints(BaseURL, Endpoints)}
    || #{var := Var, endpoints := Endpoints} <- httpiq_protocol_specs()].

httpiq_endpoints(BaseURL, EndpointSpecs) ->
  [#httpiq_endpoint{
    name = Name,
    url = endpoint_url(BaseURL, Path)}
    || #{name := Name, path := Path} <- EndpointSpecs].

httpiq_protocol_specs() ->
  [
    #{
      var => ?NS_MAM_2,
      endpoints => [
        #{
          name => <<"by-id">>,
          path => <<"archive/by-id/">>
        }
      ]
    }
  ].

endpoint_url(BaseURL, Path) ->
  Base = case binary:last(BaseURL) of
           47 -> BaseURL;
           _ -> <<BaseURL/binary, "/">>
         end,
  <<Base/binary, Path/binary>>.

validate_token_payload(#httpiq_token{scopes = Scopes}, Lang) ->
  validate_scopes(Scopes, Lang).

validate_scopes([], Lang) ->
  bad_request(Lang, <<"HTTP IQ token request must contain at least one scope">>);
validate_scopes(Scopes, Lang) ->
  Normalized = [str:strip(Scope) || Scope <- Scopes],
  case lists:member(<<>>, Normalized) of
    true ->
      bad_request(Lang, <<"HTTP IQ token scope must not be empty">>);
    false ->
      validate_supported_scopes(Normalized, Lang)
  end.

validate_supported_scopes(Scopes, Lang) ->
  Unknown = [Scope || Scope <- Scopes,
    not lists:member(Scope, supported_scopes())],
  case Unknown of
    [] ->
      {ok, Scopes};
    _ ->
      Txt = <<"Unsupported HTTP IQ token scope">>,
      {error, xmpp:err_feature_not_implemented(Txt, Lang)}
  end.

supported_scopes() ->
  [Var || #{var := Var} <- httpiq_protocol_specs()].

effective_ttl(LServer, undefined) ->
  gen_mod:get_module_opt(LServer, ?MODULE, jwt_ttl);
effective_ttl(LServer, RequestedTTL) ->
  min(RequestedTTL, gen_mod:get_module_opt(LServer, ?MODULE, jwt_ttl)).

seconds_to_timestamp(Secs) ->
  {Secs div 1000000, Secs rem 1000000, 0}.

get_device_id(#jid{} = JID) ->
  {LUser, LServer, LResource} = jid:tolower(JID),
  case ejabberd_sm:get_user_info(LUser, LServer, LResource) of
    [_H | Info] ->
      proplists:get_value(device_id, Info, undefined);
    _ ->
      undefined
  end.

bad_request(Lang, Txt) ->
  {error, xmpp:err_bad_request(Txt, Lang)}.

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
  Query = #mam_query{id = ReqID, xmlns = ?NS_MAM_2, xdata = XData},
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
      {401, ?HEADER(?CT_PLAIN), [atom_to_binary(Reason, latin1)]};
    Auth when is_map(Auth) ->
      {User, Server, <<"">>} = maps:get(usr, Auth),
      Scopes = maps:get(scopes, Auth, []),
      case check_host(Server) of
        true ->
          handle_reuest(Path, Req, User, Server, Scopes);
        _ ->
          {400, ?HEADER(?CT_PLAIN), [<<"unknown host">>]}
      end;
    _ ->
      {500, ?HEADER(?CT_PLAIN), [<<"internal error">>]}
  end;
process(_, #request{method = 'OPTIONS', data = <<>>}) ->
  {204, ?OPTIONS_HEADER, []};
process(_Path, Request) ->
  ?DEBUG("Bad Request: no handler ~p~n~p", [_Path,Request]),
  {400, ?HEADER(?CT_PLAIN), [<<"no handler">>]}.

handle_reuest([<<"archive">>, <<"by-id">>], #request{q = Q}, User, Server, Scopes) ->
  case lists:member(?NS_MAM_2, Scopes) of
    true ->
      To = proplists:get_value(<<"by">>, Q),
      StanzaID = proplists:get_value(<<"id">>, Q),
      handle_archive(Server, User, StanzaID, To);
    false ->
      {403, ?HEADER(?CT_PLAIN), [<<"forbidden">>]}
  end;
handle_reuest([<<"vcard">>], #request{q = Q}, User, Server, _Scopes) ->
  Target = proplists:get_value(<<"jid">>, Q, error),
  handle_vcard(Server, User, Target);
handle_reuest(Path, _Req, _User, _Server, _Scopes) ->
  ?DEBUG("path no found: ~p~n", [Path]),
  {404, ?HEADER(?CT_PLAIN), [<<"path no found">>]}.

handle_vcard(_Server, _User, error) ->
  {400, ?HEADER(?CT_PLAIN), [<<"bad jid">>]};
handle_vcard(Server, User, Target) when is_binary(Target) ->
  JID = jid:from_string(Target),
  handle_vcard(Server, User, JID);
handle_vcard(Server, User, JID) ->
  ReqID = randoms:get_string(),
  do_cast(Server, {vcard_request,Server, User, ReqID, JID, self()}),
  loop(Server, ReqID).

handle_archive(_LServer, _LUser, undefined, _To) ->
  {400, ?HEADER(?CT_PLAIN), [<<"no stanza id">>]};
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
        #jid{luser = User, lserver = Server} ->
          case ejabberd_auth:check_password(User, <<"">>, Server, Pass) of
            true->
              #{usr => {User, Server, <<"">>},
                caller_server => Server,
                scopes => supported_scopes()};
            _ ->
              {error, invalid_auth}
          end
      catch _:{bad_jid, _} ->
        {error, invalid_auth}
      end;
    {oauth, Token, _} ->
      case check_jwt(Token) of
        {error, _} ->
          {error, invalid_auth};
        Result ->
          Result
      end;
    _ ->
      {error, invalid_auth}
  end;
extract_auth(_) ->
  {error, invalid_auth}.

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
      case jwt_scopes(proplists:get_value(<<"scope">>, Payload, [])) of
        {ok, Scopes} ->
          try jid:decode(UserDevID) of
            #jid{luser = LUser, lserver = LServer, lresource = DevID} ->
              check_jwt(LUser, LServer, DevID, Token, Exp, Scopes, Now)
          catch _:_ ->
            {error, invalid_auth}
          end;
        error ->
          {error, invalid_auth}
      end;
    _ ->
      {error, invalid_auth}
  end.

jwt_scopes(Scopes) when is_list(Scopes) ->
  case lists:all(fun erlang:is_binary/1, Scopes) of
    true -> {ok, Scopes};
    false -> error
  end;
jwt_scopes(_) ->
  error.

check_jwt(_LUser, _LServer, _DevID, _Token, Exp, _Scopes, _Now)
    when not is_integer(Exp) ->
  {error, invalid_auth};
check_jwt(_LUser, _LServer, _DevID, _Token, Exp, _Scopes, Now)
    when Exp < Now ->
  {error, invalid_auth};
check_jwt(LUser, LServer, DevID, Token, _, Scopes, _) ->
  check_jwt(LUser, LServer, DevID, Token, Scopes).

check_jwt(LUser, LServer, DevID, Token, Scopes) ->
  TokenHash = token_hash(Token),
  Key = token_cache_key(LUser, LServer, DevID),
  Now = erlang:system_time(second),
  case lookup_cached_auth(Key, TokenHash, Now) of
    {ok, Auth} ->
      Auth#{scopes => Scopes};
    miss ->
      verify_jwt_from_storage(LUser, LServer, DevID, Token, TokenHash, Scopes, Now);
    stale ->
      {error, invalid_auth}
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
      {200, ?HEADER(?CT_XML), [make_string(Acc ++ [Pkt])]}
  after ?TIMEOUT ->
    do_cast(LServer, {delete_session, ReqID}),
    {408, ?HEADER(?CT_PLAIN), [<<"Request Timeout">>]}
end.

process_messages(LServer, Packet) ->
  ejabberd_hooks:run_fold(offline_message_hook,
    LServer, {bounce, Packet}, []).

check_host(Host) ->
  ejabberd_router:is_my_host(Host) andalso
    gen_mod:is_loaded(Host, ?MODULE).

make_string(Values) ->
  list_to_binary(lists:map(fun(X) -> fxml:element_to_binary(xmpp:encode(X)) end, Values)).

do_cast(LServer, Request) ->
  Proc = gen_mod:get_module_proc(LServer, ?MODULE),
  gen_server:cast(Proc, Request).

%%%===================================================================
%%% Caching
%%%===================================================================

init_cache(Host, Opts) ->
  case gen_mod:get_opt(use_cache, Opts) of
    true ->
      ets_cache:new(?TOKEN_CACHE, cache_opts(Opts));
    false ->
      case gen_mod:is_loaded_elsewhere(Host, ?MODULE) of
        true -> ok;
        false -> ets_cache:delete(?TOKEN_CACHE)
      end
  end.

cache_opts(Opts) ->
  MaxSize = gen_mod:get_opt(cache_size, Opts),
  CacheMissed = gen_mod:get_opt(cache_missed, Opts),
  LifeTime = case gen_mod:get_opt(cache_life_time, Opts) of
    infinity -> infinity;
    I -> timer:seconds(I)
  end,
  [{max_size, MaxSize}, {cache_missed, CacheMissed}, {life_time, LifeTime}].

use_cache(LServer) ->
  gen_mod:get_module_opt(LServer, ?MODULE, use_cache).

cache_nodes() ->
  ejabberd_cluster:get_nodes().

token_cache_key(LUser, LServer, DeviceID) ->
  {LUser, LServer, DeviceID}.

lookup_cached_auth(Key, TokenHash, Now) ->
  case ets_cache:lookup(?TOKEN_CACHE, Key) of
    {ok, {TokenHash, Exp, Auth}} when Exp > Now ->
      {ok, Auth};
    {ok, {_OtherTokenHash, Exp, _Auth}} when Exp > Now ->
      stale;
    _ ->
      miss
  end.

cache_auth(LServer, Key, TokenHash, Exp, Auth) ->
  case use_cache(LServer) of
    true ->
      ets_cache:insert(?TOKEN_CACHE, Key, {TokenHash, Exp, Auth}, cache_nodes());
    false ->
      ok
  end.

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

make_jwt(LServer, JID, DeviceID) ->
  TTL = gen_mod:get_module_opt(LServer, ?MODULE, jwt_ttl),
  case make_jwt(LServer, JID, DeviceID, [?NS_MAM_2], TTL) of
    {ok, Compact, _Exp} ->
      {ok, Compact};
    Err ->
      Err
  end.

make_jwt(LServer, JID, DeviceID, Scopes, TTL) ->
  {LUser, LServer, _} = jid:tolower(JID),
  Now = erlang:system_time(second),
  Exp = Now + TTL,
  case get_or_create_jwk(LUser, LServer, DeviceID) of
    {ok, JWK} ->
      Sub = jid:to_string(jid:replace_resource(JID, DeviceID)),
      JWS = #{<<"alg">> => <<"HS256">>},
      JWT = #{<<"iss">> => LServer,
        <<"sub">> => Sub,
        <<"scope">> => Scopes,
        <<"iat">> => Now,
        <<"exp">> => Exp},
      Signed = jose_jwt:sign(JWK, JWS, JWT),
      {_, Compact} = jose_jws:compact(Signed),
      case store_token_marker(LUser, LServer, DeviceID, JWK, Compact, Exp, Now) of
        ok ->
          Auth = auth_map(LUser, LServer, Scopes),
          Key = token_cache_key(LUser, LServer, DeviceID),
          cache_auth(LServer, Key, token_hash(Compact), Exp, Auth),
          {ok, Compact, Exp};
        Err -> Err
      end;
    Err ->
      Err
  end.

get_or_create_jwk(LUser, LServer, DeviceID) ->
  case lookup_token_marker(LUser, LServer, DeviceID) of
    {ok, #{jwk := JWK}} ->
      {ok, JWK};
    not_found ->
      {ok, generate_jwk()};
    Err ->
      Err
  end.

generate_jwk() ->
  #{<<"kty">> => <<"oct">>,
    <<"k">> => base64url:encode(crypto:strong_rand_bytes(32))}.

lookup_token_marker(LUser, LServer, DeviceID) ->
  case sql_select_token_marker(LUser, LServer, DeviceID) of
    {ok, JWKData, TokenHash, Exp} ->
      case decode_jwk(JWKData) of
        {ok, JWK} -> {ok, #{jwk => JWK, token_hash => TokenHash, exp => Exp}};
        Err -> Err
      end;
    Other ->
      Other
  end.

verify_jwt_from_storage(LUser, LServer, DeviceID, Token, TokenHash, Scopes, Now) ->
  case lookup_token_marker(LUser, LServer, DeviceID) of
    {ok, #{jwk := JWK, token_hash := TokenHash, exp := StoredExp}} when StoredExp > Now ->
      case jose_jwt:verify(JWK, Token) of
        {true, _, _} ->
          Auth = auth_map(LUser, LServer, Scopes),
          Key = token_cache_key(LUser, LServer, DeviceID),
          cache_auth(LServer, Key, TokenHash, StoredExp, Auth),
          Auth;
        _ ->
          {error, invalid_auth}
      end;
    _ ->
      {error, invalid_auth}
  end.

auth_map(LUser, LServer, Scopes) ->
  #{usr => {LUser, LServer, <<"">>},
    caller_server => LServer,
    scopes => Scopes}.

sql_select_token_marker(LUser, LServer, DeviceID) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(jwk)s, @(token_hash)s, @(expires_at)d "
      "from http_iq_tokens where username=%(LUser)s "
      "and %(LServer)H and device_id=%(DeviceID)s")) of
    {selected, []} ->
      not_found;
    {selected, [{JWKData, TokenHash, Exp}]} ->
      {ok, JWKData, TokenHash, Exp};
    _ ->
      {error, db_failure}
  end.

store_token_marker(LUser, LServer, DeviceID, JWK, Token, Exp, Now) ->
  JWKData = encode_jwk(JWK),
  TokenHash = token_hash(Token),
  sql_upsert_token_marker(LUser, LServer, DeviceID, JWKData, TokenHash, Exp, Now).

sql_upsert_token_marker(LUser, LServer, DeviceID, JWKData, TokenHash, Exp, Now) ->
  case ?SQL_UPSERT(
    LServer,
    "http_iq_tokens",
    ["!username=%(LUser)s",
      "!server_host=%(LServer)s",
      "!device_id=%(DeviceID)s",
      "jwk=%(JWKData)s",
      "token_hash=%(TokenHash)s",
      "expires_at=%(Exp)d",
      "updated_at=%(Now)d"]) of
    ok ->
      ok;
    _ ->
      {error, db_failure}
  end.

encode_jwk(#{<<"kty">> := Kty, <<"k">> := K}) ->
  jiffy:encode({[{<<"kty">>, Kty}, {<<"k">>, K}]}).

decode_jwk(JWKData) ->
  try jiffy:decode(JWKData) of
    {[{<<"kty">>, Kty}, {<<"k">>, K}]} ->
      {ok, #{<<"kty">> => Kty, <<"k">> => K}};
    {[{<<"k">>, K}, {<<"kty">>, Kty}]} ->
      {ok, #{<<"kty">> => Kty, <<"k">> => K}};
    _ ->
      {error, invalid_jwk}
  catch
    _:_ ->
      {error, invalid_jwk}
  end.

token_hash(Token) ->
  base64url:encode(crypto:hash(sha256, Token)).
