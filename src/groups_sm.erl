%%%-------------------------------------------------------------------
%%% @author Andrey Gagarin andrey.gagarin@redsolution.ru
%%% @copyright (C) 2020, Redsolution Inc.
%%% @doc
%%%
%%% @end
%%% Created : 20. нояб. 2020 11:48
%%%-------------------------------------------------------------------
-module(groups_sm).
-author("andrey.gagarin@redsolution.ru").

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
  code_change/3]).
-export([activate/2, deactivate/2]).
-define(SERVER, ?MODULE).
-define(MYHOSTS, ejabberd_config:get_myhosts()).
-record(xabber_sm_state, {pid = <<>>}).
-include("logger.hrl").
-include("xmpp.hrl").
%%%===================================================================
%%% API
%%%===================================================================

%% @doc Spawns the server and registers the local name (unique)
-spec(start_link() ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


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
handle_call(_Request, _From, State = #xabber_sm_state{}) ->
  {reply, ok, State}.

%% @private
%% @doc Handling cast messages
-spec(handle_cast(Request :: term(), State :: #xabber_sm_state{}) ->
  {noreply, NewState :: #xabber_sm_state{}} |
  {noreply, NewState :: #xabber_sm_state{}, timeout() | hibernate} |
  {stop, Reason :: term(), NewState :: #xabber_sm_state{}}).
handle_cast({group_created,Server, GroupLocalPart}, #xabber_sm_state{pid = PID} = State) ->
  SID = {p1_time_compat:unique_timestamp(), PID},
  ejabberd_sm:open_session(SID, GroupLocalPart, Server, <<"Group">>, 50, [{group, true}]),
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
handle_info({route, #presence{} = Packet}, State = #xabber_sm_state{}) ->
  mod_groups_presence:process_presence(Packet),
  {noreply, State};
handle_info({route, #iq{} = Packet}, State = #xabber_sm_state{}) ->
  mod_groups_iq_handler:make_action(Packet),
  {noreply, State};
handle_info({route, #message{} = Packet}, State = #xabber_sm_state{}) ->
  {LUser, LServer, _} = jid:tolower(Packet#message.to),
  ProcName = binary_to_atom(<<LUser/binary,$_,LServer/binary,"_messages">>, utf8),
  Proc = case whereis(ProcName) of
           undefined ->
             PID = spawn(mod_groups_messages,process_messages,[]),
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
      Groups = mod_groups_chats:get_all(Host),
      start_entities(Groups,Host,Pid,<<"Group">>)
    catch
        _:Why ->
          ?ERROR_MSG("Group sessions cannot be started: ~p",[Why])
    end
                end, ?MYHOSTS).

start_entities(Chats,Server,Pid,Resource) ->
  lists:foreach(fun(C) ->
    {Chat} = C,
    SID = {p1_time_compat:unique_timestamp(), Pid},
    ejabberd_sm:open_session(SID, Chat, Server, Resource, 50, [{group, true}]) end, Chats).

activate(Server, GroupLocalPart) ->
  gen_server:cast(?MODULE, {group_created,Server,GroupLocalPart}).

deactivate(Server, GroupLocalPart) ->
  gen_server:cast(?MODULE, {group_deleted,Server,GroupLocalPart}).
