%%%-------------------------------------------------------------------
%%% File    : mod_sync.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : XEP:  Fast Client Synchronization
%%% Created : 21 May 2019 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_sync).
-author('andrey.gagarin@redsolution.com').

-behaviour(gen_mod).
-behavior(gen_server).
-compile([{parse_transform, ejabberd_sql_pt}]).

-protocol({xep, '0CCC', '0.9.0'}).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-include("mod_roster.hrl").

%% gen_mod callbacks.
-export([start/2,stop/1,reload/3,depends/2,mod_options/1]).

%% gen_server callbacks.
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

%% hooks
-export([c2s_stream_features/2, sm_receive_packet/1, user_send_packet/1,
  process_messages/0, remove_user/2]).

%% iq
-export([process_iq/1]).

% syncronization_query hook
-export([create_synchronization_metadata/13]).
-type c2s_state() :: ejabberd_c2s:state().

% API
-export([is_muted/3, is_muted/4]).

%% records
-record(state, {
  host = <<"">> :: binary(),
  eg_last_message=[] :: list(),
  eg_last_retract=[] :: list()
}).

-record(external_group_last_msg,
{
  group = {<<"">>, <<"">>}             :: {binary(), binary()} | '_',
  id = <<>>                            :: binary() | '_',
  user_id = <<>>                       :: binary() | '_',
  packet = #xmlel{}                    :: xmlel() | message() | '_',
  retract_version = <<>>               :: binary() | '_'
}
).

-record(external_group_msgs,
{
  group_sid = {{<<"">>, <<"">>}, <<"">>}  :: {{binary(), binary()}, binary()} | '_',
  uid = <<>>                              :: binary() | '_',
  ts = <<>>                               :: binary() | '_',
  deleted = false                         :: boolean() | '_'
}).

-type(us_peer() ::{{binary(), binary()}, {binary(), binary()}}).
-record(sync_data,
{
  us_peer             :: us_peer() | '_',
  call_ts             :: non_neg_integer() | '_',
  call_msg            :: xmlel() | message() | '_',
  card                :: xmlel() | '_',
  invite              :: binary() | '_'
}
).

-define(TABLE_SIZE_LIMIT, 2000000000). % A bit less than 2 GiB.
-define(NS_XABBER_CHAT, <<"urn:xabber:chat">>).
-define(NS_OMEMO, <<"urn:xmpp:omemo:2">>).
-define(AUTO_CLEAN_INTERVAL, 43200000). % 12 hours

%%--------------------------------------------------------------------
%% gen_mod callbacks.
%%--------------------------------------------------------------------
-spec start(binary(), gen_mod:opts()) -> ok.
start(Host, Opts) ->
  gen_mod:start_child(?MODULE, Host, Opts).

-spec stop(binary()) -> ok.
stop(Host) ->
  gen_mod:stop_child(?MODULE, Host).

-spec reload(binary(), gen_mod:opts(), gen_mod:opts()) -> ok.
reload(Host, NewOpts, OldOpts) ->
  NewMod = gen_mod:db_mod(Host, NewOpts, ?MODULE),
  OldMod = gen_mod:db_mod(Host, OldOpts, ?MODULE),
  if NewMod /= OldMod ->
    NewMod:init(Host, NewOpts);
    true ->
      ok
  end.

-spec depends(binary(), gen_mod:opts()) -> [{module(), hard | soft}].
depends(_Host, _Opts) ->
  [].

mod_options(_Host) ->
  [].

%%--------------------------------------------------------------------
%% gen_server callbacks.
%%--------------------------------------------------------------------
init([Host, _Opts]) ->
  ejabberd_mnesia:create(?MODULE, sync_data,
    [{disc_only_copies, [node()]},
      {type, set},
      {attributes, record_info(fields, sync_data)}]),
  ejabberd_mnesia:create(?MODULE, external_group_last_msg,
    [{disc_only_copies, [node()]},
      {type, set},
      {attributes, record_info(fields, external_group_last_msg)}]),
  ejabberd_mnesia:create(?MODULE, external_group_msgs,
    [{disc_only_copies, [node()]},
      {type, set},
      {attributes, record_info(fields, external_group_msgs)}]),
  register_iq_handlers(Host),
  register_hooks(Host),
  erlang:send_after(?AUTO_CLEAN_INTERVAL + rand:uniform(10) * 3600000,
    self(), {'delete_read_messages', Host}),
  {ok, #state{host = Host}}.

terminate(_Reason, State) ->
  Host = State#state.host,
  unregister_hooks(Host),
  unregister_iq_handlers(Host).

handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast({eg_save_message, Record , TS, IsService},
    #state{eg_last_message = Acc} = State) ->
%% Acc stores last N saved messages
%% to prevent overwrites in the database of the same message
  #external_group_last_msg{group = {GUser, GServer},id = StanzaID,
    user_id = UserID} = Record,
  Group_SID = {{GUser, GServer}, StanzaID},
  Acc1 = case lists:member(Group_SID, Acc) of
           true -> Acc;
           _ ->
             eg_store_last_msg(Record),
             case IsService of
               false -> eg_store_message1(Group_SID, UserID , TS);
               _ -> ok
             end,
             save_last_action(Acc, Group_SID)
          end,
  {noreply, State#state{eg_last_message = Acc1}};
handle_cast({eg_change_last_message, Group, Replace},
    #state{eg_last_retract = Acc} = State)->
  ID = integer_to_binary(Replace#xabber_replace.id),
  Ver = integer_to_binary(Replace#xabber_replace.version),
  Acc1 = case lists:member({Group, ID, Ver}, Acc) of
           true -> Acc;
           _->
             case mnesia:dirty_read(external_group_last_msg, Group) of
               [#external_group_last_msg{retract_version = Ver, id = ID}] ->
                 ok;
               [#external_group_last_msg{id = ID} = Record] ->
                 eg_change_last_msg(Replace, Record);
               _ ->
                 ok
             end,
             save_last_action(Acc, {Group, ID, Ver})
         end,
  {noreply, State#state{eg_last_retract = Acc1}};
handle_cast({eg_delete_msg, _, <<>>, <<>>, _}, State) ->
  {noreply, State};
handle_cast({eg_delete_msg, Group, ID, <<>>, Ver},
    #state{eg_last_retract = Acc} = State) ->
  Acc1 = eg_remove_message(Acc, Group, ID, <<>>, Ver),
  {noreply,  State#state{eg_last_retract = Acc1}};
handle_cast({eg_delete_msg, Group, <<>>, UserID, Ver},
    #state{eg_last_retract = Acc} = State) ->
  Acc1 = eg_remove_message(Acc, Group, <<>>, UserID, Ver),
  {noreply, State#state{eg_last_retract = Acc1}};
handle_cast({eg_delete_msg, Group, all, all, Ver},
    #state{eg_last_retract = Acc} = State) ->
  Acc1 = eg_remove_message(Acc, Group, all, all, Ver),
  {noreply, State#state{eg_last_retract = Acc1}};
handle_cast({send_push, LUser, LServer, PushType, PushPayload}, State) ->
  ejabberd_hooks:run(xabber_push_notification,
    LServer, [PushType, LUser,LServer, PushPayload]),
  {noreply, State};
handle_cast({send_push, LUser, LServer, Conversation, CType, PushType, PushPayload}, State) ->
  Mute =  is_muted(LUser,LServer, Conversation, CType),
  case Mute of
    false ->
      ejabberd_hooks:run(xabber_push_notification,
        LServer, [PushType, LUser,LServer, PushPayload]);
    _ ->
      pass
  end,
  {noreply, State};
handle_cast({user_send, #iq{from = From, to = To} = IQ}, State) ->
  case xmpp:has_subtag(IQ,#xabbergroup_decline{}) of
    true ->
      {LUser, LServer,_} = jid:tolower(From),
      {PUser, PServer,_} = jid:tolower(To),
      delete_invite(LUser,LServer,PUser,PServer),
      deactivate_conversation(LServer,LUser,
        #xabber_conversation{jid = jid:make(PUser,PServer),
          type = ?NS_GROUPCHAT});
    _ -> ok
  end,
  {noreply, State};
handle_cast({user_send, #presence{type = Type, from = From, to = To}}, State)
  when Type == subscribe orelse Type == subscribed  ->
  {LUser, LServer,_} = jid:tolower(From),
  {PUser, PServer,_} = jid:tolower(To),
  delete_invite(LUser,LServer,PUser,PServer),
  {noreply, State};
handle_cast({user_send, #presence{type = unsubscribe, from = From, to = To}}, State) ->
  {LUser, LServer,_} = jid:tolower(From),
  {PUser, PServer,_} = jid:tolower(To),
  maybe_delete_invite_and_conversation(LUser,LServer,PUser,PServer),
  {noreply, State};
handle_cast({user_send, #presence{type = unsubscribed, from = From, to = To}}, State) ->
  {LUser, LServer,_} = jid:tolower(From),
  maybe_delete_invite_or_presence(LUser, LServer, To),
  {noreply, State};
handle_cast({sm, #presence{type = subscribe,from = From,
  to = #jid{lserver = LServer, luser = LUser}} = Presence},State) ->
  case mod_xabber_entity:is_group(LUser, LServer) of
    false ->
      X = xmpp:get_subtag(Presence, #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT}),
      {Type, GroupInfo} =
        case X of
          false ->
            maybe_push_notification(LUser, LServer,jid:to_string(jid:remove_resource(From)),
              ?NS_XABBER_CHAT,<<"subscribe">>,#presence{type = subscribe, from = From}),
            {?NS_XABBER_CHAT, <<>>};
          _ ->
            Privacy = get_privacy(xmpp:get_subtag(X, #xabbergroupchat_privacy{})),
            Parent = X#xabbergroupchat_x.parent,
            Info = case Parent of
                     undefined -> Privacy;
                     _ -> <<Privacy/binary,$,,(jid:to_string(Parent))/binary>>
                   end,
            {?NS_GROUPCHAT, Info}
        end,
      Conversation = jid:to_string(jid:remove_resource(From)),
      create_conversation(LServer,LUser,Conversation,<<"">>,false,Type,GroupInfo);
    _ ->
      ok
  end,
  {noreply, State};
handle_cast({sm, #presence{type = unsubscribe,from = From, to = To}},State) ->
  {LUser, LServer,_} = jid:tolower(To),
  maybe_delete_invite_or_presence(LUser, LServer, From),
  {noreply, State};
handle_cast({sm, #presence{type = unsubscribed, from = From, to = To}},State) ->
  {LUser, LServer,_} = jid:tolower(To),
  {PUser, PServer,_} = jid:tolower(From),
  maybe_delete_invite_and_conversation(LUser,LServer,PUser,PServer),
  {noreply, State};
handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info({'delete_read_messages', Host}, State) ->
  eg_delete_read_messages(Host),
  erlang:send_after(?AUTO_CLEAN_INTERVAL + rand:uniform(10) * 3600000,
    self(), {'delete_read_messages', Host}),
  {noreply, State};
handle_info(_Info, State) ->
  {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%--------------------------------------------------------------------
%% Hooks handlers.
%%--------------------------------------------------------------------
register_hooks(Host) ->
  ejabberd_hooks:add(syncronization_query, Host, ?MODULE,
    create_synchronization_metadata, 60),
  ejabberd_hooks:add(user_send_packet, Host, ?MODULE,
    user_send_packet, 101),
  ejabberd_hooks:add(sm_receive_packet, Host, ?MODULE,
    sm_receive_packet, 55),
  ejabberd_hooks:add(c2s_post_auth_features, Host, ?MODULE,
    c2s_stream_features, 50),
  ejabberd_hooks:add(remove_user, Host, ?MODULE,
    remove_user, 60).

unregister_hooks(Host) ->
  ejabberd_hooks:delete(syncronization_query, Host, ?MODULE,
    create_synchronization_metadata, 60),
  ejabberd_hooks:delete(user_send_packet, Host, ?MODULE,
    user_send_packet, 101),
  ejabberd_hooks:delete(sm_receive_packet, Host, ?MODULE,
    sm_receive_packet, 55),
  ejabberd_hooks:delete(c2s_post_auth_features, Host, ?MODULE,
    c2s_stream_features, 50),
  ejabberd_hooks:delete(remove_user, Host, ?MODULE,
    remove_user, 60).

c2s_stream_features(Acc, Host) ->
  case gen_mod:is_loaded(Host, ?MODULE) of
    true ->
      [#xabber_synchronization{}|Acc];
    false ->
      Acc
  end.

-spec sm_receive_packet(stanza()) -> stanza().
sm_receive_packet(#message{to = #jid{luser = LUser, lserver = LServer}} = Pkt) ->
  Proc = get_subprocess(LUser,LServer),
  Proc ! {in, Pkt},
  Pkt;
sm_receive_packet(#presence{to = #jid{lserver = LServer}} = Pkt) ->
  send_cast(LServer, {sm,Pkt}),
  Pkt;
sm_receive_packet(Acc) ->
  Acc.

-spec user_send_packet({stanza(), c2s_state()})
      -> {stanza(), c2s_state()}.
user_send_packet({#message{} = Pkt, #{user := LUser, lserver := LServer}} = Acc) ->
  Proc = get_subprocess(LUser,LServer),
  Proc ! {out, Pkt},
  Acc;
user_send_packet({#presence{} = Pkt, #{lserver := LServer}} = Acc) ->
  send_cast(LServer, {user_send,Pkt}),
  Acc;
user_send_packet({#iq{type = set} = Pkt, #{lserver := LServer}} = Acc) ->
  send_cast(LServer, {user_send,Pkt}),
  Acc;
user_send_packet(Acc) ->
  Acc.

-spec remove_user(binary(), binary()) -> ok.
remove_user(User, Server) ->
  LUser = jid:nodeprep(User),
  LServer = jid:nameprep(Server),
  delete_sync_data(LUser, LServer),
  delete_conversations(LUser, LServer),
  ok.


%%--------------------------------------------------------------------
%% IQ handlers.
%%--------------------------------------------------------------------
-spec register_iq_handlers(binary()) -> ok.
register_iq_handlers(Host) ->
  gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_XABBER_ARCHIVED,
    ?MODULE, process_iq),
  gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_XABBER_PINNED,
    ?MODULE, process_iq),
  gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_XABBER_SYNCHRONIZATION,
    ?MODULE, process_iq).

-spec unregister_iq_handlers(binary()) -> ok.
unregister_iq_handlers(Host) ->
  gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_XABBER_ARCHIVED),
  gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_XABBER_PINNED),
  gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_XABBER_SYNCHRONIZATION).

process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = get,
  sub_els = [#xabber_synchronization_query{stamp = undefined, rsm = undefined}  = Query],
  lang = Lang} = IQ) ->
  SyncQuery = parse_query(Query,Lang),
  case SyncQuery of
    {ok,Form} ->
      Sync = make_result(LServer, LUser, <<"0">>, undefined, Form),
      xmpp:make_iq_result(IQ,Sync);
    {error,Err} ->
      xmpp:make_error(IQ, Err);
    _ ->
      xmpp:make_error(IQ, xmpp:err_bad_request())
  end;
process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = get,
  sub_els = [#xabber_synchronization_query{stamp = <<>>, rsm = undefined} = Query],
  lang = Lang} = IQ) ->
  SyncQuery = parse_query(Query,Lang),
  case SyncQuery of
    {ok,Form} ->
      Sync = make_result(LServer, LUser, <<"0">>, undefined, Form),
      xmpp:make_iq_result(IQ,Sync);
    {error,Err} ->
      xmpp:make_error(IQ, Err);
    _ ->
      xmpp:make_error(IQ, xmpp:err_bad_request())
  end;
process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = get,
  sub_els = [#xabber_synchronization_query{stamp = Stamp, rsm = undefined}  = Query],
  lang = Lang} = IQ) ->
  SyncQuery = parse_query(Query,Lang),
  case SyncQuery of
    {ok,Form} ->
      Sync = make_result(LServer, LUser, Stamp, undefined, Form),
      xmpp:make_iq_result(IQ,Sync);
    {error,Err} ->
      xmpp:make_error(IQ, Err);
    _ ->
      xmpp:make_error(IQ, xmpp:err_bad_request())
  end;
process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = get,
  sub_els = [#xabber_synchronization_query{stamp = undefined, rsm = RSM} = Query],
  lang = Lang} = IQ) ->
  SyncQuery = parse_query(Query,Lang),
  case SyncQuery of
    {ok,Form} ->
      Sync = make_result(LServer, LUser, <<"0">>, RSM, Form),
      xmpp:make_iq_result(IQ,Sync);
    {error,Err} ->
      xmpp:make_error(IQ, Err);
    _ ->
      xmpp:make_error(IQ, xmpp:err_bad_request())
  end;
process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = get,
  sub_els = [#xabber_synchronization_query{stamp = <<>>, rsm = RSM} = Query],
  lang = Lang} = IQ) ->
  SyncQuery = parse_query(Query,Lang),
  case SyncQuery of
    {ok,Form} ->
      Sync = make_result(LServer, LUser, <<"0">>, RSM, Form),
      xmpp:make_iq_result(IQ,Sync);
    {error,Err} ->
      xmpp:make_error(IQ, Err);
    _ ->
      xmpp:make_error(IQ, xmpp:err_bad_request())
  end;
process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = get,
  sub_els = [#xabber_synchronization_query{stamp = Stamp, rsm = RSM} = Query],
  lang = Lang} = IQ) ->
  SyncQuery = parse_query(Query, Lang),
  case SyncQuery of
    {ok,Form} ->
      Sync = make_result(LServer, LUser, Stamp, RSM, Form),
      xmpp:make_iq_result(IQ,Sync);
    {error,Err} ->
      xmpp:make_error(IQ, Err);
    _ ->
      xmpp:make_error(IQ, xmpp:err_bad_request())
  end;
process_iq(#iq{type = set, sub_els = [#xabber_synchronization_query{
  sub_els = [#xabber_conversation{status = undefined,
    mute = undefined, pinned = undefined} ]}]} = IQ) ->
  xmpp:make_error(IQ, xmpp:err_bad_request());
process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = set,
  sub_els = [#xabber_synchronization_query{
    sub_els = [#xabber_conversation{status = Status,
      mute = undefined, pinned = undefined} = Conversation]}]} = IQ) ->
  Result = case Status of
             deleted ->
               deactivate_conversation(LServer, LUser,Conversation);
             archived ->
               archive_conversation(LServer, LUser, Conversation);
             active ->
               activate_conversation(LServer, LUser, Conversation);
             _ ->
               {error, xmpp:err_bad_request()}
           end,
  iq_result(IQ,Result);
process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = set,
  sub_els = [#xabber_synchronization_query{
    sub_els =[#xabber_conversation{
      mute = undefined, pinned = Order} = Conversation]}]} = IQ) when Order /= undefined ->
  iq_result(IQ, pin_conversation(LServer, LUser, Conversation));
process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = set,
  sub_els = [#xabber_synchronization_query{
    sub_els =[#xabber_conversation{
      mute = Period, pinned = undefined} = Conversation]}]} = IQ) when Period /= undefined->
  iq_result(IQ, mute_conversation(LServer, LUser, Conversation));
process_iq(IQ) ->
  xmpp:make_error(IQ, xmpp:err_bad_request()).

iq_result(IQ,ok) ->
  xmpp:make_iq_result(IQ);
iq_result(IQ,{error, Err}) ->
  xmpp:make_error(IQ,Err);
iq_result(IQ,_Result) ->
  xmpp:make_error(IQ, xmpp:err_internal_server_error()).

parse_query(#xabber_synchronization_query{xdata = undefined}, _Lang) ->
  {ok, []};
parse_query(#xabber_synchronization_query{xdata = #xdata{}} = Query, Lang) ->
  X = xmpp_util:set_xdata_field(
    #xdata_field{var = <<"FORM_TYPE">>,
      type = hidden, values = [?NS_XABBER_SYNCHRONIZATION]},
    Query#xabber_synchronization_query.xdata),
  try	sync_query:decode(X#xdata.fields) of
    Form -> {ok, Form}
  catch _:{sync_query, Why} ->
    Txt = sync_query:format_error(Why),
    {error, xmpp:err_bad_request(Txt, Lang)}
  end;
parse_query(#xabber_synchronization_query{}, _Lang) ->
  {ok, []}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%--------------------------------------------------------------------
%% Sub process.
%%--------------------------------------------------------------------

-spec get_subprocess(binary(), binary())-> pid().
get_subprocess(User,Server)->
  ProcName = binary_to_atom(<<"mod_sync_msg_heandler_",User/binary,$_,Server/binary>>, utf8),
  case whereis(ProcName) of
    undefined ->
      PID = spawn(?MODULE,process_messages,[]),
      register(ProcName, PID),
      PID;
    PID ->
      PID
  end.

process_messages() ->
  receive
    {Direction,#message{} = Pkt } ->
      process_message(Direction, Pkt),
      process_messages();
    _ ->
      exit(normal)
  after
    300000 -> exit(normal)
  end.

-spec process_message(atom(), stanza()) -> any().
process_message(in, #message{type = chat, body = [], from = From, to = To,
  sub_els = SubEls} = Pkt) ->
  check_voip_msg(in, Pkt),
  DecSubEls = lists:map(fun(El) -> xmpp:decode(El) end, SubEls),
  handle_sub_els(chat,DecSubEls,From,To);
process_message(in, #message{type = chat, from = Peer, to = To,
  meta = #{stanza_id := TS}} = Pkt) ->
  {LUser, LServer, _ } = jid:tolower(To),
  {PUser, PServer, _} = jid:tolower(Peer),
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  Invite = xmpp:get_subtag(Pkt, #xabbergroupchat_invite{}),
  GroupSysMsg = xmpp:get_subtag(Pkt, #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE}),
  GroupMsg = xmpp:get_subtag(Pkt, #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT}),
  Encryption = identify_encryption_type(Pkt),
  IsLocal = lists:member(PServer,ejabberd_config:get_myhosts()),
  Type = if
           Encryption /= false -> Encryption;
           GroupSysMsg /= false orelse GroupMsg /= false ->
             ?NS_GROUPCHAT;
           true -> ?NS_XABBER_CHAT
         end,
  if
    Invite  =/= false ->
      #xabbergroupchat_invite{jid = ChatJID} = Invite,
      case ChatJID of
        undefined ->
          %% Bad invite
          ok;
        _ ->
          Chat = jid:to_string(jid:remove_resource(ChatJID)),
          store_invite(LUser, LServer, ChatJID, integer_to_binary(TS)),
          create_conversation(LServer,LUser,Chat,<<>>,false,?NS_GROUPCHAT,<<>>),
          maybe_push_notification(LUser,LServer,Conversation,?NS_XABBER_CHAT,
            <<"message">>,#stanza_id{id = integer_to_binary(TS), by = jid:remove_resource(To)})
      end;
    Type == ?NS_GROUPCHAT; Type == ?NS_CHANNELS ->
      FilPacket = filter_packet(Pkt,jid:remove_resource(Peer)),
      StanzaID = xmpp:get_subtag(FilPacket, #stanza_id{}),
      UTime = xmpp:get_subtag(FilPacket, #unique_time{}),
      if
        %% Bad message
        StanzaID == false; UTime == false -> ok;
        true ->
          SID = StanzaID#stanza_id.id,
          case IsLocal of
            false ->
              MsgTS = ts_to_usec(UTime#unique_time.stamp),
              LastMsg = #external_group_last_msg{group = {PUser, PServer},id = SID,
                user_id =get_user_id(Pkt), packet = Pkt, retract_version = <<>> },
              eg_store_message(LServer, LastMsg, MsgTS);
            _ ->
              ok
          end,
          update_metainfo(LServer,LUser,Conversation, Type),
          maybe_push_notification(LUser,LServer,Conversation,Type,<<"message">>,StanzaID)
      end;
    true ->
      case check_voip_msg(in, Pkt) of
        false ->
          maybe_push_notification(LUser, LServer, Conversation, Type,
            <<"message">>,#stanza_id{id = integer_to_binary(TS),
              by = jid:remove_resource(To)}),
          update_metainfo(LServer, LUser, Conversation, Type);
        _ ->
          ok
      end
  end;
process_message(in, #message{type = headline, body = [], from = From, to = To, sub_els = SubEls})->
  DecSubEls = lists:map(fun(El) -> xmpp:decode(El) end, SubEls),
  handle_sub_els(headline,DecSubEls,From,To);
process_message(out, #message{type = chat, from = #jid{luser =  LUser,lserver = LServer},
  to = To, meta = #{stanza_id := StanzaID, mam_archived := true}} = Pkt)->
  %% Messages for groups should not get here,
  %% because the archive for them should be disabled.
  %% But if this happens, only "metadata_updated_at" will be updated.
  case check_voip_msg(out, Pkt) of
    true -> ok;
    _ ->
      Conversation = jid:to_string(jid:remove_resource(To)),
      Type = case identify_encryption_type(Pkt) of
               false -> not_encrypted;
               NS -> NS
             end,
      update_metainfo(LServer, LUser, Conversation, Type, [{read, StanzaID}]),
      maybe_push_notification(LUser,LServer,<<"outgoing">>,
        #stanza_id{id = integer_to_binary(StanzaID), by = jid:make(LServer)})
  end;
process_message(out, #message{type = chat, from = #jid{luser =  LUser,lserver = LServer},
  to = #jid{luser =  PUser,lserver = PServer}} = Pkt) ->
  case check_voip_msg(out, Pkt) of
    true -> ok;
    _ ->
    Displayed = xmpp:get_subtag(Pkt, #message_displayed{}),
    Conversation = jid:to_string(jid:make(PUser,PServer)),
    Type = case get_conversation_type(LServer,LUser,Conversation) of
             [T] -> T;
             _ -> undefined
           end,

    case Displayed of
      #message_displayed{id = _OriginID} when Type == ?NS_GROUPCHAT ->
        FilPacket = filter_packet(Displayed,jid:make(PUser,PServer)),
        StanzaID = case xmpp:get_subtag(FilPacket, #stanza_id{}) of
                     #stanza_id{id = SID} -> SID;
                     _ ->
                       %% for legacy or bad clients
                       {V, _} = get_group_last_message_id_ts(PUser, PServer),
                       V
                   end,
        case is_local(PServer) of
          true ->
            update_metainfo(read, LServer,LUser,Conversation,
              StanzaID,Type,StanzaID);
          _ ->
            MsgTS = eg_get_message_ts(PUser, PServer, StanzaID),
            update_metainfo(read, LServer,LUser,Conversation,
              StanzaID,Type,MsgTS)
        end,
        maybe_push_notification(LUser,LServer,<<"displayed">>,Displayed);
      #message_displayed{id = OriginID} ->
        BareJID = jid:make(LUser,LServer),
        Displayed2 = filter_packet(Displayed,BareJID),
        StanzaID = get_stanza_id(Displayed2,BareJID,LServer,OriginID),
        Type1 = case Type of
                  undefined ->
                    case mod_mam_sql:is_encrypted(LServer,StanzaID) of
                      {true, NS} -> NS;
                      _-> ?NS_XABBER_CHAT
                    end;
                  _-> Type
                end,
        update_metainfo(read, LServer,LUser,Conversation,
          StanzaID,Type1,StanzaID),
        maybe_push_notification(LUser,LServer,<<"displayed">>,Displayed);
      _ ->
        ok
    end
  end;
process_message(_Direction,_Pkt) ->
  ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

get_conversation_info(LServer, LUser, Conversation, Type) ->
  SServer = ejabberd_sql:escape(LServer),
  SUser = ejabberd_sql:escape(LUser),
  SConversation = ejabberd_sql:escape(Conversation),
  SType = ejabberd_sql:escape(Type),
  HostClause = case ejabberd_sql:use_new_schema() of
                 true ->
                   <<" and server_host='",SServer/binary,"' ">>;
                 _->
                   <<>>
               end,
  Query = [<<"select conversation, retract,type, conversation_thread,
  read_until,read_until_ts, delivered_until, displayed_until, updated_at, status,
  encrypted, pinned, mute, group_info
  from conversation_metadata where username = '">>,SUser,<<"' and
  conversation = '">>,SConversation,<<"' and type = '">>,
    SType,<<"'">>,HostClause,<<";">>],
  case ejabberd_sql:sql_query(LServer, Query) of
    {selected, _, []} ->
      {error, notfound};
    {selected, _, [Res]} ->
      [ConvRes] = convert_result([Res]),
      make_result_el(LServer, LUser, ConvRes);
    _ ->
      {error, internal}
  end.

make_result(LServer, LUser, Stamp, RSM, Form) ->
  {QueryChats, QueryCount} = make_sql_query(LServer, LUser, Stamp, RSM, Form),
  {selected, _, Res} = ejabberd_sql:sql_query(LServer, QueryChats),
  {selected, _, [[CountBinary]]} = ejabberd_sql:sql_query(LServer, QueryCount),
  Count = binary_to_integer(CountBinary),
  ConvRes = convert_result(Res),
  Presences = get_pending_subscriptions(LUser,LServer),
  ReplacedConv = lists:map(fun(El) ->
    C = make_result_el(LServer, LUser, El),
    case lists:keyfind(C#xabber_conversation.jid, #presence.from, Presences) of
      false -> C;
      Presence -> xmpp_codec:set_els(C, [Presence | C#xabber_conversation.sub_els])
    end

                   end, ConvRes
  ),
  LastStamp = get_last_stamp(LServer, LUser),
  ResRSM = case ReplacedConv of
             [_|_] when RSM /= undefined ->
               #xabber_conversation{stamp = First} = hd(ReplacedConv),
               #xabber_conversation{stamp = Last} = lists:last(ReplacedConv),
               #rsm_set{first = #rsm_first{data = First},
                 last = Last,
                 count = Count};
             [] when RSM /= undefined ->
               #rsm_set{count = Count};
             _ ->
               undefined
           end,
  #xabber_synchronization_query{sub_els = ReplacedConv,
    stamp = LastStamp, rsm = ResRSM}.

convert_result(Result) ->
  lists:map(fun(El) ->
    [Conversation,Retract,Type,Thread,
      Read,ReadTS,Delivered,Display,UpdateAt,
      Status,Encrypted, Pinned,Mute, GroupInfo] = El,
    GroupXelem = case binary:split(GroupInfo,<<$,>>) of
                   [<<>>] ->
                     [];
                   [Privacy, Parent] ->
                     [#xabbergroupchat_x{
                       xmlns = ?NS_GROUPCHAT,
                       parent = jid:from_string(Parent),
                       sub_els = [#xabbergroupchat_privacy{cdata = Privacy}]}];
                   [Privacy] ->
                     [#xabbergroupchat_x{
                       xmlns = ?NS_GROUPCHAT,
                       sub_els = [#xabbergroupchat_privacy{cdata = Privacy}]}]
                 end,
    {Conversation,binary_to_integer(Retract),Type,Thread,
      Read,ReadTS,Delivered,Display,binary_to_integer(UpdateAt),
      binary_to_atom(Status,utf8),ejabberd_sql:to_bool(Encrypted),
      Pinned,binary_to_integer(Mute), GroupXelem} end, Result).

make_result_el(LServer, LUser, El) ->
  {Conversation, Retract, Type, Thread, Read, ReadTS, Delivered,
    Display, UpdateAt, ConversationStatus, Encrypted,
    Pinned,Mute,GroupInfo} = El,
  ConversationMetadata = ejabberd_hooks:run_fold(syncronization_query,
    LServer, [], [LUser, LServer, Conversation, Read, ReadTS, Delivered, Display,
      ConversationStatus, Retract, Type, Encrypted, GroupInfo]),
  CElem = #xabber_conversation{
    stamp = integer_to_binary(UpdateAt),
    type = Type, status = ConversationStatus,
    thread = Thread,
    jid = jid:from_string(Conversation),
    pinned = Pinned,
    sub_els = ConversationMetadata},
  Now = time_now() div 1000000,
  if
    Mute >= Now -> CElem#xabber_conversation{mute = integer_to_binary(Mute)};
    true -> CElem
  end.

create_synchronization_metadata(_Acc,_LUser,_LServer,_Conversation,
    _Read,_ReadTS,_Delivered,_Display,deleted,_Retract,_Type,_Encrypted,_GroupInfo) ->
  {stop,[]};
create_synchronization_metadata(Acc,LUser,LServer,Conversation,
    Read,ReadTS,Delivered,Display,_ConversationStatus,Retract,Type,Encrypted,GroupInfo) ->
  {PUser, PServer,_} = jid:tolower(jid:from_string(Conversation)),
  IsLocal = is_local(PServer),
  case Type of
    ?NS_CHANNELS when IsLocal == false ->
      {Sub, _, _} = mod_roster:get_jid_info(<<>>, LUser, LServer,
        jid:from_string(Conversation)),
      Count = eg_get_unread_msgs_count({PUser, PServer}, ReadTS, Sub),
      UserCard = eg_get_user_card(LUser, LServer, PUser, PServer),
      LastMessage = eg_get_last_message(LUser, LServer, PUser, PServer, Sub),
      LastCall = get_actual_last_call(LUser, LServer, PUser, PServer),
      Unread = #xabber_conversation_unread{count = Count, 'after' = Read},
      XabberDelivered = #xabber_conversation_delivered{id = Delivered},
      XabberDisplayed = #xabber_conversation_displayed{id = Display},
      SubEls = [Unread, XabberDisplayed, XabberDelivered] ++ LastMessage,
      {stop,[#xabber_metadata{node = ?NS_XABBER_REWRITE,
        sub_els = [#xabber_conversation_retract{version = Retract}]},
        #xabber_metadata{node = ?NS_JINGLE_MESSAGE,sub_els = LastCall},
        #xabber_metadata{node = ?NS_CHANNELS, sub_els = UserCard},
        #xabber_metadata{node = ?NS_XABBER_SYNCHRONIZATION, sub_els = SubEls}]};
    ?NS_CHANNELS ->
      User = jid:to_string(jid:make(LUser,LServer)),
      Chat = jid:to_string(jid:make(PUser,PServer)),
      Status = mod_channels_users:check_user_if_exist(LServer,User,Chat),
      Count = lg_get_count_messages(User,Chat,Read,Status),
      LastMessage = lg_get_last_message(LUser, LServer, PUser, PServer,Status),
      LastCall = get_actual_last_call(LUser, LServer, PUser, PServer),
      Unread = #xabber_conversation_unread{count = Count, 'after' = Read},
      XabberDelivered = #xabber_conversation_delivered{id = Delivered},
      XabberDisplayed = #xabber_conversation_displayed{id = Display},
      UserCard = mod_channels_users:form_user_card(User,Chat),
      SubEls = [Unread, XabberDisplayed, XabberDelivered] ++ LastMessage,
      {stop,[#xabber_metadata{node = ?NS_XABBER_REWRITE,
        sub_els = [#xabber_conversation_retract{version = Retract}]},
        #xabber_metadata{node = ?NS_JINGLE_MESSAGE,sub_els = LastCall},
        #xabber_metadata{node = ?NS_CHANNELS, sub_els = [UserCard]},
        #xabber_metadata{node = ?NS_XABBER_SYNCHRONIZATION, sub_els = SubEls}]};
    ?NS_GROUPCHAT when IsLocal == true ->
      User = jid:to_string(jid:make(LUser,LServer)),
      Chat = jid:to_string(jid:make(PUser,PServer)),
      Status = mod_groups_users:check_user_if_exist(LServer,User,Chat),
      Count = lg_get_count_messages(User,Chat,Read,Status),
      LastMessage = lg_get_last_message(LUser, LServer, PUser, PServer,Status),
      LastCall = get_actual_last_call(LUser, LServer, PUser, PServer),
      Unread = #xabber_conversation_unread{count = Count, 'after' = Read},
      XabberDelivered = #xabber_conversation_delivered{id = Delivered},
      XabberDisplayed = #xabber_conversation_displayed{id = Display},
      UserCard = lg_get_user_card(LUser, LServer, PUser, PServer),
      SubEls = [Unread, XabberDisplayed, XabberDelivered] ++ LastMessage,
      {stop,[#xabber_metadata{node = ?NS_XABBER_REWRITE,
        sub_els = [#xabber_conversation_retract{version = Retract}]},
        #xabber_metadata{node = ?NS_JINGLE_MESSAGE,sub_els = LastCall},
        #xabber_metadata{node = ?NS_GROUPCHAT, sub_els = UserCard ++ GroupInfo},
        #xabber_metadata{node = ?NS_XABBER_SYNCHRONIZATION, sub_els = SubEls}]};
    ?NS_GROUPCHAT ->
      {Sub, _, _} = mod_roster:get_jid_info(<<>>, LUser, LServer,
        jid:from_string(Conversation)),
      Count = eg_get_unread_msgs_count({PUser, PServer}, ReadTS, Sub),
      UserCard = eg_get_user_card(LUser, LServer, PUser, PServer),
      LastMessage = eg_get_last_message(LUser, LServer, PUser, PServer, Sub),
      LastCall = get_actual_last_call(LUser, LServer, PUser, PServer),
      Unread = #xabber_conversation_unread{count = Count, 'after' = Read},
      XabberDelivered = #xabber_conversation_delivered{id = Delivered},
      XabberDisplayed = #xabber_conversation_displayed{id = Display},
      SubEls = [Unread, XabberDisplayed, XabberDelivered] ++ LastMessage,
      {stop,[#xabber_metadata{node = ?NS_XABBER_REWRITE,
        sub_els = [#xabber_conversation_retract{version = Retract}]},
        #xabber_metadata{node = ?NS_JINGLE_MESSAGE,sub_els = LastCall},
        #xabber_metadata{node = ?NS_GROUPCHAT, sub_els = UserCard ++ GroupInfo},
        #xabber_metadata{node = ?NS_XABBER_SYNCHRONIZATION, sub_els = SubEls}]};
    _ when Encrypted == true ->
      Count = get_count_messages(LServer,LUser,Conversation,Read,Type),
      LastMessage = get_last_encrypted_message(LServer,LUser,Conversation,Type),
      Unread = #xabber_conversation_unread{count = Count, 'after' = Read},
      XabberDelivered = #xabber_conversation_delivered{id = Delivered},
      XabberDisplayed = #xabber_conversation_displayed{id = Display},
      SubEls = [Unread, XabberDisplayed, XabberDelivered] ++ LastMessage,
%%      RetractVersion = mod_retract:get_version(LServer, LUser),
      {stop,[#xabber_metadata{node = ?NS_XABBER_REWRITE,
        sub_els = [#xabber_conversation_retract{version = Retract}]},
        #xabber_metadata{node = ?NS_XABBER_SYNCHRONIZATION, sub_els = SubEls}|Acc]};
    _ ->
      Count = get_count_messages(LServer,LUser,Conversation,Read,?NS_XABBER_CHAT),
      LastMessage = get_last_message(LServer,LUser,Conversation),
      LastCall = get_actual_last_call(LUser, LServer, PUser, PServer),
      Unread = #xabber_conversation_unread{count = Count, 'after' = Read},
      XabberDelivered = #xabber_conversation_delivered{id = Delivered},
      XabberDisplayed = #xabber_conversation_displayed{id = Display},
      SubEls = [Unread, XabberDisplayed, XabberDelivered] ++ LastMessage,
%%      RetractVersion = mod_retract:get_version(LServer, LUser),
      {stop,[#xabber_metadata{node = ?NS_XABBER_REWRITE,
        sub_els = [#xabber_conversation_retract{version = Retract}]},
        #xabber_metadata{node = ?NS_JINGLE_MESSAGE,sub_els = LastCall},
        #xabber_metadata{node = ?NS_XABBER_SYNCHRONIZATION, sub_els = SubEls}|Acc]}
  end.

get_pending_subscriptions(LUser, LServer) ->
  BareJID = jid:make(LUser, LServer),
  Result = mod_roster:get_roster(LUser, LServer),
  lists:filtermap(
    fun(#roster{ask = Ask} = R) when Ask == in; Ask == both ->
      Message = R#roster.askmessage,
      Status = if is_binary(Message) -> (Message);
                 true -> <<"">>
               end,
      {true, #presence{from = jid:make(R#roster.jid),
        to = BareJID,
        type = subscribe,
        status = xmpp:mk_text(Status)}};
      (_) ->
        false
    end, Result).

%% Get the last informative chat message
get_last_message(LServer,LUser,Conversation) ->
  get_last_informative_message(LServer, LUser,
    Conversation, misc:now_to_usec(erlang:now())).

get_last_informative_message(LServer, LUser, Conversation, TS) ->
  ConvType = ?NS_XABBER_CHAT,
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(timestamp)d, @(xml)s, @(peer)s, @(kind)s, @(nick)s "
    " from archive where username=%(LUser)s and bare_peer=%(Conversation)s "
    " and %(LServer)H and timestamp < %(TS)d and conversation_type=%(ConvType)s "
    " order by timestamp desc limit 10")) of
    {selected,[]} ->
      [];
    {selected,List} ->
      case find_informative_message(LUser, LServer, List) of
        [] ->
          {TS1, _, _, _, _} = lists:last(List),
          get_last_informative_message(LServer, LUser, Conversation, TS1);
        M -> M
      end;
    _ ->
      []
  end.

find_informative_message(_LUser, _LServer, [])-> [];
find_informative_message(LUser, LServer, List)->
  [{TS, XML, Peer, Kind, Nick}| Tail] = List,
  case mod_mam_sql:make_archive_el(integer_to_binary(TS), XML, Peer,
    Kind, Nick, chat, jid:make(LUser,LServer), jid:make(LUser,LServer)) of
    {ok, ArchiveElement} ->
      #forwarded{sub_els = [Message]} = ArchiveElement,
      case xmpp:get_text(Message#message.body) of
        <<>> ->
          case xmpp:has_subtag(Message, #jingle_reject{}) of
            true ->
              [#xabber_conversation_last{sub_els = [Message]}];
            _ ->
              find_informative_message(LUser, LServer, Tail)
          end;
        _ ->
          case xmpp:has_subtag(Message, #xabbergroupchat_invite{}) of
            true ->
              find_informative_message(LUser, LServer, Tail);
            _ ->
              [#xabber_conversation_last{sub_els = [Message]}]
          end
      end;
    _ ->
      find_informative_message(LUser, LServer, Tail)
  end.

%% Get the last encrypted informative chat message
get_last_encrypted_message(LServer,LUser,Conversation, ConvType) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(timestamp)d, @(xml)s, @(peer)s, @(kind)s, @(nick)s "
    " from archive where username=%(LUser)s and bare_peer=%(Conversation)s "
    " and %(LServer)H and txt notnull and txt !='' "
    " and conversation_type = %(ConvType)s order by timestamp desc limit 1")) of
    {selected,[<<>>]} ->
      [];
    {selected,[{TS, XML, Peer, Kind, Nick}]} ->
      convert_message(TS, XML, Peer, Kind, Nick, LUser, LServer);
    _ ->
      []
  end.

store_last_call(Pkt, Peer, LUser, LServer, ID) ->

  {PUser, PServer, _} = jid:tolower(Peer),
  Data = get_sync_data(LUser, LServer, PUser, PServer),
  NewData = Data#sync_data{
    call_ts = time_now(),
    call_msg = Pkt
  },
  case store_sync_data(NewData) of
    {atomic, ok} ->
      Conversation = jid:to_string(jid:remove_resource(Peer)),
      update_metainfo(call, LServer,LUser,Conversation, ID,?NS_XABBER_CHAT,ID),
      ?DEBUG("Save call ~p to ~p~n TS ~p ",[LUser,Peer, ID]),
      ok;
    {aborted, Err1} ->
      ?DEBUG("Unable to save call for ~s@~s: ~s",
        [LUser, LServer, Err1]),
      Err1
  end.

delete_last_call(Peer, LUser, LServer) ->
  {PUser, PServer, _} = jid:tolower(Peer),
  Data = get_sync_data(LUser, LServer, PUser, PServer),
  NewData = Data#sync_data{
    call_ts = undefined,
    call_msg = undefined
  },
  store_sync_data(NewData).

get_actual_last_call(LUser, LServer, PUser, PServer) ->
  TS10 = time_now() - 600000000,
  Data = get_sync_data(LUser, LServer, PUser, PServer),
  case Data of
    #sync_data{call_msg = undefined} -> [];
    #sync_data{call_msg = Pkt, call_ts = TS} when TS >= TS10 ->
      [#xabber_conversation_call{sub_els = [Pkt]}];
    #sync_data{call_msg = _Pkt, call_ts = _TS} ->
      delete_last_call(jid:make(PUser, PServer), LUser, LServer),
      [];
    _ -> []
  end.

%% Get last message in the external group if ID matches
eg_get_last_message_by_id(Group, ID) when is_integer(ID) ->
  eg_get_last_message_by_id(Group, integer_to_binary(ID));
eg_get_last_message_by_id(Group, ID) ->
  FN = fun()->
    mnesia:match_object(external_group_last_msg,
      {external_group_last_msg, Group,ID,'_','_','_'},
      read)
       end,
  case mnesia:transaction(FN) of
    {atomic, [#external_group_last_msg{packet = Msg}]} -> Msg;
    _ -> false
  end.

%% Save the message of the external group
eg_store_message(LServer, LastMessage, TS) when is_integer(TS) ->
  eg_store_message(LServer, LastMessage, integer_to_binary(TS));
eg_store_message(LServer, LastMessage, TS) ->
  #external_group_last_msg{packet = Pkt} = LastMessage,
  IsService = xmpp:get_subtag(Pkt,#xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE}),
  send_cast(LServer, {eg_save_message, LastMessage, TS, IsService}).

eg_store_message1(Group_SID, UserID, TS) ->
  case {mnesia:table_info(external_group_msgs, disc_only_copies),
    mnesia:table_info(external_group_msgs, memory)} of
    {[_|_], TableSize} when TableSize > ?TABLE_SIZE_LIMIT ->
      ?ERROR_MSG("external_group_msgs too large, won't store ~p",[Group_SID]),
      {error, overflow};
    _ ->
      F1 = fun() ->
        mnesia:write(
          #external_group_msgs{
            group_sid = Group_SID,
            uid = UserID,
            ts = TS
          })
           end,
      case mnesia:transaction(F1) of
        {atomic, ok} ->
          ?DEBUG("Save external group message ~p~n",[Group_SID]),
          ok;
        {aborted, Err1} ->
          ?DEBUG("Cannot save external group message ~p: ~s",
            [Group_SID, Err1]),
          Err1
      end
  end.

%% Save the last message of the external group
eg_store_last_msg(Record) ->
  case {mnesia:table_info(external_group_last_msg, disc_only_copies),
    mnesia:table_info(external_group_last_msg, memory)} of
    {[_|_], TableSize} when TableSize > ?TABLE_SIZE_LIMIT ->
      ?ERROR_MSG("external_group_last_msg too large,
       won't store ~p",[Record]),
      {error, overflow};
    _ ->
      F1 = fun() -> mnesia:write(Record) end,
      case mnesia:transaction(F1) of
        {atomic, ok} ->
          ?DEBUG("Save last message ~p ~p",
            [Record#external_group_last_msg.group,
              Record#external_group_last_msg.id]),
          ok;
        {aborted, Err1} ->
          ?DEBUG("Cannot save last msg for ~p ~p: ~s",
            [Record#external_group_last_msg.group,
              Record#external_group_last_msg.id, Err1]),
          Err1
      end
  end.

%% Maybe change last message in the external group
eg_maybe_change_last_msg(LServer, ConversationJID, Replace) ->
  {PUser, PServer, _} = jid:tolower(ConversationJID),
  send_cast(LServer, {eg_change_last_message, {PUser, PServer}, Replace}).

eg_change_last_msg(Replace, LastMsg) ->
  Ver = integer_to_binary(Replace#xabber_replace.version),
  #xabber_replace{ xabber_replace_message = XabberReplaceMessage} = Replace,
  #xabber_replace_message{body = Text, sub_els = NewEls} = XabberReplaceMessage,
  MD = xmpp:decode(LastMsg#external_group_last_msg.packet),
  Sub = MD#message.sub_els,
  Body = MD#message.body,
  OldText = xmpp:get_text(Body),
  Sub1 = lists:filter(fun(El) ->
    case xmpp:get_ns(El) of
      ?NS_REFERENCE_0 -> false;
      ?NS_GROUPCHAT -> false;
      _ -> true
    end end, Sub),
  Els1 = Sub1 ++ NewEls,
  NewBody = [#text{lang = <<>>,data = Text}],
  R = #replaced{stamp = erlang:timestamp(), body = OldText},
  Els2 = [R|Els1],
  NewMsg = MD#message{sub_els = Els2, body = NewBody},
  NewLastMsg = LastMsg#external_group_last_msg{packet=NewMsg, retract_version=Ver},
  eg_store_last_msg(NewLastMsg).

get_user_id(Pkt) ->
  get_id_from_x(Pkt, xmpp:get_subtag(Pkt, #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT})).

get_id_from_x(Pkt, false) ->
  try_to_get_id(Pkt);
get_id_from_x(_Pkt, X) ->
  get_card_from_refence(xmpp:get_subtag(X,#xmppreference{}), group).

get_card_from_refence(false,_Type) ->
  false;
get_card_from_refence(Reference, channel) ->
  get_id_from_card(xmpp:get_subtag(Reference, #channel_user_card{}));
get_card_from_refence(Reference, group) ->
  get_id_from_card(xmpp:get_subtag(Reference, #xabbergroupchat_user_card{})).

get_id_from_card(#channel_user_card{id = ID}) ->
  ID;
get_id_from_card(#xabbergroupchat_user_card{id = ID}) ->
  ID;
get_id_from_card(_Card) ->
  false.

try_to_get_id(Pkt) ->
  get_x(xmpp:get_subtag(Pkt, #channel_x{xmlns = ?NS_CHANNELS})).

get_x(false) ->
  false;
get_x(X) ->
  get_card_from_refence(xmpp:get_subtag(X,#xmppreference{}), channel).

%%eg_store_message(PUser, PServer, UserID, StanzaID, false) ->
%%  case {mnesia:table_info(external_group_msgs, disc_only_copies),
%%    mnesia:table_info(external_group_msgs, memory)} of
%%    {[_|_], TableSize} when TableSize > ?TABLE_SIZE_LIMIT ->
%%      ?ERROR_MSG("Unread counter too large, won't store message id for ~s@~s",
%%        [PUser, PServer]),
%%      {error, overflow};
%%    _ ->
%%      F1 = fun() ->
%%        mnesia:write(
%%          #external_group_msgs{
%%            group_sid = {{PUser, PServer}, StanzaID},
%%            uid = UserID,
%%            ts = integer_to_binary(time_now())
%%          })
%%           end,
%%      case mnesia:transaction(F1) of
%%        {atomic, ok} ->
%%          ?DEBUG("Save external group msg for ~p@~p~n",[PUser, PServer]),
%%          ok;
%%        {aborted, Err1} ->
%%          ?DEBUG("Cannot save external group msg for ~s@~s: ~s",
%%            [PUser, PServer, Err1]),
%%          Err1
%%      end
%%  end;
%%eg_store_message(_Peer, _UserID, _TS, _OriginID, _IsService) ->
%%  ok.

eg_get_unread_msgs_count(Group, ReadTS, Subscription) when is_integer(ReadTS) ->
  eg_get_unread_msgs_count(Group, integer_to_binary(ReadTS), Subscription);
eg_get_unread_msgs_count(Group, ReadTS, both) ->
  FN = fun()->
    MatchHead = #external_group_msgs{group_sid='$1', _='_' , ts = '$2', deleted = false},
    Guards = [{'=:=', {const, Group}, {element, 1, '$1'}},{'>', '$2', ReadTS}],
    Result = {size,'$1'}, %% just to minimize memory usage
    length(mnesia:select(external_group_msgs,[{MatchHead, Guards, [Result]}]))
      end,
   case mnesia:transaction(FN) of
     {atomic,Count} when is_integer(Count) -> Count;
     _ -> 0
   end;
eg_get_unread_msgs_count(_, _, _) -> 0.

eg_remove_message(Acc, Group, StanzaID, UserID, RVer) ->
  AID = if
         StanzaID == all, UserID == all -> RVer;
         StanzaID /= <<>> -> StanzaID;
         UserID /= <<>> -> UserID
       end,
  case lists:member({Group, AID, RVer}, Acc) of
    true -> Acc;
    _ ->
      eg_do_remove_msg(Group, StanzaID, UserID),
      save_last_action(Acc, {Group, AID, RVer})
  end.

%% Delete all external group messages
eg_do_remove_msg(Group, all, all) ->
  mnesia:dirty_delete(external_group_last_msg, Group),
  FN = fun()->
    MatchHead = #external_group_msgs{group_sid='$1', _='_' , _ = '_', _ = '_'},
    Guards = [{'=:=', {const, Group}, {element, 1, '$1'}}],
    Msgs = mnesia:select(external_group_msgs,[{MatchHead, Guards, ['$_']}]),
    lists:foreach(fun(O) -> mnesia:delete_object(O) end, Msgs)
       end,
  mnesia:transaction(FN);
%% Mark the message of the external group as deleted by the stanza ID
eg_do_remove_msg(Group, ID, <<>>) when ID /= <<>> ->
  case eg_get_last_message_by_id(Group, ID) of
    false -> ok;
    _ ->
      mnesia:dirty_delete(external_group_last_msg, Group)
  end,
  FN = fun() ->
    case mnesia:read(external_group_msgs, {Group, ID}) of
      [Msg] -> mnesia:write(Msg#external_group_msgs{deleted = true});
      _ -> ok
    end end,
  mnesia:transaction(FN);
%% Mark the message of the external group as deleted by the user ID
eg_do_remove_msg(Group, <<>>, UserID) when UserID /= <<>> ->
  case mnesia:dirty_read(external_group_last_msg, Group) of
    [#external_group_last_msg{user_id = UserID} = LMsg] ->
      mnesia:dirty_delete_object(LMsg);
    _ -> ok
  end,
  FN = fun()->
    MatchHead = #external_group_msgs{group_sid='$1', uid='$2' , _ = '_', _ = '_'},
    Guards = [{'=:=', {const, Group}, {element, 1, '$1'}},{'=:=', UserID,'$2'}],
    Msgs = mnesia:select(external_group_msgs,[{MatchHead, Guards, ['$_']}]),
    lists:foreach(fun(O) -> mnesia:delete_object(O) end, Msgs)
       end,
  mnesia:transaction(FN);
eg_do_remove_msg(_, _, _) ->
  ok.

%% Get last message in the external group
eg_get_last_message(LUser, LServer, GUser, GServer, both) ->
  case mnesia:dirty_read(external_group_last_msg, {GUser, GServer}) of
    [Result] ->
      #external_group_last_msg{packet = Msg} = Result,
      [#xabber_conversation_last{sub_els = [xmpp:set_to(Msg, jid:make(LUser, LServer))]}];
    _->
      []
  end;
eg_get_last_message(LUser, LServer, GUser, GServer, _Sub) ->
  get_invite(LServer,LUser,GUser, GServer).

%% Get the last non-system message ID in the external group
eg_get_last_message_id_ts(GUser, GServer) ->
  FN = fun(R, {ID, TS}) ->
    case R of
      #external_group_msgs{
        ts = TS1,
        group_sid = {{GUser, GServer} , ID1}
      } when TS1 > TS ->
        {ID1, TS1};
      _ -> {ID, TS}

    end
    end,
  Result = mnesia:transaction(fun() ->
    mnesia:foldl(FN, {0, time_now()}, external_group_msgs) end),
  case Result of
    {atomic, {ID, TS}} -> {ID,TS};
    _ -> undefined
  end.

eg_get_message_ts(GUser, GServer, StanzaID) ->
  case mnesia:dirty_read(external_group_msgs,
    {{GUser, GServer}, StanzaID}) of
    [#external_group_msgs{ts=TS}] -> TS;
    _ -> time_now()
  end.

%% Delete last message in the external group by stanza ID
eg_delete_one_msg(LServer, PUser, PServer, StanzaID, Version) ->
  send_cast(LServer, {eg_delete_msg, {PUser, PServer}, StanzaID, <<>>, Version}).

%% Delete last message in the external group by user ID
eg_delete_user_messages(LServer, PUser, PServer, UserID, Version) ->
  send_cast(LServer, {eg_delete_msg, {PUser, PServer}, <<>>, UserID, Version}).

%% Delete all message in the external group.
eg_delete_all_msgs(LServer, PUser, PServer, Version) ->
  send_cast(LServer, {eg_delete_msg, {PUser, PServer}, all, all, Version}).

%% Delete messages that all group members have read
eg_delete_read_messages(LServer) ->
  Type = ?NS_GROUPCHAT,
  Like = <<"%@",LServer/binary>>,
  IDsList = case ejabberd_sql:sql_query(LServer,
    ?SQL("select @(conversation)s, @(min(read_until))s from conversation_metadata "
    " where type = %(Type)s  and read_until !='0'"
    " and conversation not like %(Like)s and %(LServer)H "
    " group by conversation")) of
              {selected, L} -> L;
              R -> R
            end,
  FN = fun()->
    TSsList = lists:filtermap(fun({GroupS, Read}) ->
      {GUser, GServer, _} = jid:tolower(jid:from_string(GroupS)),
      case mnesia:read(external_group_msgs, {{GUser, GServer}, Read}) of
        [#external_group_msgs{ts = TS}] -> {true,{{GUser, GServer}, TS}};
        _ -> false
      end end, IDsList),
    lists:foreach(fun({Group, TS}) ->
      MatchHead = #external_group_msgs{group_sid='$1', _='_' , ts = '$2', _='_'},
      Guards = [{'=:=', {const, Group}, {element, 1, '$1'}},{'<', '$2', TS}],
      Result = '$_',
      Msgs = mnesia:select(external_group_msgs,[{MatchHead, Guards, [Result]}]),
      lists:foreach(fun(M) -> mnesia:delete_object(M) end, Msgs)
                  end, TSsList) end,

  mnesia:transaction(FN).

get_stanza_id(Pkt,BareJID) ->
  case xmpp:get_subtag(Pkt, #stanza_id{}) of
    #stanza_id{by = BareJID, id = StanzaID} ->
      StanzaID;
    _ ->
      undefined
  end.

get_unique_time(Pkt,BareJID) ->
  case xmpp:get_subtag(Pkt, #unique_time{}) of
    #unique_time{by = BareJID, stamp = TS} ->
      ts_to_usec(TS);
    _ ->
      time_now()
  end.

get_stanza_id(Pkt,BareJID,LServer,OriginID) ->
  case get_stanza_id(Pkt,BareJID) of
    undefined ->
      LUser = BareJID#jid.luser,
      mod_unique:get_stanza_id_by_origin_id(LServer,OriginID,LUser);
    StanzaID ->
      StanzaID
  end.

get_group_last_message_id_ts(GUser, GServer)->
  case is_local(GServer) of
    true ->
      R = lg_get_last_message_id(GUser, GServer),
      {R, R};
    _ ->
      eg_get_last_message_id_ts(GUser, GServer)
  end.

get_privacy(#xabbergroupchat_privacy{cdata = Privacy}) ->
  Privacy;
get_privacy(_Privacy) ->
  <<"public">>.

update_metainfo(LServer, LUser, Conv, Type) ->
  update_metainfo(LServer, LUser, Conv, Type,[]).

update_metainfo(LServer, LUser, Conv, not_encrypted, Opts) ->
  F = fun () ->
    case ejabberd_sql:sql_query_t(
      ?SQL("select @(type)s,@(status)s,@(mute)d from conversation_metadata "
      " where username = %(LUser)s and conversation = %(Conv)s "
      " and status != 'deleted' and not encrypted and %(LServer)H" )) of
      {selected,[]} ->
        conversation_sql_upsert(LServer, LUser, Conv , Opts),
        ?NS_XABBER_CHAT;
      {selected,[{Type, Status, Mute}]} ->
        sql_metainfo_update_t(LServer, LUser, Conv,
          Type, Status, Mute, Opts),
        Type;
      _->
        undefined
    end end,
  case ejabberd_sql:sql_transaction(LServer, F) of
    {atomic, Type} -> Type;
    _ -> undefined
  end;
update_metainfo(LServer, LUser, Conv, Type, Opts) ->
  Encrypted = if
                Type == ?NS_XABBER_CHAT; Type == ?NS_GROUPCHAT -> false;
                true -> true
             end,
  F = fun () ->
    case ejabberd_sql:sql_query_t(
      ?SQL("select @(type)s,@(status)s,@(mute)d from conversation_metadata "
      " where username = %(LUser)s and conversation = %(Conv)s "
      " and status != 'deleted' and %(LServer)H")) of
      {selected,[]} ->
        conversation_sql_upsert(LServer, LUser, Conv ,
          [{type, Type}, {encrypted, Encrypted}] ++ Opts);
      {selected,[{Type, Status, Mute}]} ->
        sql_metainfo_update_t(LServer, LUser, Conv, Type, Status, Mute, Opts);
      {selected, List}  ->
        Chat = lists:keyfind(Type, 1, List),
        IsGroup = lists:keymember(?NS_GROUPCHAT, 1, List),
        if
          is_tuple(Chat) ->
            {Type, Status, Mute} = Chat,
            sql_metainfo_update_t(LServer, LUser, Conv, Type, Status, Mute, Opts);
          not IsGroup andalso Type /= ?NS_GROUPCHAT ->
            conversation_sql_upsert(LServer, LUser, Conv ,
              [{type, Type}, {encrypted, Encrypted}] ++ Opts);
          true ->
            {type_changed, [T || {T, _, _} <- List]}
        end;
      _ ->
        error
    end end,
  case ejabberd_sql:sql_transaction(LServer, F) of
    {atomic, {type_changed, OldTypes}} ->
      type_changed(LUser, LServer, Conv, OldTypes, Type),
      Type;
    _->
      Type
  end.

sql_metainfo_update_t(LServer, LUser, Conv, Type, Status, Mute, Opts) ->
  TS = time_now(),
  TSSec = TS div 1000000,
  {NewStatus, NewMute} = if
                           Mute > TSSec -> {Status, Mute};
                           true -> {<<"active">>, 0}
                         end,
  ejabberd_sql:sql_query_t(
    ?SQL("update conversation_metadata "
    " set updated_at=%(TS)d, metadata_updated_at = %(TS)d, "
    " status=%(NewStatus)s, mute=%(NewMute)d "
    " where username=%(LUser)s and conversation=%(Conv)s "
    " and type = %(Type)s and %(LServer)H")
  ),
  case proplists:get_value(read, Opts) of
    undefined -> ok;
    SID when Type /= ?NS_GROUPCHAT->
      ejabberd_sql:sql_query_t(
        ?SQL("update conversation_metadata set "
        " read_until = %(SID)s, read_until_ts = %(SID)d "
        " where username=%(LUser)s and conversation=%(Conv)s "
        " and type = %(Type)s and read_until_ts <= %(SID)d "
        " and %(LServer)H")
      );
    _ -> ok
  end.


type_changed(LUser, LServer, Conv , OldTypes, NewType) ->
  ConvJID  = jid:from_string(Conv),
  if
    NewType /= ?NS_GROUPCHAT ->
      update_mam_prefs(remove,jid:make(LUser,LServer),
        jid:from_string(Conv));
    true -> ok
  end,
  lists:foreach(fun(CType) ->
    deactivate_conversation(LServer,LUser,
      #xabber_conversation{type = CType, jid = ConvJID})
    end, OldTypes),
  Encrypted = if
                NewType == ?NS_XABBER_CHAT;
                NewType == ?NS_GROUPCHAT -> false;
                true -> true
              end,
  create_conversation(LServer, LUser, Conv,
    <<>>, Encrypted, NewType, <<>>),
  TS = time_now(),
  make_sync_push(LServer, LUser, Conv,
    TS, NewType, false).

update_metainfo(_Any, _LServer,_LUser,_Conversation, undefined,_Type,_MsgTS) ->
  ?DEBUG("Stanza ID is undefined",[]),
  ok;
%% Used only in group conversations
update_metainfo(read_delivered, LServer, LUser,
    Conversation, StanzaID, Type, MsgTS) ->
  ?DEBUG("save delivered ~p ~p ~p",[LUser,Conversation,StanzaID]),
  TS = time_now(),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set metadata_updated_at = %(TS)d,"
    " read_until = %(StanzaID)s, read_until_ts = %(MsgTS)d, "
    " delivered_until = %(StanzaID)s, delivered_until_ts = %(MsgTS)d "
    " where username=%(LUser)s and conversation=%(Conversation)s "
    " and type = %(Type)s and read_until_ts <= %(MsgTS)d "
    " and %(LServer)H")
  );
update_metainfo(delivered, LServer,LUser,Conversation,StanzaID,Type,MsgTS) ->
  ?DEBUG("save delivered ~p ~p ~p",[LUser,Conversation,StanzaID]),
  TS = time_now(),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set metadata_updated_at = %(TS)d,"
    " delivered_until = %(StanzaID)s, delivered_until_ts = %(MsgTS)d "
    " where username=%(LUser)s and conversation=%(Conversation)s "
    " and type = %(Type)s and delivered_until_ts <= %(MsgTS)d "
    " and %(LServer)H")
  );
update_metainfo(read, LServer,LUser,Conversation,StanzaID,undefined,MsgTS) ->
  ?DEBUG("save read ~p ~p ~p",[LUser,Conversation,StanzaID]),
  TS = time_now(),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set metadata_updated_at = %(TS)d,"
    " read_until = %(StanzaID)s, read_until_ts = %(MsgTS)d "
    " where username=%(LUser)s and conversation=%(Conversation)s "
    " and not encrypted and read_until_ts <= %(MsgTS)d "
    " and %(LServer)H")
  );
update_metainfo(read, LServer,LUser,Conversation,StanzaID,Type,MsgTS) ->
  ?DEBUG("save read ~p ~p ~p",[LUser,Conversation,StanzaID]),
  TS = time_now(),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set metadata_updated_at = %(TS)d,"
    " read_until = %(StanzaID)s, read_until_ts = %(MsgTS)d "
    "where username=%(LUser)s and conversation=%(Conversation)s "
    " and type = %(Type)s and read_until_ts <= %(MsgTS)d "
    " and %(LServer)H")
  );
update_metainfo(displayed, LServer,LUser,Conversation,StanzaID,Type,MsgTS) ->
  ?DEBUG("save displayed ~p ~p ~p",[LUser,Conversation,StanzaID]),
  TS = time_now(),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set metadata_updated_at = %(TS)d,"
    " displayed_until = %(StanzaID)s, displayed_until_ts = %(MsgTS)d "
    " where username=%(LUser)s and conversation=%(Conversation)s "
    " and type = %(Type)s and  displayed_until_ts <= %(MsgTS)d "
    " and %(LServer)H")
  );
update_metainfo(_, LServer,LUser,Conversation,_StanzaID, Type, _MsgTS) ->
  ?DEBUG("updating the conversation metadata timestamp ~p ~p ",[LUser,Conversation]),
  TS = time_now(),
  ?SQL_UPSERT(
    LServer,
    "conversation_metadata",
    ["!username=%(LUser)s",
      "!conversation=%(Conversation)s",
      "!type=%(Type)s",
      "metadata_updated_at=%(TS)d",
      "server_host=%(LServer)s"]).

-spec get_conversation_type(binary(),binary(),binary()) -> list() | error.
get_conversation_type(LServer,LUser,Conversation) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(type)s from conversation_metadata "
    " where username=%(LUser)s and conversation=%(Conversation)s "
    " and status != 'deleted' and %(LServer)H")) of
    {selected,[]} -> [];
    {selected, List} -> [T || {T} <- List];
    _ -> error
  end.


update_retract(LServer, LUser, Conv, Ver, CType, TS) ->
  case ejabberd_sql:sql_query(LServer,
    ?SQL("update conversation_metadata SET "
    " metadata_updated_at ="
    "   CASE "
    "     WHEN type=%(CType)s THEN %(TS)d "
    "     ELSE metadata_updated_at "
    "   END, "
    " retract = %(Ver)d "
    " where username=%(LUser)s and conversation=%(Conv)s "
    " and retract < %(Ver)d and status != 'deleted' and %(LServer)H")) of
    {updated, N} when N > 0 -> ok;
    _Other -> error
  end.

get_last_stamp(LServer, LUser) ->
  case ejabberd_sql:sql_query(LServer,
    ?SQL("select @(max(metadata_updated_at))s from conversation_metadata "
    " where username=%(LUser)s and %(LServer)H")) of
    {selected,[]} ->
      <<"0">>;
    {selected,[{Version}]} ->
      Version
  end.

get_count_messages(LServer,LUser,Peer,TS, ConvType) ->
  case ejabberd_sql:sql_query(LServer,
    ?SQL("select @(count(*))d from archive "
    " where username=%(LUser)s and bare_peer=%(Peer)s and txt notnull and txt !='' "
    " and timestamp > %(TS)d and (not ARRAY['invite','voip'] && tags or tags is null) "
    " and conversation_type = %(ConvType)s and %(LServer)H")) of
    {selected,[{Count}]} ->
      Count;
    _ ->
      0
  end.

%% Get the last non-system message ID in the local group
lg_get_last_message_id(GUser, GServer) ->
  case ejabberd_sql:sql_query(GServer,
    ?SQL("select @(timestamp)s from archive"
    " where username=%(GUser)s  and txt notnull and txt !='' and %(GServer)H "
    " order by timestamp desc limit 1")) of
    {selected,[{TS}]} -> TS;
    _ -> undefined
  end.

lg_get_last_message(_LUser, _LServer, GUser, GServer, <<"both">>) ->
  case ejabberd_sql:sql_query(
    GServer,
    ?SQL("select @(timestamp)d, @(xml)s, @(peer)s, @(kind)s, @(nick)s "
    " from archive where username=%(GUser)s  and txt notnull and txt !='' "
    " and %(GServer)H order by timestamp desc limit 1")) of
    {selected,[{TS, XML, Peer, Kind, Nick}]} ->
      convert_message(TS, XML, Peer, Kind, Nick, GUser, GServer);
    _ ->
      []
  end;
lg_get_last_message(LUser, LServer, GUser, GServer, _) ->
  get_invite(LServer,LUser,GUser, GServer).

lg_get_count_messages(BareUser,Chat,TS,<<"both">>) ->
  {ChatUser, ChatServer, _ } = jid:tolower(jid:from_string(Chat)),
  case ejabberd_sql:sql_query(ChatServer,
    ?SQL("select @(count(*))d from archive "
    " where username=%(ChatUser)s and txt notnull and txt !='' "
    " and bare_peer not in (%(BareUser)s,%(Chat)s) and timestamp > %(TS)d "
    " and %(ChatServer)H")) of
    {selected,[{Count}]} ->
      Count;
    _ ->
      0
  end;
lg_get_count_messages(_LServer,_LUser,_TS,_Status) ->
  0.

convert_message(TS, XML, Peer, Kind, Nick, LUser, LServer) ->
  case mod_mam_sql:make_archive_el(integer_to_binary(TS), XML, Peer,
    Kind, Nick, chat, jid:make(LUser,LServer), jid:make(LUser,LServer)) of
    {ok, ArchiveElement} ->
      #forwarded{sub_els = [Message]} = ArchiveElement,
      [#xabber_conversation_last{sub_els = [Message]}];
    _ ->
      []
  end.


%%%===================================================================
%%% Handle sub_els
%%%===================================================================

handle_sub_els(chat, [#message_displayed{id = OriginID} = Displayed], From, To) ->
  {PUser, PServer, _} = jid:tolower(From),
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  {LUser,LServer,_} = jid:tolower(To),
  BareJID = jid:make(LUser,LServer),
  Type = case get_conversation_type(LServer,LUser,Conversation) of
           [T] -> T;
           _ -> undefined
         end,
  PeerJID = jid:make(PUser,PServer),
  {Type1, StanzaID, TS} =
    if
      Type == ?NS_GROUPCHAT ->
        Displayed2= filter_packet(Displayed,PeerJID),
        SID = get_stanza_id(Displayed2,PeerJID,LServer,OriginID),
        TS1 = case is_local(PServer) of
               true -> SID;
               _ -> eg_get_message_ts(PUser, PServer, SID)
             end,
        {Type, SID, TS1};
      Type =/= undefined ->
        Displayed2 = filter_packet(Displayed,BareJID),
        SID = get_stanza_id(Displayed2,BareJID,LServer,OriginID),
        {Type, SID, SID};
      true ->
        Displayed2 = filter_packet(Displayed,BareJID),
        SID = get_stanza_id(Displayed2,BareJID,LServer,OriginID),
        case mod_mam_sql:is_encrypted(LServer,SID) of
          {true, NS} -> {NS, SID, SID};
          _-> {?NS_XABBER_CHAT, SID, SID}
        end
    end,
  update_metainfo(displayed, LServer,LUser,Conversation,StanzaID,Type1,TS);
handle_sub_els(chat, [#message_received{id = OriginID} = Delivered], From, To) ->
  {PUser, PServer, _} = jid:tolower(From),
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  {LUser,LServer,_} = jid:tolower(To),
  BareJID = jid:make(LUser,LServer),
  Delivered2 = filter_packet(Delivered,BareJID),
  StanzaID1 = get_stanza_id(Delivered2,BareJID,LServer,OriginID),
  IsEncrypted = mod_mam_sql:is_encrypted(LServer,StanzaID1),
  case IsEncrypted of
    {true, NS} ->
      update_metainfo(delivered, LServer,LUser,Conversation,StanzaID1,NS,StanzaID1);
    _ ->
      update_metainfo(delivered, LServer,LUser,Conversation,StanzaID1,?NS_XABBER_CHAT,StanzaID1)
  end;
handle_sub_els(headline, [#xabber_retract_message{version = _Version, id = undefined,
  conversation = _Conv}], _From, _To) ->
  ok;
handle_sub_els(headline, [#xabber_retract_message{version = _Version,  id = _ID,
  conversation = undefined}], _From, _To) ->
  ok;
handle_sub_els(headline, [#xabber_retract_message{version =  undefined, id = _ID,
  conversation = _Conv}], _From, _To) ->
  ok;
handle_sub_els(headline, [#xabber_retract_message{type = Type, version = Version, id = StanzaID,
  conversation = ConversationJID} = Retract], _From, To) ->
  #jid{luser = LUser, lserver = LServer} = To,
  #jid{luser = PUser, lserver = PServer} = ConversationJID,
  case lists:member(PServer,ejabberd_config:get_myhosts()) of
    false ->
      eg_delete_one_msg(LServer, PUser, PServer,
        integer_to_binary(StanzaID), Version);
    _ -> ok
  end,
  Conversation = jid:to_string(ConversationJID),
  TS = time_now(),
  case update_retract(LServer,LUser,Conversation,Version,Type, TS) of
    ok ->
      send_push_about_retract(LServer,LUser,Conversation,Retract,Type,TS);
    _->
      pass
  end,
  ok;
handle_sub_els(headline, [#xabber_retract_user{version = Version, id = UserID,
  conversation = ConversationJID} = Retract], _From, To) ->
  #jid{luser = LUser, lserver = LServer} = To,
  #jid{luser = PUser, lserver = PServer} = ConversationJID,
  case lists:member(PServer,ejabberd_config:get_myhosts()) of
    false ->
      eg_delete_user_messages(LServer, PUser, PServer, UserID, Version);
    _ -> ok
  end,
  Conversation = jid:to_string(ConversationJID),
  TS = time_now(),
  update_retract(LServer,LUser,Conversation,Version,<<>>,TS),
  send_push_about_retract(LServer,LUser,Conversation,Retract,<<>>,TS);
handle_sub_els(headline, [
  #xabber_retract_all{type = Type, version = Version,
  conversation = ConversationJID} = Retract], _From, To)
  when ConversationJID =/= undefined andalso Version =/= undefined ->
  #jid{luser = LUser, lserver = LServer} = To,
  #jid{luser = PUser, lserver = PServer} = ConversationJID,
  Conversation = jid:to_string(ConversationJID),
  TS = time_now(),
  case lists:member(PServer,ejabberd_config:get_myhosts()) of
    false ->
      eg_delete_all_msgs(LServer, PUser, PServer, Version);
    _ -> ok
  end,
  update_retract(LServer,LUser,Conversation,Version,Type,TS),
  send_push_about_retract(LServer,LUser,Conversation,Retract,Type,TS);
handle_sub_els(headline, [#xabber_replace{version = undefined, conversation = _ConversationJID} = _Retract],
    _From, _To) ->
  ok;
handle_sub_els(headline, [#xabber_replace{type = Type, version = Version, conversation = ConversationJID} = Replace],
    _From, To) ->
  #jid{luser = LUser, lserver = LServer} = To,
  Conversation = jid:to_string(ConversationJID),
  eg_maybe_change_last_msg(LServer, ConversationJID, Replace),
  TS = time_now(),
  case update_retract(LServer,LUser,Conversation,Version,Type,TS) of
    ok ->
      send_push_about_retract(LServer,LUser,Conversation,Replace,Type,TS);
    _->
      pass
  end,
  ok;
handle_sub_els(headline, [#delivery_x{ sub_els = [Message]}], From, To) ->
  MessageD = xmpp:decode(Message),
  %% Bad server or client may send an error message
  if
    MessageD#message.type == chat;
    MessageD#message.type == normal ->
      process_delivery_msg(MessageD, From, To),
      ok;
    true ->
      ok
  end;
handle_sub_els(_Type, _SubEls, _From, _To) ->
  ok.

process_delivery_msg(MessageD, From, To) ->
  {PUser, PServer, _} = jid:tolower(From),
  PeerJID = jid:make(PUser, PServer),
  {LUser,LServer,_} = jid:tolower(To),
  Conversation = jid:to_string(PeerJID),
  StanzaID = get_stanza_id(MessageD,PeerJID),
  MsgTS = case is_local(PServer) of
            false ->
              Time = get_unique_time(MessageD,PeerJID),
              get_and_store_user_card(LServer, LUser,
                PeerJID, MessageD),
              LastMsg = #external_group_last_msg{
                group = {PUser, PServer}, id = StanzaID,
                user_id =get_user_id(MessageD),
                packet = xmpp:set_from(MessageD, From)},
              eg_store_message(LServer, LastMsg, Time),
              Time;
            _ ->
              StanzaID
          end,
  update_metainfo(read_delivered, LServer, LUser, Conversation,
    StanzaID, ?NS_GROUPCHAT, MsgTS).

%%%===================================================================
%%% Check VoIP message
%%%===================================================================
check_voip_msg(Direction, #message{type = chat,
  from = From, to = To, meta = #{stanza_id := StanzaID}} = Pkt)->
  Propose = xmpp:has_subtag(Pkt, #jingle_propose{}),
  Accept = xmpp:get_subtag(Pkt, #jingle_accept{}),
  Reject = xmpp:get_subtag(Pkt, #jingle_reject{}),
  {{LUser, LServer, _}, Peer} =
    case Direction of
      in -> {jid:tolower(To), From};
      _-> {jid:tolower(From), To}
    end,
  Conversation = jid:to_string(jid:remove_resource(Peer)),
  if
    Propose andalso Direction == in ->
      maybe_push_notification(LUser,LServer,<<"call">>,Pkt),
      store_last_call(Pkt, Peer, LUser, LServer, StanzaID),
      true;
    Propose ->
      %% Direction is out
      true;
    Accept /= false ->
      maybe_push_notification(LUser,LServer,<<"data">>,Accept),
      update_metainfo(call, LServer,LUser,Conversation,
        StanzaID,?NS_XABBER_CHAT, StanzaID),
      delete_last_call(Peer, LUser, LServer),
      true;
    Reject /= false ->
      maybe_push_notification(LUser,LServer,<<"data">>,Reject),
      update_metainfo(call, LServer,LUser,Conversation,
        StanzaID,?NS_XABBER_CHAT, StanzaID),
      delete_last_call(Peer, LUser, LServer),
      true;
    true ->
      false
  end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

make_sql_query(LServer, User, 0, RSM, Form)->
  make_sql_query(LServer, User, <<"0">>, RSM, Form);
make_sql_query(LServer, User, TS, RSM, Form) ->
  {Max, Direction, Chat} = get_max_direction_chat(RSM),
  SServer = ejabberd_sql:escape(LServer),
  SUser = ejabberd_sql:escape(User),
  Timestamp = ejabberd_sql:escape(TS),
  Pinned =  proplists:get_value(filter_pinned, Form),
  PinnedFirst = proplists:get_value(pinned_first, Form),
  Archived = proplists:get_value(filter_archived, Form),
  DeleteClause = case TS of
                   <<"0">> -> [<<"and status != 'deleted' ">>];
                   _ -> []
                 end,
  PinnedClause = case Pinned of
                   false ->
                     [<<"and pinned is null ">>];
                   true ->
                     [<<"and pinned >= 0 ">>];
                   _ ->
                     []
                 end,
  ArchivedClause = case Archived of
                     false ->
                       [<<"and status != 'archived' ">>];
                     true ->
                       [<<"and status = 'archived' ">>];
                     _ ->
                       []
                   end,
  PinnedFirstClause = case PinnedFirst of
                        false ->
                          [];
                        true ->
                          [<<" pinned desc ">>];
                        _ ->
                          []
                      end,
  LimitClause = if is_integer(Max), Max >= 0 ->
    [<<" limit ">>, integer_to_binary(Max)];
                  true ->
                    []
                end,
  Conversations = [<<"select conversation,
  retract,
  type,
  conversation_thread,
  read_until,
  read_until_ts,
  delivered_until,
  displayed_until,
  updated_at,
  status,
  encrypted,
  pinned,
  mute,
  group_info
  from conversation_metadata where username = '">>,SUser,<<"' and
  metadata_updated_at > '">>,Timestamp,<<"'">>] ++ DeleteClause,
  PageClause = case Chat of
                 B when is_binary(B) ->
                   case Direction of
                     before ->
                       [<<" AND updated_at > '">>, Chat,<<"' ">>];
                     'after' ->
                       [<<" AND updated_at < '">>, Chat,<<"' ">>];
                     _ ->
                       []
                   end;
                 _ ->
                   []
               end,
  Query = case ejabberd_sql:use_new_schema() of
            true ->
              [Conversations,<<" and server_host='">>,
                SServer, <<"' ">>,PageClause, PinnedClause, ArchivedClause];
            false ->
              [Conversations,PageClause, PinnedClause, ArchivedClause]
          end,
  QueryPage =
    case Direction of
      before ->
        [<<"SELECT * FROM (">>, Query,
          <<" ORDER BY updated_at ASC ">>,
          LimitClause, <<") AS c ORDER BY ">>, PinnedFirstClause ,<<" updated_at DESC;">>];
      _ ->
        [Query, <<" ORDER BY ">>, PinnedFirstClause ,<<" updated_at DESC ">>,
          LimitClause, <<";">>]
    end,
  case ejabberd_sql:use_new_schema() of
    true ->
      {QueryPage,[<<"SELECT COUNT(*) FROM (">>,Conversations,<<" and server_host='">>,
        SServer, <<"' ">>,
        <<" ) as subquery;">>]};
    false ->
      {QueryPage,[<<"SELECT COUNT(*) FROM (">>,Conversations,
        <<" ) as subquery;">>]}
  end.


get_max_direction_chat(RSM) ->
  case RSM of
    #rsm_set{max = Max, before = Before} when is_binary(Before) ->
      {Max, before, Before};
    #rsm_set{max = Max, 'after' = After} when is_binary(After) ->
      {Max, 'after', After};
    #rsm_set{max = Max} ->
      {Max, undefined, undefined};
    _ ->
      {undefined, undefined, undefined}
  end.

pin_conversation(LServer, LUser, #xabber_conversation{type = Type, jid = ConvJID, thread = Thread, pinned = Pinned}) ->
  Num = binary_to_integer(Pinned),
  TS = time_now(),
  Conversation = jid:to_string(ConvJID),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata "
    " set pinned=%(Num)d, metadata_updated_at=%(TS)d "
    " where username = %(LUser)s and conversation = %(Conversation)s "
    " and type = %(Type)s and status!='deleted' "
    " and conversation_thread = %(Thread)s and %(LServer)H")) of
    {updated, 0} ->
      {error,xmpp:err_item_not_found()};
    {updated,_N} ->
      make_sync_push(LServer,LUser,Conversation,TS,Type),
      ok;
    _ ->
      {error,xmpp:err_internal_server_error()}
  end;
pin_conversation(_, _, _) ->
  {error,xmpp:err_bad_request()}.

mute_conversation(LServer, LUser,
    #xabber_conversation{type = Type, jid = ConvJID, thread = Thread, mute = Mute}) ->
  TS = time_now(),
  Conversation = jid:to_string(ConvJID),
  SetMute = case Mute of
              <<>> -> <<"0">>;
              <<"0">> ->
                %%  forever = now + 100 years
                TS1 = TS div 1000000 + 3170980000,
                integer_to_binary(TS1);
              Val ->
                TS1 = TS div 1000000 + binary_to_integer(Val),
                integer_to_binary(TS1)
            end,
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata "
    " set mute=%(SetMute)d, metadata_updated_at=%(TS)d "
    " where username = %(LUser)s and conversation = %(Conversation)s "
    " and type = %(Type)s and status!='deleted' "
    " and conversation_thread = %(Thread)s and %(LServer)H")) of
    {updated, 0} ->
      {error,xmpp:err_item_not_found()};
    {updated,_N} ->
      make_sync_push(LServer,LUser,Conversation,TS,Type),
      ok;
    _ ->
      {error,xmpp:err_internal_server_error()}
  end;
mute_conversation(_, _, _) ->
  {error,xmpp:err_bad_request()}.

archive_conversation(LServer, LUser,
    #xabber_conversation{type = Type, jid = ConvJID, thread = Thread}) ->
  TS = time_now(),
  Conversation = jid:to_string(ConvJID),
    case ejabberd_sql:sql_query(
      LServer,
      ?SQL("update conversation_metadata "
      " set status = 'archived', metadata_updated_at=%(TS)d "
      " where username = %(LUser)s and conversation = %(Conversation)s "
      " and type = %(Type)s and status!='deleted' "
      " and conversation_thread = %(Thread)s and %(LServer)H")) of
      {updated, 0} ->
        {error,xmpp:err_item_not_found()};
      {updated,_N} ->
        make_sync_push(LServer,LUser,Conversation,TS,Type),
        ok;
      _ ->
        {error,xmpp:err_internal_server_error()}
    end;
archive_conversation(_, _, _) ->
  {error,xmpp:err_bad_request()}.

activate_conversation(LServer, LUser, #xabber_conversation{type = Type, jid = ConvJID, thread = Thread}) ->
  TS = time_now(),
  Conversation = jid:to_string(ConvJID),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata "
    " set status = 'active', metadata_updated_at=%(TS)d "
    " where username = %(LUser)s and conversation = %(Conversation)s "
    " and type = %(Type)s and status!='deleted' "
    " and conversation_thread = %(Thread)s and %(LServer)H")) of
    {updated, 0} ->
      {error,xmpp:err_item_not_found()};
    {updated,_N} ->
      make_sync_push(LServer,LUser,Conversation,TS,Type),
      ok;
    _ ->
      {error,xmpp:err_internal_server_error()}
  end;
activate_conversation(_, _, _) ->
  {error,xmpp:err_bad_request()}.

%% set the conversation status to "deleted"
deactivate_conversation(LServer,LUser,#xabber_conversation{type = Type, jid = JID}) ->
  Conversation = jid:to_string(jid:remove_resource(JID)),
  TS = time_now(),
  case Type of
    ?NS_GROUPCHAT ->
      update_mam_prefs(remove, jid:make(LUser, LServer), JID),
      delete_sync_data(LUser,LServer, Conversation);
    _-> ok
  end,
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata "
    " set status = 'deleted', updated_at=%(TS)d, metadata_updated_at=%(TS)d "
    " where username = %(LUser)s and conversation = %(Conversation)s "
    " and type = %(Type)s and %(LServer)H")) of
    {updated,0} ->
      {error,xmpp:err_item_not_found()};
    {updated,_N} ->
      make_sync_push(LServer,LUser,Conversation,TS,Type,false),
      ok;
    _ ->
      {error,xmpp:err_internal_server_error()}
  end;
deactivate_conversation(_,_,_) ->
  {error,xmpp:err_bad_request()}.

%% Delete all user conversations
delete_conversations(LUser, LServer) ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from conversation_metadata "
    " where username = %(LUser)s and %(LServer)H")),
  ok.

is_muted(LUser, LServer, Conversation) ->
  Now = time_now() div 1000000,
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @('true')b from conversation_metadata "
    " where username = %(LUser)s and conversation = %(Conversation)s "
    " and status != 'deleted' and mute > %(Now)d and %(LServer)H")) of
    {selected,[_|_]} -> true;
    _ -> false
  end.

is_muted(LUser,LServer, Conversation, Type) ->
  Now = time_now() div 1000000,
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @('true')b from conversation_metadata "
    " where username = %(LUser)s and conversation = %(Conversation)s "
    " and type = %(Type)s and mute > %(Now)d and %(LServer)H")) of
    {selected,[{Result}]} -> Result;
    _ -> false
  end.

maybe_push_notification(LUser, LServer, PushType, PushPayload)->
  send_cast(LServer, {send_push, LUser, LServer, PushType, PushPayload}).

maybe_push_notification(LUser, LServer, Conversation, CType, PushType, PushPayload)
  when <<LUser/binary,$@,LServer/binary>> /= Conversation ->
  case mod_xabber_entity:get_entity_type(LUser,LServer) of
    user ->
      send_cast(LServer, {send_push, LUser, LServer, Conversation,CType,
        PushType, PushPayload});
    _ ->
      pass
  end;
maybe_push_notification(_, _, _, _, _, _) ->
  %%  ignore notifications from yourself
  pass.

send_push_about_retract(LServer,LUser,Conversation,PushPayload,RetractType,TS) ->
  CType = case RetractType of
            <<>> ->
              case get_conversation_type(LServer,LUser,Conversation) of
                [T] -> T;
                _-> ?NS_XABBER_CHAT
              end;
            _ -> RetractType
          end,
  make_sync_push(LServer,LUser,Conversation, TS, CType),
  maybe_push_notification(LUser,LServer,Conversation,CType,
    <<"update">>,xmpp:decode(PushPayload)).

get_sync_data(LUser, LServer, PUser, PServer) ->
  FN = fun()->
    mnesia:read(sync_data,
      {{LUser, LServer}, {PUser, PServer}})
       end,
  case mnesia:transaction(FN) of
    {atomic, [Result]} -> Result;
    _ -> #sync_data{us_peer = {{LUser, LServer}, {PUser, PServer}}}
  end.

store_sync_data(Record) ->
  case lists:usort(
    lists:nthtail(2,tuple_to_list(Record))) of
    [undefined] ->
      %% delete if all fields are not defined
      Key = Record#sync_data.us_peer,
      mnesia:transaction(fun() -> mnesia:delete({sync_data, Key}) end);
    _ ->
      check_and_store_sync_data(Record)
  end.

check_and_store_sync_data(Record) ->
  case {mnesia:table_info(sync_data, disc_only_copies),
    mnesia:table_info(sync_data, memory)} of
    {[_|_], TableSize} when TableSize > ?TABLE_SIZE_LIMIT ->
      ?ERROR_MSG("sync_data too large, won't store ~p",[Record]),
      {aborted, overflow};
    _ ->
      mnesia:transaction(fun() -> mnesia:write(Record) end)
  end.

delete_sync_data(LUser, LServer, Conversation) ->
  {PUser, PServer, _} = jid:tolower(jid:from_string(Conversation)),
  delete_sync_data(LUser, LServer, PUser, PServer).

delete_sync_data(LUser, LServer, PUser, PServer) ->
  mnesia:transaction(fun () ->
    mnesia:delete({sync_data, {{LUser, LServer}, {PUser, PServer}}}) end).

delete_sync_data(LUser, LServer) ->
  FN = fun()->
    MatchHead = #sync_data{us_peer = '$1', _='_', _='_', _='_'},
    Guards = [{'=:=', {const, {LUser, LServer}}, {element, 1, '$1'}}],
    List = mnesia:select(sync_data,[{MatchHead, Guards, ['$_']}]),
    lists:foreach(fun(O) -> mnesia:delete_object(O) end, List)
       end,
  mnesia:transaction(FN).


%% invite logic

store_invite(LUser, LServer,GroupJID,StanzaID) ->
  {PUser, PServer, _} = jid:tolower(GroupJID),
  Data = get_sync_data(LUser, LServer, PUser, PServer),
  %% delete the previous invitation, if it exists
  case Data#sync_data.invite of
    undefined -> ok;
    ID -> mod_retract:delete_message(LServer, LUser, ID)
  end,
  NewData = Data#sync_data{
    invite = StanzaID
  },
  store_sync_data(NewData).

get_invite(LServer, LUser, PUser, PServer) ->
  Data = get_sync_data(LUser, LServer, PUser, PServer),
  case Data#sync_data.invite of
    undefined -> [];
    ID ->
      TS = binary_to_integer(ID),
      case ejabberd_sql:sql_query(
        LServer,
        ?SQL("select @(timestamp)d, @(xml)s, @(peer)s, @(kind)s, @(nick)s "
        " from archive where username = %(LUser)s and timestamp = %(TS)d "
        " and %(LServer)H ")) of
        {selected,[<<>>]} ->
          [];
        {selected,[{TS, XML, Peer, Kind, Nick}]}->
          convert_message(TS, XML, Peer, Kind, Nick, LUser, LServer);
        _ ->
          []
      end
  end.

maybe_delete_invite_and_conversation(LUser,LServer,PUser,PServer) ->
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  Type = get_conversation_type(LServer,LUser,Conversation),
  case Type of
    [?NS_GROUPCHAT] ->
      delete_invite(LUser,LServer,PUser,PServer),
      deactivate_conversation(LServer,LUser,
        #xabber_conversation{jid = jid:make(PUser,PServer),
          type = ?NS_GROUPCHAT});
    _ ->
      notfound
  end.

maybe_delete_invite_or_presence(LUser, LServer, JID) ->
  case maybe_delete_invite_and_conversation(LUser, LServer, JID#jid.luser, JID#jid.lserver) of
    notfound ->
      %% notify all connected clients of the user
      %% that the subscription request has been rejected
      SJID = jid:to_string(jid:remove_resource(JID)),
      TS = time_now(),
      case mod_roster:get_jid_info([],LUser, LServer, JID) of
        {_, Ask ,_} when Ask == in; Ask == both ->
          lists:foreach(fun(CType) ->
            update_metainfo(presence, LServer, LUser, SJID, <<"presence">> ,CType, time_now()),
            make_sync_push(LServer, LUser, SJID, TS, CType, false)
                        end, get_conversation_type(LServer,LUser,SJID));
        _ -> ok
      end;
    _ ->
      ok
  end.

delete_invite(LUser,LServer,PUser,PServer) ->
  Data = get_sync_data(LUser, LServer, PUser, PServer),
  case Data#sync_data.invite of
    undefined -> ok;
    ID ->
      mod_retract:delete_message(LServer, LUser, ID),
      NewData = Data#sync_data{invite = undefined},
      store_sync_data(NewData)
  end.

make_sync_push(LServer,LUser,Conversation, TS, ?NS_GROUPCHAT) ->
  make_sync_push(LServer,LUser,Conversation, TS, ?NS_GROUPCHAT, false);
make_sync_push(LServer,LUser,Conversation, TS, Type) ->
  make_sync_push(LServer,LUser,Conversation, TS, Type, true).

make_sync_push(LServer,LUser,Conversation, TS, Type, WithPresence) ->
  case get_conversation_info(LServer,LUser,Conversation,Type) of
    {error, Why} ->
      ?ERROR_MSG("Get conversation info error: ~p;"
      " user:~p, conversation:~p, type:~p",[Why, {LUser,LServer}, Conversation,Type]);
    CnElem ->
      CnElem1 = if
                   WithPresence ->
                     case mod_roster:get_jid_info([],LUser, LServer,
                       jid:from_string(Conversation)) of
                       {_, Ask ,_} when Ask == in; Ask == both ->
                         P = #presence{from = jid:from_string(Conversation),
                           type = subcribe},
                         SubEls = [P | xmpp_codec:get_els(CnElem)],
                         xmpp_codec:set_els(CnElem, SubEls);
                       _ -> CnElem
                     end;
                   true -> CnElem
                 end,
      UserResources = ejabberd_sm:get_user_present_resources(LUser,LServer),
      Query = #xabber_synchronization_query{stamp = integer_to_binary(TS), sub_els = [CnElem1]},
      lists:foreach(fun({_, Res}) ->
        From = jid:make(LUser,LServer),
        To = jid:make(LUser,LServer,Res),
        IQ = #iq{from = From, to = To, type = set, id = randoms:get_string(), sub_els = [Query]},
        ejabberd_router:route(IQ)
                    end, UserResources)
  end.

create_conversation(LServer, LUser, Conversation,
    Thread, Encrypted, Type, GroupInfo) ->
  Options = [{type, Type}, {thread, Thread}, {encrypted, Encrypted},
    {'group_info', GroupInfo}],
  F = fun() ->
    conversation_sql_upsert(LServer, LUser, Conversation , Options)
      end,
  ejabberd_sql:sql_transaction(LServer, F),
  case Type of
    ?NS_GROUPCHAT ->
      GroupJID = jid:from_string(Conversation),
      update_mam_prefs(add,jid:make(LUser,LServer),GroupJID),
      {GUser, GServer, _} = jid:tolower(GroupJID),
      %% Set "read_until" for correct unread count.
      {LastMsgID, TS} = case get_group_last_message_id_ts(GUser,GServer) of
                          undefined ->  {0,time_now()};
                          V -> V
                        end,
      update_metainfo(read, LServer, LUser, Conversation, LastMsgID, Type, TS);
    _ ->
      ok
  end.

conversation_sql_upsert(LServer, LUser, Conversation , Options) ->
  Type = proplists:get_value(type, Options, ?NS_XABBER_CHAT),
  Thread = proplists:get_value(thread, Options, <<"">>),
  Encrypted = proplists:get_value(encrypted, Options, false),
  GroupInfo = proplists:get_value('group_info', Options, <<"">>),
  Status = proplists:get_value('status', Options, <<"active">>),
  Read = proplists:get_value(read, Options, 0),
  TS = time_now(),
  ?SQL_UPSERT_T(
    "conversation_metadata",
    ["!username=%(LUser)s",
      "!conversation=%(Conversation)s",
      "!type=%(Type)s",
      "updated_at=%(TS)d",
      "read_until = %(Read)s",
      "read_until_ts = %(Read)d",
      "conversation_thread=%(Thread)s",
      "metadata_updated_at=%(TS)d",
      "status=%(Status)s",
      "group_info=%(GroupInfo)s",
      "encrypted=%(Encrypted)b",
      "server_host=%(LServer)s"]).

get_and_store_user_card(LServer,LUser,PeerJID,Message) ->
  {X, Type} = case xmpp:get_subtag(Message,
    #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT}) of
                false ->
                  T = xmpp:get_subtag(Message,#channel_x{xmlns = ?NS_CHANNELS}),
                  {T, #channel_user_card{}};
                T ->
                  {T, #xabbergroupchat_user_card{}}
              end,
  Ref = case X of
        false -> false;
        _ -> xmpp:get_subtag(X,#xmppreference{})
  end,
  Card = case Ref of
           false -> false;
           _ -> xmpp:get_subtag(Ref, Type)
         end,
  case Card of
    false -> false;
    _ -> eg_store_card(LServer,LUser,PeerJID,Card)
  end.


eg_store_card(LServer,LUser,Peer,Pkt) ->
  {PUser, PServer, _} = jid:tolower(Peer),
  Data = get_sync_data(LUser, LServer, PUser, PServer),
  NewData = Data#sync_data{card = Pkt},
  case store_sync_data(NewData) of
    {atomic, ok} -> ok;
    {aborted, Err} ->
      ?ERROR_MSG("Cannot store card for ~s@~s: ~s", [LUser, LServer, Err]), Err
  end.

eg_get_user_card(LUser, LServer, PUser, PServer) ->
  Data = get_sync_data(LUser, LServer, PUser, PServer),
  case Data#sync_data.card of
    undefined -> [];
    Card -> [Card]
  end.

lg_get_user_card(LUser, LServer, PUser, PServer) ->
  User = jid:to_string(jid:make(LUser,LServer)),
  Chat = jid:to_string(jid:make(PUser,PServer)),
  try mod_groups_users:form_user_card(User,Chat) of
    R -> [R]
  catch
    _:_ -> []
  end.

identify_encryption_type(Pkt) ->
  find_encryption(xmpp:get_els(Pkt)).

find_encryption(Els) ->
  R = lists:foldl(fun(El, Acc0) ->
    Name = xmpp:get_name(El),
    NS = xmpp:get_ns(El),
    case {Name, NS} of
      {<<"encryption">>, <<"urn:xmpp:eme:0">>} ->
        xmpp_codec:get_attr(<<"namespace">>,
          El#xmlel.attrs, false);
      _ ->
        Acc0
    end
                  end, false, Els),
  case R of
    false -> find_encryption_fallback(Els);
    _ -> R
  end.

find_encryption_fallback(Els) ->
  XEPS = [<<"urn:xmpp:otr:0">>, <<"jabber:x:encrypted">>,
    <<"urn:xmpp:openpgp:0">>, <<"eu.siacs.conversations.axolotl">>,
    <<"urn:xmpp:omemo:1">>, <<"urn:xmpp:omemo:2">>],
  lists:foldl(fun(El, Acc0) ->
    NS = xmpp:get_ns(El),
    case lists:member(NS, XEPS) of
      true -> NS;
      false -> Acc0
    end
              end, false, Els).

-spec update_mam_prefs(atom(), jid(), jid()) -> stanza() | error.
update_mam_prefs(_Action, User, User) ->
%%  skip for myself
  ok;
update_mam_prefs(Action, User, Contact) ->
  ContactBare = jid:remove_resource(Contact),
  case get_mam_prefs(User) of
    #mam_prefs{never=Never0} = Prefs ->
      Never1 = case Action of
                 add -> Never0 ++ [ContactBare];
                 _ ->
                   L1 = lists:usort([jid:tolower(jid:remove_resource(J)) || J <- Never0]),
                   L2 = L1 -- [jid:tolower(ContactBare)],
                   [jid:make(LJ) || LJ <- L2]
               end,
      set_mam_prefs(User, Prefs#mam_prefs{never = Never1});
    _ ->
      error
  end.

set_mam_prefs(#jid{lserver = LServer} = User, Prefs) ->
  IQ = #iq{from = User,
    to = #jid{lserver = LServer},
    type = set,
    sub_els = [Prefs]},
  mod_mam:pre_process_iq_v0_3(IQ).

%% Makes two request attempts in case of a temporary database error
get_mam_prefs(User) ->
  get_mam_prefs(User, 2).

get_mam_prefs(_User, 0) ->
  error;
get_mam_prefs(#jid{lserver = LServer} = User, Retry) ->
  IQ = #iq{from = User,
    to = #jid{lserver = LServer},
    type = get, sub_els = [#mam_prefs{xmlns = ?NS_MAM_2}]},
  case mod_mam:pre_process_iq_v0_3(IQ) of
    #iq{type = result, sub_els = [#mam_prefs{} = Prefs]} ->
      Prefs;
    _  ->
      get_mam_prefs(User, Retry - 1)
  end.

filter_packet(Pkt,BareJID) ->
  Els = xmpp:get_els(Pkt),
  NewEls = lists:filtermap(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"stanza-id">> andalso NS == ?NS_SID_0);
      (Name == <<"time">> andalso NS == ?NS_UNIQUE) ->
        try xmpp:decode(El) of
          #stanza_id{by = By} ->
            By == BareJID;
          #unique_time{by = By} ->
            By == BareJID
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          true
      end
    end, Els),
  xmpp:set_els(Pkt, NewEls).

time_now() ->
  {MSec, Sec, USec} = erlang:timestamp(),
  (MSec*1000000 + Sec)*1000000 + USec.

ts_to_usec(ErlangTS) ->
  {MSec, Sec, USec} = ErlangTS,
  (MSec*1000000 + Sec)*1000000 + USec.

send_cast(LServer, Message) ->
  Proc = gen_mod:get_module_proc(LServer, ?MODULE),
  gen_server:cast(Proc, Message).

save_last_action(Acc, Message) ->
  lists:sublist([Message | Acc],50).

is_local(Host) ->
  lists:member(Host,ejabberd_config:get_myhosts()).
