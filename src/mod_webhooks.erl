%%%-------------------------------------------------------------------
%%% File    : mod_webhooks.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : Sending webhooks about user registration and deletion events.
%%% Created : 24 Jan 2022 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%%
%%%
%%% xabberserver, Copyright (C) 2007-2022   Redsolution OÜ
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
-module(mod_webhooks).
-author("ilya.kalashnikov@redsolution.com").
-behavior(gen_mod).
-behavior(gen_server).
-include("logger.hrl").

%% gen_mod
-export([start/2, stop/1, reload/3, depends/2, mod_options/1,
  mod_opt_type/1]).

%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

%% Hooks
-export([register_user/2, remove_user/2]).

%% API
-export([send_hook/1, send_hook/4, make_jwt/2]).

-define(HTTP_TIMEOUT, 10000).
-define(CONNECT_TIMEOUT, 8000).
-define(DEFAULT_MIME, "application/json").
-define(ONE_HOUR, 3600000).

-record(state, {
  host = <<>>           :: binary(),
  url = []              :: list(),
  secret = <<>>         :: binary()
}).

%%====================================================================
%% gen_mod API
%%====================================================================
start(Host, Opts) ->
  gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
  unregister_hooks(Host),
  gen_mod:stop_child(?MODULE, Host).

reload(Host, NewOpts, OldOpts) ->
  Proc = gen_mod:get_module_proc(Host, ?MODULE),
  gen_server:cast(Proc, {reload, Host, NewOpts, OldOpts}).

depends(_Host, _Opts) -> [].

mod_options(_Host) ->
  [
    {url, []},
    {secret, <<"xmppserverwebhook">>}
  ].


mod_opt_type(secret) -> fun iolist_to_binary/1;
mod_opt_type(_) ->
  fun
    (L) when is_list(L) -> L;
    (B) when is_binary(B) -> binary_to_list(B) end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host, Opts]) ->
  State = init_state(Host,Opts),
  case State#state.url of
    [] -> ok;
    _ ->
      register_hooks(Host)
  end,
  {ok, State}.

handle_call(stop, _From, State) ->
  {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast({send_hook, Headers, Mime, Data},
    #state{host = Host, url = URL, secret = Secret} = State) ->
  Token = make_jwt(Secret, Host),
  Headers1 = [{"connection", "keep-alive"},
    {"User-Agent", "xmpp-server"},
    {"Authorization", "Bearer " ++ Token}
  ] ++ Headers,
  Request = {URL, Headers1, Mime, Data},
  case send_hook(Request) of
    {ok, _ , _} -> ok;
    _->
      erlang:send_after(?ONE_HOUR, self(), {repeat_hook, 0, Request})
  end,
  {noreply, State};
handle_cast({reload, Host, NewOpts, _OldOpts}, State) ->
  NewState = init_state(Host, NewOpts),
  OldURL = State#state.url,
  NewUrl = NewState#state.url,
  if
    NewUrl == [] andalso OldURL /= [] ->
      unregister_hooks(Host);
    NewUrl /= [] andalso OldURL == [] ->
      register_hooks(Host);
    true ->
      ok
  end,
  {noreply, NewState};
handle_cast(Msg, State) ->
  ?WARNING_MSG("unexpected cast: ~p", [Msg]),
  {noreply, State}.

%% it retries five times; at 1, 12, 24, 48, and 72 hours after the previous attempt.
handle_info({repeat_hook, Multiplier, {URL, Headers, Mime, Data}},
    #state{host = Host, secret = Secret} = State) ->
  Token = make_jwt(Secret, Host),
  HeadersNew = lists:keyreplace("Authorization", 1, Headers, {"Authorization", "Bearer " ++ Token}),
  case send_hook({URL, HeadersNew, Mime, Data}) of
    {ok, _ , _} -> ok;
    _ when Multiplier < 8 ->
      M = case Multiplier of 0 -> 1; V-> V end,
      erlang:send_after(?ONE_HOUR * 12 * M, self(),
        {repeat_hook, Multiplier + 2, {URL, HeadersNew, Mime, Data}});
    _ ->
      error
  end,
  {noreply, State};
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) -> {ok, State}.


%% hooks
-spec register_user(binary(), binary()) -> any().
register_user(User, Server) ->
  Data = make_payload(user, create, [{username, User}, {host, Server}]),
  send_hook(Server, [], [], Data),
  ok.

-spec remove_user(binary(), binary()) -> any().
remove_user(User, Server) ->
  Data = make_payload(user, remove, [{username, User}, {host, Server}]),
  send_hook(Server, [], [], Data),
  ok.

%% API

send_hook(Host, Headers, [], Data) ->
  send_hook(Host, Headers, ?DEFAULT_MIME, Data);
send_hook(Host, Headers, Mime, Data) ->
  Proc = gen_mod:get_module_proc(Host, ?MODULE),
  gen_server:cast(Proc, {send_hook, Headers, Mime, Data}).

send_hook(Request) ->
  Opts = [{connect_timeout, ?CONNECT_TIMEOUT},
    {timeout, ?HTTP_TIMEOUT}],
  try httpc:request(post, Request, Opts, [{body_format, binary}]) of
    {ok, {{_, Code, _}, _, Body}} when Code >= 200, Code =< 299 ->
      {ok, Code, Body};
    {ok, {{_, Code, _}, _, Body}} ->
      ?ERROR_MSG("Got unexpected status code: ~B~nRequest =  ~p", [Code, Request]),
      {error, Code, Body};
    {error, Reason} ->
      ?ERROR_MSG("HTTP request failed:~n** Request = ~p~n** Err = ~p", [Request, Reason]),
      {error, Reason}
  catch
    exit:Reason ->
      ?ERROR_MSG("HTTP request failed:~n** Request = ~p~n** Err = ~p", [Request, Reason]),
      {error, {http_error, {error, Reason}}}
  end.

-spec make_jwt(binary(), map()) -> binary().
make_jwt(Secret,Host)->
  JWK = #{<<"kty">> => <<"oct">>, <<"k">> => base64url:encode(Secret)},
  JWS = #{<<"alg">> => <<"HS256">>},
  JWT = #{
    <<"iss">> => Host,
    <<"iat">> => seconds_since_epoch(0),
    <<"exp">> => seconds_since_epoch(3500)
  },
  Signed = jose_jwt:sign(JWK, JWS, JWT),
  {_Alg, Token} = jose_jws:compact(Signed),
  binary_to_list(Token).

%% Internal

make_payload(user, Action, PropList) ->
  jiffy:encode({[{target, user},{action, Action}] ++ PropList});
make_payload(_Target, _Action, _PropList) ->
  jiffy:encode({[]}).

-spec seconds_since_epoch(integer()) -> non_neg_integer().
seconds_since_epoch(Diff) ->
  {Mega, Secs, _} = os:timestamp(),
  Mega * 1000000 + Secs + Diff.

init_state(Host, Opts) ->
  #state{
    host = Host,
    url = gen_mod:get_opt(url, Opts),
    secret = gen_mod:get_opt(secret, Opts)
  }.

register_hooks(Host) ->
  ejabberd_hooks:add(register_user, Host, ?MODULE, register_user, 80),
  ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 80).

unregister_hooks(Host) ->
  ejabberd_hooks:delete(register_user, Host, ?MODULE, register_user, 80),
  ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 80).
