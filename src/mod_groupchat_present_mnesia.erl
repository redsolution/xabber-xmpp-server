%%%-------------------------------------------------------------------
%%% File    : mod_groupchat_present_mnesia.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Watch for online activity in group chats
%%% Created : 05 Oct 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
%%%
%%%
%%% xabberserver, Copyright (C) 2007-2019   Redsolution OÜ
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

-module(mod_groupchat_present_mnesia).
-author('andrey.gagarin@redsolution.com').
-behaviour(gen_mod).
-behaviour(gen_server).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
%% gen_mod callbacks
-export([stop/1,start/2,depends/2,mod_options/1,
  init/0,start_link/0
]).
%% API
-export([
  get_chat_sessions/0,set_session/3,delete_session/1, select_sessions/2, delete_session/3, delete_all_user_sessions/2
]).
-record(state, {}).
-include("mod_groupchat_present.hrl").
-include("logger.hrl").
%%====================================================================
%% gen_mod callbacks
%%====================================================================
start(Host, Opts) ->
  init([Host, Opts]),
  gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
  supervisor:terminate_child(ejabberd_sup, ?MODULE),
  supervisor:delete_child(ejabberd_sup, ?MODULE),
  gen_mod:stop_child(?MODULE, Host).

depends(_Host, _Opts) ->
  [].

mod_options(_Opts) -> [].

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
-spec init() -> ok | {error, any()}.
init() ->
  Spec = {?MODULE, {?MODULE, start_link, []},
    transient, 5000, worker, [?MODULE]},
  case supervisor:start_child(ejabberd_backend_sup, Spec) of
    {ok, _Pid} -> ok;
    Err -> Err
  end.

-spec start_link() -> {ok, pid()} | {error, any()}.
start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get_chat_sessions() -> [#chat_session{}].
get_chat_sessions() ->
  select_sessions('_','_').

-spec set_session(binary(),binary(),binary()) -> ok.
set_session(Resource, User, ChatJid) ->
  case select_session(Resource,User,ChatJid) of
    [] ->
      From = jid:replace_resource(jid:from_string(User),Resource),
      To = jid:from_string(ChatJid),
      PID = spawn(mod_groupchat_presence, delete_session_from_counter_after, [To, From, 30000]),
      Session = #chat_session{
        id = PID,
        resource =  Resource,
        user = User,
        chat = ChatJid
      },
      mnesia:dirty_write(Session);
    [#chat_session{id = PID} = SS] ->
      exit(PID, kill),
      delete_session(SS),
      From = jid:replace_resource(jid:from_string(User),Resource),
      To = jid:from_string(ChatJid),
      NEWPID = spawn(mod_groupchat_presence, delete_session_from_counter_after, [To, From, 30000]),
      Session = #chat_session{
        id = NEWPID,
        resource =  Resource,
        user = User,
        chat = ChatJid
      },
      mnesia:dirty_write(Session);
    _ ->
      ok
  end.

delete_session(Resource,Username,Chat) ->
  S = select_session(Resource,Username,Chat),
  lists:foreach(fun(N) -> delete_session(N) end, S).

-spec delete_session(#chat_session{}) -> ok.
delete_session(#chat_session{} = S) ->
  mnesia:dirty_delete_object(S).

select_session(Resource,User,Chat) ->
  FN = fun()->
    mnesia:match_object(chat_session,
      {chat_session, '_', Resource, User, Chat},
      read)
       end,
  {atomic,Session} = mnesia:transaction(FN),
  Session.

select_sessions(User,Chat) ->
 FN = fun()->
   mnesia:match_object(chat_session,
     {chat_session, '_', '_', User, Chat},
     read)
      end,
  {atomic,Sessions} = mnesia:transaction(FN),
  Sessions.

delete_all_user_sessions(User,Chat) ->
  Sessions = select_sessions(User,Chat),
  lists:foreach(fun(Session) ->
  delete_session(Session) end, Sessions).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([_Host,_Opts]) ->
  ejabberd_mnesia:create(?MODULE, chat_session,
    [{disc_only_copies, [node()]},
      {attributes, record_info(fields, chat_session)}]),
  clean_tables(),
  {ok, #state{}}.

handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info({mnesia_system_event, {mnesia_down, _Node}}, State) ->
  Sessions =
    select_sessions('_','_'),
  lists:foreach(
    fun(S) ->
      mnesia:dirty_delete_object(S)
    end, Sessions),
  {noreply, State};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
clean_tables() ->
  Sessions =
    select_sessions('_','_'),
  lists:foreach(
    fun(S) ->
      mnesia:dirty_delete_object(S)
    end, Sessions).