%%%-------------------------------------------------------------------
%%% File    : mod_block_users.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : Blocking users
%%% Created : 6 Apr 2022 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
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
-module(mod_block_users).
-author("ilya.kalashnikov@redsolution.com").
-behaviour(gen_mod).
-behavior(gen_server).
-compile([{parse_transform, ejabberd_sql_pt}]).

%% gen server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).
%% gen_mod
-export([start/2, stop/1, reload/3, mod_opt_type/1, mod_options/1, depends/2]).
%% API
-export([maybe_kick/1, maybe_kick/4, block_user/3, unblock_user/2, get_user/2,
  store_user/3, remove_user/2]).


-include("logger.hrl").
-include("ejabberd_sql_pt.hrl").
-include("xmpp.hrl").

-record(state, {
  host = <<"">> :: binary(),
  last = maps:new() :: map()}).
-define(BLOCK_USERS_CACHE,blocked_users).
-define(DELAY, 3600).


init([Host, Opts]) ->
  init_cache(Host, Opts),
  ejabberd_hooks:add(c2s_session_opened, Host, ?MODULE, maybe_kick, 10),
  ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 60),
  {ok, #state{host = Host}}.

handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast({maybe_kick, {JID, Lang, SID}}, #state{last = Last} = State) ->
  LJID = jid:tolower(jid:remove_resource(JID)),
  LastTS = case maps:find(LJID, Last) of
             {ok, TS} -> TS;
             _ -> 0
           end,
  NewLast = case maybe_kick(JID, Lang, SID, LastTS) of
               {ok, NewTS} ->
                 Last1 = maps:remove(LJID, Last),
                 maps:put(LJID, NewTS, Last1);
               _ -> Last
             end,
  {noreply, State#state{last = NewLast}};
handle_cast({delete_last, {User, Server}}, #state{last = Last} = State) ->
  LJID = {User, Server, <<>>},
  {noreply,State#state{last = maps:remove(LJID, Last)}};
handle_cast(Msg, State) ->
  ?WARNING_MSG("Could not handle cast ~p~n ~p~n",[Msg,State]),
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, State) ->
  Host = State#state.host,
  ejabberd_hooks:delete(c2s_session_opened, Host, ?MODULE, maybe_kick, 10),
  ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 60),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

get_user(LUser, LServer) ->
  sql_get_user(LUser, LServer).

store_user(LUser, LServer, Reason) ->
  sql_store_user(LUser, LServer, Reason).

remove_user(User, Server) ->
  sql_remove_user(User, Server).


maybe_kick(#{jid := JID, sid := SID, lang := Lang} = State) ->
  {_LUser, LServer, _} = jid:tolower(JID),
  Proc = gen_mod:get_module_proc(LServer, ?MODULE),
  gen_server:cast(Proc, {maybe_kick, {JID, Lang, SID}}),
  State.

maybe_kick(JID , Lang, {_TS,PID}, LastTS) ->
  {LUser, LServer, _} = jid:tolower(JID),
  Res = case use_cache(LServer) of
          true ->
            ets_cache:lookup(
              ?BLOCK_USERS_CACHE, {LUser, LServer},
              fun() -> ?MODULE:get_user(LUser, LServer) end);
          false ->
            get_user(LUser, LServer);
          undefined ->
            error
        end,
  case Res of
    {ok, Reason} ->
      Result = maybe_notify(JID, Reason, LastTS),
      xmpp_stream_in:send(PID, xmpp:serr_policy_violation(Reason, Lang)),
      Result;
    _ ->
      ok
  end.

maybe_notify(JID, Reason, LastTS) ->
  EarlierThan = seconds_since_epoch() - ?DELAY,
  if
    LastTS < EarlierThan ->
      From = jid:make(<<>>,JID#jid.lserver),
      ErrMsg = #message{type = chat, from = From, to = JID,
        id = randoms:get_string(), body = [#text{lang = <<>>, data = Reason}]},
      ejabberd_router:route(ErrMsg),
      {ok, seconds_since_epoch()};
    true ->
      ok
  end.

block_user(User, Server, Reason) ->
  LUser = jid:nodeprep(User),
  LServer = jid:nameprep(Server),
  case use_cache(LServer) of
    true ->
      ets_cache:update(
        ?BLOCK_USERS_CACHE, {LUser, LServer}, {ok, Reason},
        fun() ->
          ?MODULE:store_user(LUser, LServer, Reason)
        end, cache_nodes(LServer));
    false ->
      store_user(LUser, LServer, Reason)
  end,
  From = jid:make(<<>>,LServer),
  To = jid:make(LUser,LServer),
  Msg = #message{type = chat, from = From, to = To,
    id = randoms:get_string(), body = [#text{lang = <<>>, data = Reason}]},
  ejabberd_router:route(Msg),
  ejabberd_sm:kick_user(User,Server).

unblock_user(User, Server) ->
  LUser = jid:nodeprep(User),
  LServer = jid:nameprep(Server),
  remove_user(LUser,LServer),
  Proc = gen_mod:get_module_proc(LServer, ?MODULE),
  gen_server:cast(Proc, {delete_last, {LUser, LServer}}),
  ets_cache:delete(?BLOCK_USERS_CACHE, {LUser, LServer}, cache_nodes(LServer)).

-spec init_cache(binary(), gen_mod:opts()) -> ok.
init_cache(Host, Opts) ->
  case use_cache(Host) of
    true ->
      CacheOpts = cache_opts(Opts),
      ets_cache:new(?BLOCK_USERS_CACHE, CacheOpts);
    false ->
      ets_cache:delete(?BLOCK_USERS_CACHE)
  end.

-spec use_cache(binary()) -> boolean().
use_cache(Host) ->
  gen_mod:get_module_opt(Host, ?MODULE, use_cache).

-spec cache_opts(gen_mod:opts()) -> [proplists:property()].
cache_opts(Opts) ->
  MaxSize = gen_mod:get_opt(cache_size, Opts),
  CacheMissed = gen_mod:get_opt(cache_missed, Opts),
  LifeTime = case gen_mod:get_opt(cache_life_time, Opts) of
               infinity -> infinity;
               I -> timer:seconds(I)
             end,
  [{max_size, MaxSize}, {cache_missed, CacheMissed}, {life_time, LifeTime}].

-spec cache_nodes(binary()) -> [node()].
cache_nodes(_Host) ->
  ejabberd_cluster:get_nodes().

start(Host, Opts) ->
  gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
  gen_mod:stop_child(?MODULE, Host).


reload(_Host, _NewOpts, _OldOpts) ->
  ok.

depends(_Host, _Opts) ->
  [].

mod_opt_type(O) when O == cache_life_time; O == cache_size ->
  fun (I) when is_integer(I), I > 0 -> I;
    (infinity) -> infinity
  end;
mod_opt_type(O) when O == use_cache; O == cache_missed ->
  fun (B) when is_boolean(B) -> B end.

mod_options(Host) ->
  [{use_cache, ejabberd_config:use_cache(Host)},
    {cache_size, ejabberd_config:cache_size(Host)},
    {cache_missed, ejabberd_config:cache_missed(Host)},
    {cache_life_time, ejabberd_config:cache_life_time(Host)}].

-spec seconds_since_epoch() -> non_neg_integer().
seconds_since_epoch() ->
  {Mega, Secs, _} = os:timestamp(),
  Mega * 1000000 + Secs.

%% SQL

sql_get_user(LUser, LServer) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(message)s from blocked_users "
    " where username = %(LUser)s and %(LServer)H")) of
    {selected, [{Message}]} ->
      {ok, Message};
    _ ->
      error
  end.

sql_store_user(LUser, LServer, Message) ->
  ?SQL_UPSERT(LServer,"blocked_users",
    ["!username=%(LUser)s",
      "!server_host=%(LServer)s",
      "message=%(Message)s"]).

sql_remove_user(LUser,LServer) ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from blocked_users"
    " where username = %(LUser)s and %(LServer)H")).
