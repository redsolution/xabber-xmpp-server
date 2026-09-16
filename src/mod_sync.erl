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

-protocol({xep, 'SYNC', '0.10.0'}).

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
  process_messages/0, remove_user/2, roster_in_subscription/2]).

%% iq
-export([process_iq/1]).
-type c2s_state() :: ejabberd_c2s:state().

% API
-export([is_muted/3, is_muted/4, migrate_external_group_message_meta/1]).

%% records
-record(state, {
  host = <<"">> :: binary()
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

-define(NS_OMEMO, <<"urn:xmpp:omemo:2">>).
-define(TABLE_SIZE_LIMIT, 2000000000). % A bit less than 2 GiB.
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
  sync_external_groups:init_tables(),
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

handle_cast({external_group, save_message, Group, StanzaID, Packet, TS},
    #state{host = LServer} = State) ->
  sync_external_groups:store_message(
    LServer, Group, StanzaID, Packet, TS),
  {noreply, State};
handle_cast({external_group, change_last_message, Group, Replace}, State)->
  sync_external_groups:change_last_message(Group, Replace),
  {noreply, State};
handle_cast({external_group, delete_message, Group, StanzaID, UserID, Ver},
    #state{host = LServer} = State) ->
  sync_external_groups:delete_message(
    LServer, Group, StanzaID, UserID, Ver),
  {noreply, State};
handle_cast({external_group, cleanup_cache, Conversation, Group},
    #state{host = LServer} = State) ->
  sync_external_groups:cleanup_if_unused(
    LServer, Conversation, Group),
  {noreply, State};
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
  case xmpp:has_subtag(IQ,#groups_decline{}) of
    true ->
      {LUser, LServer,_} = jid:tolower(From),
      {PUser, PServer,_} = jid:tolower(To),
      delete_invite(LUser,LServer,PUser,PServer),
      deactivate_conversation(LServer,LUser,
        #sync_conversation{jid = jid:make(PUser,PServer),
          type = ?NS_GROUPS});
    _ -> ok
  end,
  {noreply, State};
handle_cast({user_send, #presence{type = Type,
  from = From, to = To}}, State)
  when Type == subscribe orelse Type == subscribed  ->
  {LUser, LServer,_} = jid:tolower(From),
  {PUser, PServer,_} = jid:tolower(To),
  delete_invite(LUser,LServer,PUser,PServer),
  {noreply, State};
handle_cast({user_send, #presence{type = unsubscribe,
  from = From, to = To}}, State) ->
  {LUser, LServer,_} = jid:tolower(From),
  {PUser, PServer,_} = jid:tolower(To),
  maybe_delete_invite_and_conversation(LUser,LServer,PUser,PServer),
  {noreply, State};
handle_cast({user_send, #presence{type = unsubscribed,
  from = From, to = To}}, State) ->
  {LUser, LServer,_} = jid:tolower(From),
  maybe_delete_invite_or_presence(LUser, LServer, To),
  {noreply, State};
handle_cast({sm, #presence{type = subscribe}}, State) ->
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
  sync_external_groups:delete_read_messages(Host),
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
  ejabberd_hooks:add(user_send_packet, Host, ?MODULE,
    user_send_packet, 101),
  ejabberd_hooks:add(sm_receive_packet, Host, ?MODULE,
    sm_receive_packet, 55),
  ejabberd_hooks:add(roster_in_subscription, Host, ?MODULE,
    roster_in_subscription, 60),
  ejabberd_hooks:add(c2s_post_auth_features, Host, ?MODULE,
    c2s_stream_features, 50),
  ejabberd_hooks:add(remove_user, Host, ?MODULE,
    remove_user, 60).

unregister_hooks(Host) ->
  ejabberd_hooks:delete(user_send_packet, Host, ?MODULE,
    user_send_packet, 101),
  ejabberd_hooks:delete(sm_receive_packet, Host, ?MODULE,
    sm_receive_packet, 55),
  ejabberd_hooks:delete(roster_in_subscription, Host, ?MODULE,
    roster_in_subscription, 60),
  ejabberd_hooks:delete(c2s_post_auth_features, Host, ?MODULE,
    c2s_stream_features, 50),
  ejabberd_hooks:delete(remove_user, Host, ?MODULE,
    remove_user, 60).

c2s_stream_features(Acc, Host) ->
  case gen_mod:is_loaded(Host, ?MODULE) of
    true ->
      [#sync_synchronization{}|Acc];
    false ->
      Acc
  end.

-spec sm_receive_packet(stanza()) -> stanza().
sm_receive_packet(#message{to = #jid{luser = LUser, lserver = LServer}} = Pkt) ->
  Proc = get_subprocess(LUser,LServer),
  Proc ! {in, Pkt},
  Pkt;
%% Incoming subscribe is handled via roster_in_subscription so online and
%% offline requests update sync conversations through the same roster state.
sm_receive_packet(#presence{type = subscribe} = Pkt) ->
  Pkt;
sm_receive_packet(#presence{to = #jid{lserver = LServer}} = Pkt) ->
  send_cast(LServer, {sm,Pkt}),
  Pkt;
sm_receive_packet(Acc) ->
  Acc.

-spec roster_in_subscription(boolean(), presence()) -> boolean().
roster_in_subscription(true = Acc, #presence{type = subscribe} = Presence) ->
  process_subscription_request(Presence),
  Acc;
roster_in_subscription(Acc, _Presence) ->
  Acc.

-spec process_subscription_request(presence()) -> ok.
process_subscription_request(#presence{from = From,
  to = #jid{lserver = LServer, luser = LUser}} = Presence) ->
  case mod_xabber_entity:is_group(LUser, LServer) of
    false ->
      Type =
        case xmpp:get_subtag(Presence, #groups_group{}) of
          false ->
            maybe_push_notification(LUser, LServer,
              jid:to_string(jid:remove_resource(From)), ?NS_XABBER_CHAT,
              <<"subscribe">>, #presence{type = subscribe, from = From}),
            ?NS_XABBER_CHAT;
          _ ->
            ?NS_GROUPS
        end,
      Conversation = jid:to_string(jid:remove_resource(From)),
      create_conversation(LServer, LUser, Conversation, <<"">>, false, Type);
    _ ->
      ok
  end.

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
  gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_XABBER_SYNCHRONIZATION,
    ?MODULE, process_iq).

-spec unregister_iq_handlers(binary()) -> ok.
unregister_iq_handlers(Host) ->
  gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_XABBER_SYNCHRONIZATION).

process_iq(#iq{type = get, sub_els = [#sync_query{}]} = IQ) ->
  spawn(async_make_result(IQ)),
  ignore;
process_iq(#iq{sub_els = [SyncQuery]} = IQ) ->
  case xmpp:get_subtag(SyncQuery, #sync_conversation{}) of
    false ->
      xmpp:make_error(IQ, xmpp:err_bad_request());
    Conversation ->
      {LUser, LServer, _} = jid:tolower(IQ#iq.from),
      R = change_conversation(LUser, LServer, Conversation),
      iq_result(IQ, R)
  end;
process_iq(IQ) ->
  xmpp:make_error(IQ, xmpp:err_bad_request()).

iq_result(IQ,ok) ->
  xmpp:make_iq_result(IQ);
iq_result(IQ,{error, Err}) ->
  xmpp:make_error(IQ,Err);
iq_result(IQ,_Result) ->
  xmpp:make_error(IQ, xmpp:err_internal_server_error()).

%%parse_query(#sync_query{xdata = undefined}, _Lang) ->
%%  {ok, []};
%%parse_query(#sync_query{xdata = #xdata{}} = Query, Lang) ->
%%  X = xmpp_util:set_xdata_field(
%%    #xdata_field{var = <<"FORM_TYPE">>,
%%      type = hidden, values = [?NS_XABBER_SYNCHRONIZATION]},
%%    Query#xabber_synchronization_query.xdata),
%%  try	sync_query:decode(X#xdata.fields) of
%%    Form -> {ok, Form}
%%  catch _:{sync_query, Why} ->
%%    Txt = sync_query:format_error(Why),
%%    {error, xmpp:err_bad_request(Txt, Lang)}
%%  end;
%%parse_query(#sync_query{}, _Lang) ->
%%  {ok, []}.

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
process_message(in, #message{type = error}) ->
  ok;
process_message(in, #message{type = groupchat}) ->
  ok;
process_message(in, #message{meta = #{from_offline := true}}) ->
  ok;
process_message(in, #message{to = #jid{luser = LUser, lserver = LServer},
  from = #jid{luser = <<>>, lresource = <<>>, lserver = PDomain},
  body = Body, meta = #{stanza_id := TS}} = Pkt) ->
  ShouldArchive = (xmpp:has_subtag(Pkt, #hint{type = 'store'}) orelse
  xmpp:get_text(Body) /= <<>>),
  if
    ShouldArchive ->
      CType = case xmpp:get_meta(Pkt, conversation_type, undefined) of
                undefined -> not_encrypted;
                T -> T
              end,
      maybe_push_notification(LUser, LServer, PDomain, CType,
        <<"message">>, #stanza_id{id = integer_to_binary(TS),
          by = jid:make(LUser, LServer)}),
      update_metainfo(LServer, LUser, PDomain, CType);
    true ->
      ok
  end;
process_message(in, #message{type = Type, body = [], from = From,
  to = To} = Pkt) ->
  handle_control_message(in, Type, From, To, Pkt);
process_message(in, #message{type = chat, from = Peer, to = To,
  meta = #{stanza_id := TS}} = Pkt) ->
  {LUser, LServer, _ } = jid:tolower(To),
  {PUser, PServer, _} = jid:tolower(Peer),
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  Invite = xmpp:get_subtag(Pkt, #groups_invite{}),
  IsLocal = lists:member(PServer,ejabberd_config:get_myhosts()),
  Type = case xmpp:get_meta(Pkt, conversation_type, undefined) of
            undefined -> ?NS_XABBER_CHAT;
            T -> T
          end,
  if
    Invite  =/= false ->
      #groups_invite{jid = GroupJID} = Invite,
      case GroupJID of
        undefined ->
          %% Bad invite
          ok;
        _ ->
          Group = jid:to_string(jid:remove_resource(GroupJID)),
          store_invite(LUser, LServer, GroupJID, integer_to_binary(TS)),
          create_conversation(LServer,LUser, Group, <<>>, false, ?NS_GROUPS),
          maybe_push_notification(LUser ,LServer, Conversation, ?NS_XABBER_CHAT,
            <<"message">>, #stanza_id{id = integer_to_binary(TS),
              by = jid:remove_resource(To)})
      end;
    Type == ?NS_GROUPS ->
      FilPacket = filter_packet(Pkt,jid:remove_resource(Peer)),
      StanzaID = xmpp:get_subtag(FilPacket, #stanza_id{}),
      UTime = xmpp:get_subtag(FilPacket, #delivery_time{}),
      if
        %% Bad message
        StanzaID == false; UTime == false -> ok;
        true ->
          SID = StanzaID#stanza_id.id,
          case IsLocal of
            false ->
              MsgTS = misc:now_to_usec(UTime#delivery_time.stamp),
              store_external_group_message(
                LServer, {PUser, PServer}, SID, Pkt, MsgTS);
            _ ->
              ok
          end,
          update_metainfo(LServer,LUser,Conversation, Type),
          maybe_push_notification(LUser, LServer, Conversation,
            Type, <<"message">>, StanzaID)
      end;
    true ->
      case handle_call_message(in, Pkt) of
        pass ->
          maybe_push_notification(LUser, LServer, Conversation, Type,
            <<"message">>,#stanza_id{id = integer_to_binary(TS),
              by = jid:remove_resource(To)}),
          update_metainfo(LServer, LUser, Conversation, Type);
        handled ->
          ok
      end
  end;
%%process_message(in, #message{type = headline, body = [], from = From, to = To, sub_els = SubEls})->
%%  DecSubEls = lists:map(fun(El) -> xmpp:decode(El) end, SubEls),
%%  handle_control_sub_el(headline,DecSubEls,From,To);
process_message(out, #message{from = #jid{luser =  LUser, lserver = LServer},
  to = #jid{luser = <<>>, lserver = PDomain, lresource = <<>>},
  meta = #{stanza_id := StanzaID, mam_archived := true} = Meta})->
  CType = case maps:get(conversation_type, Meta, undefined) of
            undefined -> not_encrypted;
            T -> T
          end,
  update_metainfo(LServer, LUser, PDomain, CType, [{read, StanzaID}]),
  maybe_push_notification(LUser,LServer,<<"outgoing">>,
    #stanza_id{id = integer_to_binary(StanzaID), by = jid:make(LUser, LServer)}),
  ok;
process_message(out, #message{from = #jid{luser =  LUser,lserver = LServer},
  to = To, meta = #{stanza_id := StanzaID, mam_archived := true}} = Pkt)->
  %% Messages for groups should not get here,
  %% because the archive for them should be disabled.
  %% But if this happens, only "metadata_updated_at" will be updated.
  case handle_call_message(out, Pkt) of
    handled -> ok;
    pass ->
      Conversation = jid:to_string(jid:remove_resource(To)),
      Type = case xmpp:get_meta(Pkt, conversation_type, undefined) of
                undefined -> not_encrypted;
                T -> T
              end,
      update_metainfo(LServer, LUser, Conversation, Type, [{read, StanzaID}]),
      maybe_push_notification(LUser,LServer,<<"outgoing">>,
        #stanza_id{id = integer_to_binary(StanzaID), by = jid:make(LUser, LServer)})
  end;
process_message(out, #message{type = chat, from = #jid{luser =  LUser,lserver = LServer},
  to = #jid{luser =  PUser,lserver = PServer}} = Pkt) ->
  case handle_call_message(out, Pkt) of
    handled -> ok;
    pass ->
    Displayed = xmpp:get_subtag(Pkt, #mark_displayed{}),
    Conversation = jid:to_string(jid:make(PUser,PServer)),
    Type = get_preferred_conversation_type(LServer, LUser, Conversation),

    case Displayed of
      #mark_displayed{id = _OriginID} when Type == ?NS_GROUPS ->
        FilPacket = filter_packet(Displayed,jid:make(PUser,PServer)),
        StanzaID = case xmpp:get_subtag(FilPacket, #stanza_id{}) of
                     #stanza_id{id = SID} -> SID;
                     _ ->
                       %% for legacy or bad clients
                       {V, _} = get_group_last_message_id_ts(LServer, PUser, PServer),
                       V
                   end,
        case is_local(PServer) of
          true ->
            update_metainfo(read, LServer,LUser,Conversation,
              StanzaID,Type,StanzaID);
          _ ->
            MsgTS = get_external_group_message_ts(
              LServer, PUser, PServer, StanzaID),
            update_metainfo(read, LServer,LUser,Conversation,
              StanzaID,Type,MsgTS)
        end,
        maybe_push_notification(LUser,LServer,<<"displayed">>,Displayed);
      #mark_displayed{id = OriginID} ->
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
  ODBCType = ejabberd_config:get_option({sql_type, LServer}),
  ToString = fun(S) -> ejabberd_sql:to_string_literal(ODBCType, S) end,
  SServer = ToString(LServer),
  SUser = ToString(LUser),
  SConversation = ToString(Conversation),
  SType = ToString(Type),
  HostClause = case ejabberd_sql:use_new_schema() of
                 true ->
                   <<" and server_host=",SServer/binary," ">>;
                 _->
                   <<>>
               end,
  Query = [<<"select conversation, retract,type, conversation_thread,
  read_until,read_until_ts, delivered_until, displayed_until, updated_at, status,
  encrypted, pinned, mute
  from conversation_metadata where username = ">>,SUser,<<" and
  conversation = ">>,SConversation,<<" and type = ">>,
    SType, HostClause,<<";">>],
  case ejabberd_sql:sql_query(LServer, Query) of
    {selected, _, []} ->
      {error, notfound};
    {selected, _, [Res]} ->
      [ConvRes] = convert_result([Res]),
      Roster = mod_roster:get_roster(LUser, LServer),
      MetadataMap = make_metadata_map(LServer, LUser, [ConvRes], Roster),
      make_result_el_from_metadata(LServer, LUser, ConvRes, MetadataMap);
    _ ->
      {error, internal}
  end.

async_make_result(#iq{from = UserJID, sub_els = [
  #sync_query{stamp = Stamp, rsm = RSM}]} = IQ) ->
  Stamp1 = case Stamp of
             undefined -> <<"0">>;
             <<>> -> <<"0">>;
             _ -> Stamp
           end,
  fun() ->
    {LUser, LServer, _} = jid:tolower(UserJID),
    Sync = make_result(LUser, LServer, Stamp1, RSM, []),
    ejabberd_router:route(xmpp:make_iq_result(IQ, Sync))
  end.

make_result(User, Server, Stamp, RSM, Form) ->
  LastStamp = get_last_stamp(Server, User),
  make_result(User, Server, LastStamp, Stamp, RSM, Form).

make_result(_User, _Server, LastStamp, LastStamp, RSM, _) ->
  ResRSM = case RSM of
             undefined -> undefined;
             _ ->
               #rsm_set{count = 0}
           end,
  #sync_query{stamp = LastStamp, rsm = ResRSM};
make_result(User, Server, LastStamp, Stamp, RSM, Form) ->
  {QueryChats, QueryCount} = make_sql_query(Server, User, Stamp, RSM, Form),
  {selected, _, Res} = ejabberd_sql:sql_query(Server, QueryChats),
  {selected, _, [[CountBinary]]} = ejabberd_sql:sql_query(Server, QueryCount),
  Count = binary_to_integer(CountBinary),
  ConvRes = convert_result(Res),
  Roster = mod_roster:get_roster(User, Server),
  Presences = get_pending_subscriptions(User, Server, Roster),
  make_result_with_metadata(User, Server, LastStamp, RSM, ConvRes,
    Presences, Count, Roster).

convert_result(Result) ->
  lists:map(fun(El) ->
    [Conversation,Retract,Type,Thread,
      Read,ReadTS,Delivered,Display,UpdateAt,
      Status,Encrypted, Pinned,Mute] = El,
    {Conversation,binary_to_integer(Retract),Type,Thread,
      Read,ReadTS,Delivered,Display,binary_to_integer(UpdateAt),
      binary_to_atom(Status,utf8),ejabberd_sql:to_bool(Encrypted),
      Pinned,binary_to_integer(Mute)} end, Result).

make_result_with_metadata(User, Server, LastStamp, RSM, ConvRes,
    Presences, Count, Roster) ->
  MetadataMap = make_metadata_map(Server, User, ConvRes, Roster),
  make_result_from_metadata(User, Server, LastStamp, RSM, ConvRes,
    Presences, Count, MetadataMap).

make_metadata_map(Server, User, ConvRes, Roster) ->
  StatusMap = get_group_statuses(Server, User, ConvRes, Roster),
  CountMap = get_unread_counts(Server, User, ConvRes, StatusMap),
  LastMap = get_last_messages(Server, User, ConvRes, StatusMap),
  maps:merge(maps:merge(StatusMap, CountMap), LastMap).

make_result_from_metadata(User, Server, LastStamp, RSM, ConvRes,
    Presences, Count, MetadataMap) ->
  ReplacedConv = lists:map(
    fun(El) ->
      C = make_result_el_from_metadata(Server, User, El, MetadataMap),
      case lists:keyfind(C#sync_conversation.jid,
        #presence.from, Presences) of
        false -> C;
        Presence ->
          xmpp_codec:set_els(C,
            [Presence | C#sync_conversation.sub_els])
      end
    end, ConvRes),
  ResRSM = if
             ReplacedConv /= [] andalso RSM /= undefined ->
               #sync_conversation{stamp = First} = hd(ReplacedConv),
               #sync_conversation{stamp = Last} = lists:last(ReplacedConv),
               #rsm_set{first = #rsm_first{data = First},
                 last = Last,
                 count = Count};
             ReplacedConv == [] andalso RSM /= undefined ->
               #rsm_set{count = Count};
             true ->
               undefined
           end,
  #sync_query{sub_els = ReplacedConv,
    stamp = LastStamp, rsm = ResRSM}.

make_result_el_from_metadata(LServer, LUser, El, MetadataMap) ->
  {Conversation, Retract, Type, Thread, Read, ReadTS, Delivered,
    Display, UpdateAt, ConversationStatus, Encrypted,
    Pinned,Mute} = El,
  ConversationMetadata = make_synchronization_metadata(
    LUser, LServer, Conversation, Read, ReadTS, Delivered, Display,
    ConversationStatus, Retract, Type, Encrypted, MetadataMap),
  CElem = #sync_conversation{
    stamp = integer_to_binary(UpdateAt),
    type = Type, status = ConversationStatus,
    thread = Thread,
    jid = jid:from_string(Conversation),
    pinned = Pinned,
    sub_els = ConversationMetadata},
  Now = erlang:system_time(second),
  if
    Mute >= Now -> CElem#sync_conversation{mute = integer_to_binary(Mute)};
    true -> CElem
  end.

make_synchronization_metadata(_LUser, _LServer, _Conversation,
    _Read, _ReadTS, _Delivered, _Display, deleted, _Retract, _Type,
    _Encrypted, _MetadataMap) ->
  [];
make_synchronization_metadata(LUser, LServer, Conversation,
    Read, _ReadTS, Delivered, Display, _ConversationStatus, Retract, Type,
    Encrypted, MetadataMap) ->
  {PUser, PServer,_} = jid:tolower(jid:from_string(Conversation)),
  IsLocal = is_local(PServer),
  case Type of
    ?NS_GROUPS when IsLocal == true ->
      Chat = jid:to_string(jid:make(PUser,PServer)),
      Count = unread_count({local_group, Chat}, MetadataMap),
      LastMessage = last_message({last, local_group, Chat}, MetadataMap),
      Unread = #sync_unread{count = Count, 'after' = Read},
      XabberDelivered = #sync_delivered{id = Delivered},
      XabberDisplayed = #sync_displayed{id = Display},
      SubEls = [Unread, XabberDisplayed, XabberDelivered] ++ LastMessage,
      [#sync_metadata{node = ?NS_XABBER_REWRITE,
        sub_els = [#sync_retract{version = Retract}]},
        #sync_metadata{node = ?NS_XABBER_SYNCHRONIZATION, sub_els = SubEls}];
    ?NS_GROUPS ->
      Chat = jid:to_string(jid:make(PUser,PServer)),
      Count = unread_count({external_group, Chat}, MetadataMap),
      LastMessage = last_message({last, external_group, Chat}, MetadataMap),
      Unread = #sync_unread{count = Count, 'after' = Read},
      XabberDelivered = #sync_delivered{id = Delivered},
      XabberDisplayed = #sync_displayed{id = Display},
      SubEls = [Unread, XabberDisplayed, XabberDelivered] ++ LastMessage,
      [#sync_metadata{node = ?NS_XABBER_REWRITE,
        sub_els = [#sync_retract{version = Retract}]},
        #sync_metadata{node = ?NS_XABBER_SYNCHRONIZATION, sub_els = SubEls}];
    _ when Encrypted == true ->
      Count = unread_count({chat, Conversation, Type}, MetadataMap),
      LastMessage = last_message({last, chat, Conversation, Type}, MetadataMap),
      Unread = #sync_unread{count = Count, 'after' = Read},
      XabberDelivered = #sync_delivered{id = Delivered},
      XabberDisplayed = #sync_displayed{id = Display},
      SubEls = [Unread, XabberDisplayed, XabberDelivered] ++ LastMessage,
      [#sync_metadata{node = ?NS_XABBER_REWRITE,
        sub_els = [#sync_retract{version = Retract}]},
        #sync_metadata{node = ?NS_XABBER_SYNCHRONIZATION, sub_els = SubEls}];
    _ ->
      Count = unread_count({chat, Conversation, ?NS_XABBER_CHAT}, MetadataMap),
      LastMessage = last_message(
        {last, chat, Conversation, ?NS_XABBER_CHAT}, MetadataMap),
      LastCall = case get_actual_last_call(LUser, LServer, PUser, PServer) of
                   [] -> [];
                   Calls ->
                     [#sync_metadata{node = ?NS_JINGLE_MESSAGE,
                       sub_els = Calls}]
                 end,
      Unread = #sync_unread{count = Count, 'after' = Read},
      XabberDelivered = #sync_delivered{id = Delivered},
      XabberDisplayed = #sync_displayed{id = Display},
      SubEls = [Unread, XabberDisplayed, XabberDelivered] ++ LastMessage,
      [#sync_metadata{node = ?NS_XABBER_REWRITE,
        sub_els = [#sync_retract{version = Retract}]},
        #sync_metadata{node = ?NS_XABBER_SYNCHRONIZATION,
          sub_els = SubEls}] ++ LastCall
  end.

unread_count(Key, CountMap) ->
  case maps:find(Key, CountMap) of
    {ok, Count} -> Count;
    error -> error({missing_unread_count, Key})
  end.

last_message(Key, MetadataMap) ->
  case maps:find(Key, MetadataMap) of
    {ok, Message} -> Message;
    error -> error({missing_last_message, Key})
  end.

local_group_status(Chat, MetadataMap) ->
  case maps:find({status, local_group, Chat}, MetadataMap) of
    {ok, Status} -> Status;
    error -> error({missing_local_group_status, Chat})
  end.

external_group_status(Chat, MetadataMap) ->
  case maps:find({status, external_group, Chat}, MetadataMap) of
    {ok, Status} -> Status;
    error -> error({missing_external_group_status, Chat})
  end.

get_group_statuses(LServer, LUser, ConvRes, Roster) ->
  {LocalReqs, ExternalReqs} =
    lists:foldl(
      fun collect_group_status_request/2,
      {#{}, #{}},
      ConvRes),
  LocalReqList = maps:values(LocalReqs),
  ExternalReqList = maps:values(ExternalReqs),
  LocalStatusMap = sync_local_groups:statuses(
    LServer, LUser, LocalReqList),
  ExternalStatusMap = batch_get_external_group_statuses(
    LServer, LUser, ExternalReqList, Roster),
  maps:merge(LocalStatusMap, ExternalStatusMap).

collect_group_status_request(
    {_Conversation, _Retract, _Type, _Thread,
    _Read, _ReadTS, _Delivered, _Display, _UpdateAt, deleted, _Encrypted,
    _Pinned, _Mute}, Acc) ->
  Acc;
collect_group_status_request(
    {Conversation, _Retract, Type, _Thread,
    _Read, _ReadTS, _Delivered, _Display, _UpdateAt, _ConversationStatus,
    _Encrypted, _Pinned, _Mute}, Acc) ->
  {PUser, PServer,_} = jid:tolower(jid:from_string(Conversation)),
  case Type of
    ?NS_GROUPS ->
      case is_local(PServer) of
        true ->
          Chat = jid:to_string(jid:make(PUser,PServer)),
          {LocalReqs, ExternalReqs} = Acc,
          {maps:put(Chat, Chat, LocalReqs), ExternalReqs};
        _ ->
          Chat = jid:to_string(jid:make(PUser,PServer)),
          {LocalReqs, ExternalReqs} = Acc,
          {LocalReqs,
            maps:put(Chat, {Chat, jid:from_string(Conversation)},
              ExternalReqs)}
      end;
    _ ->
      Acc
  end.

batch_get_external_group_statuses(_LServer, _LUser, [], _Roster) ->
  #{};
batch_get_external_group_statuses(_LServer, _LUser, Reqs, Roster) ->
  RosterStatusMap = roster_status_map(Roster),
  maps:from_list(
    [{{status, external_group, Chat},
      maps:get(jid:tolower(jid:remove_resource(JID)), RosterStatusMap, none)}
     || {Chat, JID} <- Reqs]).

roster_status_map(Roster) ->
  maps:from_list(
    [{jid:remove_resource(JID), Subscription}
      || #roster{jid = JID, subscription = Subscription} <- Roster]).

get_unread_counts(LServer, LUser, ConvRes, StatusMap) ->
  {ChatReqs, GroupReqs, ExternalReqs, CountMap0} =
    lists:foldl(
      fun(El, Acc) ->
        collect_unread_count_request(LServer, LUser, El, StatusMap, Acc)
      end,
      {#{}, #{}, #{}, #{}},
      ConvRes),
  ChatReqList = maps:values(ChatReqs),
  GroupReqList = maps:values(GroupReqs),
  ExternalReqList = maps:values(ExternalReqs),
  ChatCountMap = sync_archive_reader:counts(LServer, LUser, ChatReqList),
  GroupCountMap = sync_local_groups:counts(
    jid:to_string(jid:make(LUser,LServer)), GroupReqList),
  ExternalCountMap = sync_external_groups:batch_counts(
    LServer, ExternalReqList),
  maps:merge(
    maps:merge(maps:merge(CountMap0, ChatCountMap), GroupCountMap),
    ExternalCountMap).

collect_unread_count_request(_LServer, _LUser,
    {_Conversation, _Retract, _Type, _Thread,
    _Read, _ReadTS, _Delivered, _Display, _UpdateAt, deleted, _Encrypted,
    _Pinned, _Mute}, _StatusMap, Acc) ->
  Acc;
collect_unread_count_request(_LServer, _LUser,
    {Conversation, _Retract, Type, _Thread,
    Read, ReadTS, _Delivered, _Display, _UpdateAt, _ConversationStatus,
    Encrypted, _Pinned, _Mute}, StatusMap,
    {ChatReqs, GroupReqs, ExternalReqs, CountMap}) ->
  {PUser, PServer,_} = jid:tolower(jid:from_string(Conversation)),
  IsLocal = is_local(PServer),
  case Type of
    ?NS_GROUPS when IsLocal == true ->
      Chat = jid:to_string(jid:make(PUser,PServer)),
      Status = local_group_status(Chat, StatusMap),
      collect_local_group_unread_count_request(
        Chat, PUser, PServer, Read, Status,
        {ChatReqs, GroupReqs, ExternalReqs, CountMap});
    ?NS_GROUPS ->
      Chat = jid:to_string(jid:make(PUser,PServer)),
      Status = external_group_status(Chat, StatusMap),
      collect_external_group_unread_count_request(
        Chat, PUser, PServer, ReadTS, Status,
        {ChatReqs, GroupReqs, ExternalReqs, CountMap});
    _ when Encrypted == true ->
      Key = {chat, Conversation, Type},
      {maps:put(Key, {Key, Conversation, Read, Type}, ChatReqs),
        GroupReqs, ExternalReqs, CountMap};
    _ ->
      Key = {chat, Conversation, ?NS_XABBER_CHAT},
      {maps:put(Key, {Key, Conversation, Read, ?NS_XABBER_CHAT}, ChatReqs),
        GroupReqs, ExternalReqs, CountMap}
  end.

collect_local_group_unread_count_request(Chat, GUser, GServer, Read,
    <<"both">>, {ChatReqs, GroupReqs, ExternalReqs, CountMap}) ->
  Key = {local_group, Chat},
  ReqKey = {GServer, Chat},
  {ChatReqs,
    maps:put(ReqKey, {Key, Chat, GUser, GServer, Read}, GroupReqs),
    ExternalReqs, CountMap};
collect_local_group_unread_count_request(Chat, _GUser, _GServer, _Read,
    _Status, {ChatReqs, GroupReqs, ExternalReqs, CountMap}) ->
  {ChatReqs, GroupReqs, ExternalReqs,
    maps:put({local_group, Chat}, 0, CountMap)}.

collect_external_group_unread_count_request(Chat, GUser, GServer, ReadTS,
    both, {ChatReqs, GroupReqs, ExternalReqs, CountMap}) ->
  Key = {external_group, Chat},
  ReqKey = {GServer, Chat},
  {ChatReqs, GroupReqs,
    maps:put(ReqKey, {Key, Chat, GUser, GServer, ReadTS}, ExternalReqs),
    CountMap};
collect_external_group_unread_count_request(Chat, _GUser, _GServer, _ReadTS,
    _Status, {ChatReqs, GroupReqs, ExternalReqs, CountMap}) ->
  {ChatReqs, GroupReqs, ExternalReqs,
    maps:put({external_group, Chat}, 0, CountMap)}.

get_last_messages(LServer, LUser, ConvRes, StatusMap) ->
  {ChatReqs, EncryptedReqs, GroupReqs, ExternalReqs} =
    lists:foldl(
      fun(El, Acc) ->
        collect_last_message_request(LServer, LUser, El, StatusMap, Acc)
      end,
      {#{}, #{}, #{}, #{}},
      ConvRes),
  ChatReqList = maps:values(ChatReqs),
  EncryptedReqList = maps:values(EncryptedReqs),
  GroupReqList = maps:values(GroupReqs),
  ExternalReqList = maps:values(ExternalReqs),
  ChatLastMap = sync_archive_reader:last_informative_messages(
    LServer, LUser, ChatReqList),
  EncryptedLastMap =
    sync_archive_reader:last_encrypted_messages(
      LServer, LUser, EncryptedReqList),
  GroupLastMap = batch_get_local_group_last_messages(
    LServer, LUser, GroupReqList),
  ExternalLastMap =
    batch_get_external_group_last_messages(LServer, LUser, ExternalReqList),
  maps:merge(
    maps:merge(maps:merge(ChatLastMap, EncryptedLastMap), GroupLastMap),
    ExternalLastMap).

collect_last_message_request(_LServer, _LUser,
    {_Conversation, _Retract, _Type, _Thread,
    _Read, _ReadTS, _Delivered, _Display, _UpdateAt, deleted, _Encrypted,
    _Pinned, _Mute}, _StatusMap, Acc) ->
  Acc;
collect_last_message_request(_LServer, _LUser,
    {Conversation, _Retract, Type, _Thread,
    _Read, _ReadTS, _Delivered, _Display, _UpdateAt, _ConversationStatus,
    Encrypted, _Pinned, _Mute}, StatusMap,
    {ChatReqs, EncryptedReqs, GroupReqs, ExternalReqs}) ->
  {PUser, PServer,_} = jid:tolower(jid:from_string(Conversation)),
  IsLocal = is_local(PServer),
  case Type of
    ?NS_GROUPS when IsLocal == true ->
      Chat = jid:to_string(jid:make(PUser,PServer)),
      Status = local_group_status(Chat, StatusMap),
      collect_local_group_last_message_request(
        Chat, PUser, PServer, Status,
        {ChatReqs, EncryptedReqs, GroupReqs, ExternalReqs});
    ?NS_GROUPS ->
      Chat = jid:to_string(jid:make(PUser,PServer)),
      Status = external_group_status(Chat, StatusMap),
      collect_external_group_last_message_request(
        Chat, PUser, PServer, Status,
        {ChatReqs, EncryptedReqs, GroupReqs, ExternalReqs});
    _ when Encrypted == true ->
      Key = {last, chat, Conversation, Type},
      {ChatReqs,
        maps:put(Key, {Key, Conversation, Type}, EncryptedReqs),
        GroupReqs, ExternalReqs};
    _ ->
      Key = {last, chat, Conversation, ?NS_XABBER_CHAT},
      {maps:put(Key, {Key, Conversation}, ChatReqs),
        EncryptedReqs, GroupReqs, ExternalReqs}
  end.

collect_local_group_last_message_request(Chat, GUser, GServer, Status,
    {ChatReqs, EncryptedReqs, GroupReqs, ExternalReqs}) ->
  Key = {last, local_group, Chat},
  ReqKey = {GServer, Chat},
  {ChatReqs, EncryptedReqs,
    maps:put(ReqKey, {Key, Chat, GUser, GServer, Status}, GroupReqs),
    ExternalReqs}.

collect_external_group_last_message_request(Chat, GUser, GServer, Status,
    {ChatReqs, EncryptedReqs, GroupReqs, ExternalReqs}) ->
  Key = {last, external_group, Chat},
  {ChatReqs, EncryptedReqs, GroupReqs,
    maps:put(Chat, {Key, Chat, GUser, GServer, Status}, ExternalReqs)}.

batch_get_local_group_last_messages(_LServer, _LUser, []) ->
  #{};
batch_get_local_group_last_messages(LServer, LUser, Reqs) ->
  {ArchiveReqs, InviteReqs} =
    lists:partition(fun({_Key, _Chat, _GUser, _GServer, <<"both">>}) ->
      true;
      (_) ->
        false
    end, Reqs),
  maps:merge(
    sync_local_groups:archive_last_messages(ArchiveReqs),
    batch_get_local_group_invites(LServer, LUser, InviteReqs)).

batch_get_local_group_invites(_LServer, _LUser, []) ->
  #{};
batch_get_local_group_invites(LServer, LUser, Reqs) ->
  maps:from_list(
    [{Key, get_invite(LServer, LUser, GUser, GServer)}
      || {Key, _Chat, GUser, GServer, _Status} <- Reqs]).

batch_get_external_group_last_messages(_LServer, _LUser, []) ->
  #{};
batch_get_external_group_last_messages(LServer, LUser, Reqs) ->
  maps:from_list(
    [{Key, external_group_last_message(LUser, LServer, GUser, GServer, Status)}
      || {Key, _Chat, GUser, GServer, Status} <- Reqs]).

external_group_last_message(LUser, LServer, GUser, GServer, both) ->
  sync_external_groups:last_message(
    LUser, LServer, GUser, GServer, both);
external_group_last_message(LUser, LServer, GUser, GServer, _Status) ->
  get_invite(LServer, LUser, GUser, GServer).

get_pending_subscriptions(LUser, LServer, Roster) ->
  BareJID = jid:make(LUser, LServer),
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
    end, Roster).

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
      [#sync_call{sub_els = [Pkt]}];
    #sync_data{call_msg = _Pkt, call_ts = _TS} ->
      delete_last_call(jid:make(PUser, PServer), LUser, LServer),
      [];
    _ -> []
  end.

%% External group cache helpers. The async boundary stays in mod_sync;
%% storage, deduplication and counter queries live in sync_external_groups.
store_external_group_message(LServer, Group, StanzaID, Packet, TS) ->
  send_cast(LServer,
    {external_group, save_message, Group, StanzaID, Packet, TS}).

migrate_external_group_message_meta(Server) ->
  sync_external_groups:migrate_message_meta(Server).

maybe_change_external_group_last_message(LServer, ConversationJID, Replace) ->
  {PUser, PServer, _} = jid:tolower(ConversationJID),
  send_cast(LServer,
    {external_group, change_last_message, {PUser, PServer}, Replace}).

%% Get the last non-system message ID in the external group
get_external_group_last_message_id_ts(LServer, GUser, GServer) ->
  sync_external_groups:last_message_id_ts(LServer, GUser, GServer).

get_external_group_message_ts(LServer, GUser, GServer, StanzaID) ->
  sync_external_groups:message_ts(LServer, GUser, GServer, StanzaID).

%% Delete last message in the external group by stanza ID
delete_external_group_message(LServer, PUser, PServer, StanzaID, Version) ->
  send_cast(LServer,
    {external_group, delete_message, {PUser, PServer}, StanzaID, <<>>, Version}).

%% Delete last message in the external group by user ID
delete_external_group_user_messages(LServer, PUser, PServer, UserID, Version) ->
  send_cast(LServer,
    {external_group, delete_message, {PUser, PServer}, <<>>, UserID, Version}).

%% Delete all message in the external group.
delete_all_external_group_messages(LServer, PUser, PServer, Version) ->
  send_cast(LServer,
    {external_group, delete_message, {PUser, PServer}, all, all, Version}).

get_stanza_id(Pkt,BareJID) ->
  case xmpp:get_subtag(Pkt, #stanza_id{}) of
    #stanza_id{by = BareJID, id = StanzaID} ->
      StanzaID;
    _ ->
      undefined
  end.

get_unique_time(Pkt,BareJID) ->
  case xmpp:get_subtag(Pkt, #delivery_time{}) of
    #delivery_time{by = BareJID, stamp = TS} ->
      misc:now_to_usec(TS);
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

get_group_last_message_id_ts(LServer, GUser, GServer)->
  case is_local(GServer) of
    true ->
      R = sync_local_groups:last_message_id(GUser, GServer),
      {R, R};
    _ ->
      get_external_group_last_message_id_ts(LServer, GUser, GServer)
  end.

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
                Type == ?NS_XABBER_CHAT; Type == ?NS_GROUPS -> false;
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
        IsGroup = lists:keymember(?NS_GROUPS, 1, List),
        if
          is_tuple(Chat) ->
            {Type, Status, Mute} = Chat,
            sql_metainfo_update_t(LServer, LUser, Conv, Type, Status, Mute, Opts);
          not IsGroup andalso Type /= ?NS_GROUPS ->
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
    SID when Type /= ?NS_GROUPS->
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
    NewType /= ?NS_GROUPS ->
      update_mam_prefs(remove,jid:make(LUser,LServer),
        jid:from_string(Conv));
    true -> ok
  end,
  lists:foreach(fun(CType) ->
    deactivate_conversation(LServer,LUser,
      #sync_conversation{type = CType, jid = ConvJID})
    end, OldTypes),
  Encrypted = if
                NewType == ?NS_XABBER_CHAT;
                NewType == ?NS_GROUPS -> false;
                true -> true
              end,
  create_conversation(LServer, LUser, Conv,
    <<>>, Encrypted, NewType),
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

get_preferred_conversation_type(LServer, LUser, Conversation) ->
  case get_conversation_type(LServer, LUser, Conversation) of
    Types when is_list(Types) ->
      case lists:member(?NS_GROUPS, Types) of
        true -> ?NS_GROUPS;
        false ->
          case Types of
            [Type] -> Type;
            _ -> undefined
          end
      end;
    _ ->
      undefined
  end.


%% Retract version in sync metadata is a client-side optimization hint.
%% Authoritative rewrite/retract state lives in retract archives. For p2p
%% chats the archive version is per user, while group chats have their own
%% archive versions, so this watermark is stored on each conversation row
%% returned by sync.
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

convert_message(TS, XML, Peer, Kind, Nick, LUser, LServer) ->
  case mod_mam_sql:make_archive_el(integer_to_binary(TS), XML, Peer,
    Kind, Nick, chat, jid:make(LUser,LServer), jid:make(LUser,LServer)) of
    {ok, ArchiveElement} ->
      #forwarded{sub_els = [Message]} = ArchiveElement,
      [#sync_last{sub_els = [Message]}];
    _ ->
      []
  end.


%%%===================================================================
%%% Handle control messages
%%%===================================================================

handle_control_message(Direction, Type, From, To,
    #message{sub_els = SubEls} = Pkt) ->
  case handle_call_message(Direction, Pkt) of
    handled ->
      ok;
    pass ->
      handle_control_sub_els(Type, SubEls, From, To)
  end.

handle_control_sub_els(Type, SubEls, From, To) ->
  lists:foreach(fun(El)->
    try xmpp:decode(El) of
      SubEl -> handle_control_sub_el(Type, SubEl, From, To)
    catch _:_ -> ok
    end end, SubEls).

handle_control_sub_el(chat, #mark_displayed{id = OriginID} = Displayed,
    From, To) ->
  {PUser, PServer, _} = jid:tolower(From),
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  {LUser,LServer,_} = jid:tolower(To),
  BareJID = jid:make(LUser,LServer),
  Type = get_preferred_conversation_type(LServer, LUser, Conversation),
  PeerJID = jid:make(PUser,PServer),
  {Type1, StanzaID, TS} =
    if
      Type == ?NS_GROUPS ->
        Displayed2= filter_packet(Displayed,PeerJID),
        SID = get_stanza_id(Displayed2,PeerJID,LServer,OriginID),
        TS1 = case is_local(PServer) of
               true -> SID;
               _ -> get_external_group_message_ts(LServer, PUser, PServer, SID)
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
handle_control_sub_el(chat, #mark_received{id = OriginID} = Delivered,
    From, To) ->
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
handle_control_sub_el(headline, #retract_message{version = _Version,
  id = undefined, conversation = _Conv}, _From, _To) ->
  ok;
handle_control_sub_el(headline, #retract_message{version = _Version,
  id = _ID, conversation = undefined}, _From, _To) ->
  ok;
handle_control_sub_el(headline, #retract_message{version =  undefined,
  id = _ID, conversation = _Conv}, _From, _To) ->
  ok;
handle_control_sub_el(headline, #retract_message{type = Type,
  version = Version, id = StanzaID, conversation = ConversationJID}, _From,
  To) ->
  #jid{luser = LUser, lserver = LServer} = To,
  #jid{luser = PUser, lserver = PServer} = ConversationJID,
  case lists:member(PServer,ejabberd_config:get_myhosts()) of
    false ->
      delete_external_group_message(
        LServer, PUser, PServer, StanzaID, Version);
    _ -> ok
  end,
  Conversation = jid:to_string(ConversationJID),
  TS = time_now(),
  update_retract(LServer,LUser,Conversation,Version,Type, TS),
  ok;
handle_control_sub_el(headline, #retract_user{version = Version,
  id = UserID, conversation = ConversationJID, type = Type0}, _From, To) ->
  #jid{luser = LUser, lserver = LServer} = To,
  #jid{luser = PUser, lserver = PServer} = ConversationJID,
  case lists:member(PServer,ejabberd_config:get_myhosts()) of
    false ->
      delete_external_group_user_messages(
        LServer, PUser, PServer, UserID, Version);
    _ -> ok
  end,
  Conversation = jid:to_string(ConversationJID),
  TS = time_now(),
  Type = case Type0 of
           <<>> -> ?NS_GROUPS;
           undefined -> ?NS_GROUPS;
           _ -> Type0
         end,
  update_retract(LServer,LUser,Conversation,Version,Type,TS),
  ok;
handle_control_sub_el(headline,
  #retract_all{type = Type, version = Version,
  conversation = ConversationJID}, _From, To)
  when ConversationJID =/= undefined andalso Version =/= undefined ->
  #jid{luser = LUser, lserver = LServer} = To,
  #jid{luser = PUser, lserver = PServer} = ConversationJID,
  Conversation = jid:to_string(ConversationJID),
  TS = time_now(),
  case lists:member(PServer,ejabberd_config:get_myhosts()) of
    false ->
      delete_all_external_group_messages(LServer, PUser, PServer, Version);
    _ -> ok
  end,
  update_retract(LServer,LUser,Conversation,Version,Type,TS),
  ok;
handle_control_sub_el(headline, #replace{version = undefined,
  conversation = _ConversationJID} = _Retract, _From, _To) ->
  ok;
handle_control_sub_el(headline, #replace{type = Type, version = Version,
  conversation = ConversationJID} = Replace, _From, To) ->
  #jid{luser = LUser, lserver = LServer} = To,
  Conversation = jid:to_string(ConversationJID),
  maybe_change_external_group_last_message(LServer, ConversationJID, Replace),
  TS = time_now(),
  update_retract(LServer,LUser,Conversation,Version,Type,TS),
  ok;
handle_control_sub_el(headline, #groups_x{} = GroupX, From, To) ->
  case xmpp:get_subtag(GroupX, #forwarded{}) of
    #forwarded{sub_els = [Message]} ->
      MessageD = xmpp:decode(Message),
      %% Bad server or client may send an error message
      if
        MessageD#message.type == chat ->
          process_delivery_msg(MessageD, From, To);
        true -> ok
      end;
    _ -> ok
  end;
handle_control_sub_el(_Type, _SubEl, _From, _To) ->
  ok.

process_delivery_msg(MessageD, From, To) ->
  BarePeer = jid:remove_resource(From),
  case get_stanza_id(MessageD, BarePeer) of
    undefined ->
      ?ERROR_MSG("Bad delivery receipt. From ~p to ~p\n~p",
        [From, To, MessageD]);
    StanzaID ->
      {PUser, PServer, _} = jid:tolower(From),
      {LUser,LServer,_} = jid:tolower(To),
      Conversation = jid:to_string(BarePeer),
      MsgTS = case is_local(PServer) of
                false ->
                  Time = get_unique_time(MessageD, BarePeer),
                  store_external_group_message(
                    LServer, {PUser, PServer}, StanzaID,
                    xmpp:set_from(MessageD, From), Time),
                  Time;
                _ ->
                  StanzaID
              end,
      update_metainfo(read_delivered, LServer, LUser, Conversation,
        StanzaID, ?NS_GROUPS, MsgTS)
  end.

%%%===================================================================
%%% Handle call messages
%%%===================================================================
handle_call_message(Direction, #message{type = chat,
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
      handled;
    Propose ->
      %% Direction is out
      handled;
    Accept /= false ->
      maybe_push_notification(LUser,LServer,<<"data">>,Accept),
      update_metainfo(call, LServer,LUser,Conversation,
        StanzaID,?NS_XABBER_CHAT, StanzaID),
      delete_last_call(Peer, LUser, LServer),
      handled;
    Reject /= false ->
      maybe_push_notification(LUser,LServer,<<"data">>,Reject),
      update_metainfo(call, LServer,LUser,Conversation,
        StanzaID,?NS_XABBER_CHAT, StanzaID),
      delete_last_call(Peer, LUser, LServer),
      handled;
    true ->
      pass
  end;
handle_call_message(_, _) ->
  pass.

%%%===================================================================
%%% Internal functions
%%%===================================================================

make_sql_query(LServer, User, 0, RSM, Form)->
  make_sql_query(LServer, User, <<"0">>, RSM, Form);
make_sql_query(LServer, User, TS, RSM, _Form) ->
  {Max, Direction, Chat} = get_max_direction_chat(RSM),
  ODBCType = ejabberd_config:get_option({sql_type, LServer}),
  ToString = fun(S) -> ejabberd_sql:to_string_literal(ODBCType, S) end,
  SServer = ToString(LServer),
  SUser = ToString(User),
  Timestamp = ToString(TS),
%%  Pinned =  proplists:get_value(filter_pinned, Form),
%%  PinnedFirst = proplists:get_value(pinned_first, Form),
%%  Archived = proplists:get_value(filter_archived, Form),
  DeleteClause = case TS of
                   <<"0">> -> [<<"and status != 'deleted' ">>];
                   _ -> []
                 end,
%%  PinnedClause = case Pinned of
%%                   false ->
%%                     [<<"and pinned is null ">>];
%%                   true ->
%%                     [<<"and pinned >= 0 ">>];
%%                   _ ->
%%                     []
%%                 end,
%%  ArchivedClause = case Archived of
%%                     false ->
%%                       [<<"and status != 'archived' ">>];
%%                     true ->
%%                       [<<"and status = 'archived' ">>];
%%                     _ ->
%%                       []
%%                   end,
%%  PinnedFirstClause = case PinnedFirst of
%%                        false ->
%%                          [];
%%                        true ->
%%                          [<<" pinned desc ">>];
%%                        _ ->
%%                          []
%%                      end,
  PinnedClause = [],
  ArchivedClause =[],
  PinnedFirstClause = [<<" pinned desc, ">>],
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
  mute
  from conversation_metadata where username = ">>,SUser,<<" and
  metadata_updated_at > ">>,Timestamp] ++ DeleteClause,
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
              [Conversations,<<" and server_host=">>,
                SServer, <<" ">>,PageClause, PinnedClause, ArchivedClause];
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
      {QueryPage,[<<"SELECT COUNT(*) FROM (">>,Conversations,<<" and server_host=">>,
        SServer, <<" ">>,
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

change_conversation(LUser, LServer, Conversation) ->
  #sync_conversation{status = Status, pinned = Pinned,
    mute = Mute} = Conversation,
  case {Status, Pinned, Mute} of
    {undefined, undefined, undefined} ->
      {error, xmpp:err_bad_request()};
    {Status, undefined, undefined} ->
      change_conversation_status(Status, LServer, LUser, Conversation);
    {undefined, _Binary, undefined} ->
      pin_conversation(LServer, LUser, Conversation);
    {undefined, undefined, _Binary} ->
      mute_conversation(LServer, LUser, Conversation);
    _ ->
      {error, xmpp:err_bad_request()}
  end.

pin_conversation(LServer, LUser, #sync_conversation{type = Type,
  jid = ConvJID, thread = Thread, pinned = Pinned}) ->
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

mute_conversation(LServer, LUser, #sync_conversation{type = Type,
  jid = ConvJID, thread = Thread, mute = Mute}) ->
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

change_conversation_status(active, LServer, LUser, Conversation) ->
  activate_conversation(LServer, LUser, Conversation);
change_conversation_status(archived, LServer, LUser, Conversation) ->
  archive_conversation(LServer, LUser, Conversation);
change_conversation_status(deleted, LServer, LUser, Conversation) ->
  deactivate_conversation(LServer, LUser, Conversation);
change_conversation_status(_, _, _, _) ->
  {error, xmpp:err_bad_request()}.

archive_conversation(LServer, LUser,
    #sync_conversation{type = Type, jid = ConvJID, thread = Thread}) ->
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

activate_conversation(LServer, LUser, #sync_conversation{type = Type,
  jid = ConvJID, thread = Thread}) ->
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
deactivate_conversation(LServer,LUser,#sync_conversation{type = Type, jid = JID}) ->
  Conversation = jid:to_string(jid:remove_resource(JID)),
  TS = time_now(),
  case Type of
    ?NS_GROUPS ->
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
      maybe_delete_unused_external_group_cache(LServer, Type, Conversation),
      make_sync_push(LServer,LUser,Conversation,TS,Type,false),
      ok;
    _ ->
      {error,xmpp:err_internal_server_error()}
  end;
deactivate_conversation(_,_,_) ->
  {error,xmpp:err_bad_request()}.

%% Delete all user conversations
delete_conversations(LUser, LServer) ->
  ExternalGroups = get_user_external_group_conversations(LServer, LUser),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from conversation_metadata "
    " where username = %(LUser)s and %(LServer)H")),
  lists:foreach(
    fun(Conversation) ->
      maybe_delete_unused_external_group_cache(LServer, ?NS_GROUPS, Conversation)
    end, ExternalGroups),
  ok.

get_user_external_group_conversations(LServer, LUser) ->
  Type = ?NS_GROUPS,
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(conversation)s from conversation_metadata "
    "where username = %(LUser)s and type = %(Type)s "
    "and status != 'deleted' and %(LServer)H")) of
    {selected, Rows} ->
      lists:usort([Conversation || {Conversation} <- Rows]);
    _ ->
      []
  end.

maybe_delete_unused_external_group_cache(LServer, ?NS_GROUPS, Conversation) ->
  {GUser, GServer, _} = jid:tolower(jid:from_string(Conversation)),
  case is_local(GServer) of
    true ->
      ok;
    false ->
      send_cast(
        LServer,
        {external_group, cleanup_cache, Conversation, {GUser, GServer}})
  end;
maybe_delete_unused_external_group_cache(_, _, _) ->
  ok.

is_muted(LUser, LServer, Conversation) ->
  Now = erlang:system_time(second),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @('true')b from conversation_metadata "
    " where username = %(LUser)s and conversation = %(Conversation)s "
    " and status != 'deleted' and mute > %(Now)d and %(LServer)H")) of
    {selected,[_|_]} -> true;
    _ -> false
  end.

is_muted(LUser,LServer, Conversation, not_encrypted) ->
  is_muted(LUser, LServer, Conversation);
is_muted(LUser,LServer, Conversation, Type) ->
  Now = erlang:system_time(second),
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

%%send_push_about_retract(LServer,LUser,Conversation,PushPayload,RetractType,TS) ->
%%  CType = case RetractType of
%%            <<>> ->
%%              case get_conversation_type(LServer,LUser,Conversation) of
%%                [T] -> T;
%%                _-> ?NS_XABBER_CHAT
%%              end;
%%            _ -> RetractType
%%          end,
%%  make_sync_push(LServer,LUser,Conversation, TS, CType),
%%  maybe_push_notification(LUser,LServer,Conversation,CType,
%%    <<"update">>,xmpp:decode(PushPayload)).

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
    MatchHead = #sync_data{us_peer = '$1', _ = '_'},
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
    [?NS_GROUPS] ->
      delete_invite(LUser,LServer,PUser,PServer),
      deactivate_conversation(LServer,LUser,
        #sync_conversation{jid = jid:make(PUser,PServer),
          type = ?NS_GROUPS});
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

make_sync_push(LServer,LUser,Conversation, TS, ?NS_GROUPS) ->
  make_sync_push(LServer,LUser,Conversation, TS, ?NS_GROUPS, false);
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
                           type = subscribe},
                         SubEls = [P | xmpp_codec:get_els(CnElem)],
                         xmpp_codec:set_els(CnElem, SubEls);
                       _ -> CnElem
                     end;
                   true -> CnElem
                 end,
      UserResources = ejabberd_sm:get_user_present_resources(LUser,LServer),
      Query = #sync_query{stamp = integer_to_binary(TS), sub_els = [CnElem1]},
      lists:foreach(fun({_, Res}) ->
        From = jid:make(LUser,LServer),
        To = jid:make(LUser,LServer,Res),
        IQ = #iq{from = From, to = To, type = set, id = randoms:get_string(), sub_els = [Query]},
        ejabberd_router:route(IQ)
                    end, UserResources)
  end.

create_conversation(LServer, LUser, Conversation,
    Thread, Encrypted, Type) ->
  Options = [{type, Type}, {thread, Thread}, {encrypted, Encrypted}],
  F = fun() ->
    conversation_sql_upsert(LServer, LUser, Conversation , Options)
      end,
  ejabberd_sql:sql_transaction(LServer, F),
  case Type of
    ?NS_GROUPS ->
      GroupJID = jid:from_string(Conversation),
      update_mam_prefs(add,jid:make(LUser,LServer),GroupJID),
      {GUser, GServer, _} = jid:tolower(GroupJID),
      %% Set "read_until" for correct unread count.
      {LastMsgID, TS} = case get_group_last_message_id_ts(LServer, GUser, GServer) of
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
  Status = proplists:get_value('status', Options, <<"active">>),
  Read = proplists:get_value(read, Options, 0),
  TS = time_now(),
  case proplists:is_defined(read, Options) of
    true ->
      conversation_sql_upsert(LServer, LUser, Conversation,
        Type, Thread, Encrypted, Status, Read, TS);
    false ->
      conversation_sql_upsert_keep_read(LServer, LUser, Conversation,
        Type, Thread, Encrypted, Status, Read, TS)
  end.

conversation_sql_upsert(LServer, LUser, Conversation,
    Type, Thread, Encrypted, Status, Read, TS) ->
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
      "encrypted=%(Encrypted)b",
      "server_host=%(LServer)s"]).

conversation_sql_upsert_keep_read(LServer, LUser, Conversation,
    Type, Thread, Encrypted, Status, Read, TS) ->
  ?SQL_UPSERT_T(
    "conversation_metadata",
    ["!username=%(LUser)s",
      "!conversation=%(Conversation)s",
      "!type=%(Type)s",
      "updated_at=%(TS)d",
      "-read_until = %(Read)s",
      "-read_until_ts = %(Read)d",
      "conversation_thread=%(Thread)s",
      "metadata_updated_at=%(TS)d",
      "status=%(Status)s",
      "encrypted=%(Encrypted)b",
      "server_host=%(LServer)s"]).

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
          #delivery_time{by = By} ->
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
  erlang:system_time(microsecond).

send_cast(LServer, Message) ->
  Proc = gen_mod:get_module_proc(LServer, ?MODULE),
  gen_server:cast(Proc, Message).

is_local(Host) ->
  lists:member(Host,ejabberd_config:get_myhosts()).
