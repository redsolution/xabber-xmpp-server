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
  Proc = gen_mod:get_module_proc(Host, ?MODULE),
  gen_server:cast(Proc, {reload, Host, NewOpts, OldOpts}).

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
handle_call(get_url, _From, State) ->
  {reply, State#state.url, State};
handle_call(Req, _From, State) ->
  ?WARNING_MSG("unexpected call: ~p", [Req]),
  {reply, {error, badarg}, State}.

handle_cast({mam_request, Server, User, ReqID, StanzaID, Remote, Caller}, #state{tab = Tab} = State) ->
  ets:insert(Tab, {ReqID,Caller}),
  SID = {p1_time_compat:unique_timestamp(), self()},
  ejabberd_sm:open_session(SID, User, Server, ReqID, 0, [{getpush, true}]),
  To = case Remote of
         undefined -> jid:make(User,Server,<<>>);
         R -> jid:from_string(R)
       end,
  XData = #xdata{type = submit,
    fields = [
      #xdata_field{var = <<"FORM_TYPE">>, type='hidden', values = [<<"urn:xmpp:mam:1">>]},
      #xdata_field{var = <<"{urn:xmpp:sid:0}stanza-id">>, values = [StanzaID]}
    ]},
  Query = #mam_query{id = ReqID, xmlns = <<"urn:xmpp:mam:2">>, xdata = XData},
  IQ=#iq{type=set,
    id = ReqID,
    from =  jid:make(User,Server,ReqID),
    to = To,
    sub_els = [Query]},
  ejabberd_router:route(IQ),
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
handle_info({route, #iq{type=result, to= #jid{luser = LUser, lserver = LServer, resource = Res}}}, State) ->
  answer(State#state.tab, Res, stop),
  delete(LUser, LServer, Res),
  {noreply, State};
handle_info({route, #iq{type=error, to= #jid{luser = LUser, lserver = LServer, resource = Res}}}, State) ->
  answer(State#state.tab, Res, error),
  delete(LUser, LServer, Res),
  {noreply, State};
handle_info({route, #message{to= #jid{luser = LUser, lserver = LServer, resource = Res}} = Packet}, State) ->
  answer(State#state.tab,Res, Packet),
  delete(LUser, LServer, Res),
  {noreply, State};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% HTTP API
%%%===================================================================

process([<<"archive">>] = Path, #request{method = 'GET', data = Data, q = Q, headers = Headers} = Req)->
  ?DEBUG("Request: ~p ~p ~p ~p~n",[Path,Data,Headers,Q]),
  To = proplists:get_value(<<"by">>, Q),
  StanzaID = proplists:get_value(<<"id">>, Q),
  Host = get_host(Headers),
  case extract_auth(Req, Host) of
    {error, unknown_host } ->
      {400, [], [<<"unknown host">>]};
    {error, Reason} ->
      {401, [],[atom_to_binary(Reason, latin1)]};
    Auth when is_map(Auth) ->
      {User, Server, <<"">>} = maps:get(usr, Auth),
      if
        Server == Host ->
          handle_archive(Server, User, StanzaID, To);
        true ->
          {401, [],[<<"host mismatch">>]}
      end
  end;

process(Path, Request) ->
  ?DEBUG("Bad Request: no handler ~p~n~p", [Path,Request]),
  {400, [], [<<"no handler">>]}.

handle_archive(_LServer, _LUser, undefined, _To) ->
  {400, [], [<<"no stanza id">>]};
handle_archive(LServer, LUser, StanzaID, To) ->
  ReqID = randoms:get_string(),
  activate(LServer, LUser, ReqID, StanzaID, To, self()),
  case loop(ReqID) of
    #message{} = Pkt ->
      {200, [],[fxml:element_to_binary(xmpp:encode(Pkt))]};
    _ ->
      {404, [],[]}
  end.

loop(ReqID) ->
  receive
    {mam_result, ReqID, error} ->
      error;
    {mam_result, ReqID, stop} ->
      stop;
    {mam_result, ReqID, Pkt} ->
      Pkt
  after ?TIMEOUT ->
    timeout
  end.

extract_auth(_, undefined) ->
  {error, unknown_host};
extract_auth(#request{auth = HTTPAuth}, Host) ->
  case HTTPAuth of
    {SJID, Pass} ->
      try jid:decode(SJID) of
        #jid{luser = User, lserver = Server} ->
          case ejabberd_auth:check_password(User, <<"">>, Server, Pass) of
            true->
              #{usr => {User, Server, <<"">>}, caller_server => Server};
            _ ->
              {error, invalid_auth}
          end
      catch _:{bad_jid, _} ->
        {error, invalid_auth}
      end;
    {oauth, Token, _} ->
      case ejabberd_oauth:check_token(Token) of
        {ok, {U, S}, Scope} ->
          #{usr => {U, S, <<"">>}, oauth_scope => Scope, caller_server => S};
        {false, Reason} ->
          case mod_x_auth_token:user_token_info(Host, Token) of
            {ok,[{SJID,_}]} ->
              JID = jid:from_string(SJID),
              #{usr => jid:tolower(JID), caller_server => JID#jid.lserver};
            _ ->
              {error, Reason}
          end
      end;
    _ ->
      {error, invalid_auth}
  end;
extract_auth(_,_) ->
  {error, invalid_auth}.

%%%===================================================================
%%% Internal functions
%%%===================================================================


activate(Server, User, ReqID, StanzaID, To, Caller) ->
  Proc = gen_mod:get_module_proc(Server, ?MODULE),
  gen_server:cast(Proc, {mam_request,Server,User,ReqID,StanzaID,To, Caller}).

delete(User, Server, Res) ->
  case ejabberd_sm:get_session_sid(User, Server, Res) of
    none ->
      ok;
    SID ->
      ejabberd_sm:close_session(SID, User, Server, Res)
  end.

answer(Tab, ReqID, Pkt) ->
  case ets:lookup(Tab,ReqID) of
    [{Res, Pid}] ->
      Pid ! {mam_result, Res, Pkt},
      ets:delete(Tab, ReqID);
    _ ->
      pass
  end.

get_host(Headers) ->
  Host = proplists:get_value(<<"Xmpp-Domain">>, Headers),
  try ejabberd_router:host_of_route(Host)
  catch
    _:_ -> undefined
  end.

%%%===================================================================
%%% API
%%%===================================================================

get_url(Host)->
  Proc = gen_mod:get_module_proc(Host, ?MODULE),
  gen_server:call(Proc, get_url).
