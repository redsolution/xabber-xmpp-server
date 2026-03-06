%%%-------------------------------------------------------------------
%%% File    : groups_sm.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%  Purpose : Group session management.
%%% Created : 22 Jan 2026 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%%
%%%
%%% xabberserver, Copyright (C) 2007-2026   redsolution corp
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
-module(groups_sm).
-author('ilya.kalashnikov@redsolution.com').
-behaviour(gen_server).

-include("logger.hrl").
-include("xmpp.hrl").

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

%% API
-export([start_link/0]).
-export([activate/3, deactivate/2, update_group_session_info/2]).

-record(xabber_sm_state, {pid = <<>>}).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Spawns the server and registers the local name (unique)
-spec(start_link() ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
%% @doc Initializes the server
-spec(init(Args :: term()) ->
  {ok, State :: #xabber_sm_state{}} | {ok, State :: #xabber_sm_state{}, timeout() | hibernate} |
  {stop, Reason :: term()} | ignore).
init([]) ->
  Pid = self(),
  start_entities(Pid),
  {ok, #xabber_sm_state{pid = Pid}}.

%% @private
%% @doc Handling call messages

-spec(handle_call(Request :: term(), From :: {pid(), Tag :: term()},
    State :: #xabber_sm_state{}) ->
  {reply, Reply :: term(), NewState :: #xabber_sm_state{}} |
  {reply, Reply :: term(), NewState :: #xabber_sm_state{}, timeout() | hibernate} |
  {noreply, NewState :: #xabber_sm_state{}} |
  {noreply, NewState :: #xabber_sm_state{}, timeout() | hibernate} |
  {stop, Reason :: term(), Reply :: term(), NewState :: #xabber_sm_state{}} |
  {stop, Reason :: term(), NewState :: #xabber_sm_state{}}).
handle_call({set_session_info, LUser, LServer, Info}, _, State) ->
  Info1 = if is_list(Info) -> Info; true -> maps:to_list(Info) end,
  lists:foreach(
    fun({Key, Val}) ->
      ejabberd_sm:set_user_info(LUser, LServer, <<"Group">>, Key, Val)
    end, Info1),
  {reply, ok, State};
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

%% @private
%% @doc Handling cast messages
-spec(handle_cast(Request :: term(), State :: #xabber_sm_state{}) ->
  {noreply, NewState :: #xabber_sm_state{}} |
  {noreply, NewState :: #xabber_sm_state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #xabber_sm_state{}}).
handle_cast({group_created, Server, GroupLocalPart, Info}, #xabber_sm_state{pid = PID} = State) ->
  SID = {p1_time_compat:unique_timestamp(), PID},
  Info1 = maps:to_list(Info) ++ [{group, true}],
  ejabberd_sm:open_session(SID, GroupLocalPart, Server,
    <<"Group">>, 50, Info1),
  {noreply, State};
handle_cast({group_deleted,Server, GroupLocalPart},State) ->
  SID = ejabberd_sm:get_session_sid(GroupLocalPart, Server, <<"Group">>),
  ejabberd_sm:close_session(SID, GroupLocalPart, Server, <<"Group">>),
  {noreply, State};
handle_cast(_Request, State = #xabber_sm_state{}) ->
  {noreply, State}.

%% @private
%% @doc Handling all non call/cast messages
-spec(handle_info(Info :: timeout() | term(), State :: #xabber_sm_state{}) ->
  {noreply, NewState :: #xabber_sm_state{}} |
  {noreply, NewState :: #xabber_sm_state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #xabber_sm_state{}}).
handle_info({route, #presence{to = To} = Packet}, State) ->
  Proc = gen_mod:get_module_proc(To#jid.lserver, groups_presences),
  gen_server:cast(Proc, Packet),
  {noreply, State};
handle_info({route, #iq{to = To} = Iq}, State) ->
  try xmpp:decode_els(Iq) of
    DecodedIq ->
      Proc = gen_mod:get_module_proc(To#jid.lserver,
        groups_iq_handler),
      gen_server:cast(Proc, DecodedIq)
  catch _:_ ->
    ?ERROR_MSG("Decoding error ~p",[Iq])
  end,
  {noreply, State};
handle_info({route, #message{} = Packet}, State) ->
  {LUser, LServer, _} = jid:tolower(Packet#message.to),
  ProcName = binary_to_atom(<<LUser/binary,$_,LServer/binary,"_messages">>, utf8),
  Proc = case whereis(ProcName) of
           undefined ->
             PID = spawn(groups_messages, process_messages, []),
             register(ProcName, PID),
             PID;
            PID ->
              PID
  end,
  Proc ! {message, Packet},
  {noreply, State};
handle_info(_Info, State = #xabber_sm_state{}) ->
  {noreply, State}.

%% @private
%% @doc This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
-spec(terminate(Reason :: (normal | shutdown | {shutdown, term()} | term()),
    State :: #xabber_sm_state{}) -> term()).
terminate(_Reason, _State = #xabber_sm_state{}) ->
  ok.

%% @private
%% @doc Convert process state when code is changed
-spec(code_change(OldVsn :: term() | {down, term()}, State :: #xabber_sm_state{},
    Extra :: term()) ->
  {ok, NewState :: #xabber_sm_state{}} | {error, Reason :: term()}).
code_change(_OldVsn, State = #xabber_sm_state{}, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

start_entities(Pid) ->
  lists:foreach(fun(Host) ->
    try
      Groups = groups_groups:get_all_groups_info(Host),
      start_entities(Groups, Pid)
    catch
        _:Why ->
          ?ERROR_MSG("Group sessions cannot be started: ~p",[Why])
    end
                end, ejabberd_config:get_myhosts()).

start_entities(GroupsInfo, Pid) ->
  lists:foreach(fun({{LUser, LServer, Resource}, Info}) ->
    Info1 = maps:to_list(Info),
    SID = {p1_time_compat:unique_timestamp(), Pid},
    ejabberd_sm:open_session(SID, LUser, LServer, Resource,
      50, Info1) end, GroupsInfo).

%%%===================================================================
%%% API
%%%===================================================================


activate(Server, GroupLocalPart, Info) ->
  gen_server:cast(?MODULE, {group_created,Server,GroupLocalPart, Info}).

deactivate(Server, GroupLocalPart) ->
  gen_server:cast(?MODULE, {group_deleted,Server,GroupLocalPart}).

update_group_session_info(Group, InfoMap) ->
  {LUser, LServer, _} = jid:tolower(jid:from_string(Group)),
  gen_server:call(?MODULE, {set_session_info, LUser, LServer, InfoMap}).
