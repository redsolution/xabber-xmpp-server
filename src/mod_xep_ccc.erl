%%%-------------------------------------------------------------------
%%% File    : mod_xep_ccc.erl
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

-module(mod_xep_ccc).
-author('andrey.gagarin@redsolution.com').

-behaviour(gen_mod).
-behavior(gen_server).
-compile([{parse_transform, ejabberd_sql_pt}]).

-protocol({xep, '0CCC', '0.9.0'}).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").

-export([is_archived/5,is_pinned/5]).
%% gen_mod callbacks.
-export([start/2,stop/1,reload/3,depends/2,mod_options/1]).

%% gen_server callbacks.
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

%% hooks
-export([c2s_stream_features/2, sm_receive_packet/1, user_send_packet/1, groupchat_send_message/3, groupchat_got_displayed/3]).

%% iq
-export([process_iq/1]).

%%
-export([get_count/4, delete_msg/5, get_last_message/4, get_last_messages/4,get_actual_last_call/4,get_last_call/4]).

%%
-export([get_last_message/3, get_count_messages/4, get_last_groupchat_message/4, get_last_previous_message/4]).

%%
-export([get_stanza_id/2, check_user_for_sync/5, try_to_sync/5, make_responce_to_sync/5, iq_result_from_remote_server/1]).
-export([get_last_sync/4, get_stanza_id_from_counter/5, get_last_card/4]).

% syncronization_query hook
-export([create_synchronization_metadata/11, check_conversation_type/11, get_invite_information/4]).
-type c2s_state() :: ejabberd_c2s:state().
%% records
-record(state, {host = <<"">> :: binary()}).

-record(invite_msg,
{
  us = {<<"">>, <<"">>}                :: {binary(), binary()} | '_',
  bare_peer = {<<"">>, <<"">>, <<"">>} :: ljid() | '_'
}
).

-record(user_card,
{
  us = {<<"">>, <<"">>}                :: {binary(), binary()} | '_',
  bare_peer = {<<"">>, <<"">>, <<"">>} :: ljid() | '_',
  packet = #xmlel{}                    :: xmlel() | message() | '_'
}
).

-record(last_msg,
{
  us = {<<"">>, <<"">>}                :: {binary(), binary()} | '_',
  bare_peer = {<<"">>, <<"">>, <<"">>} :: ljid() | '_',
  id = <<>>                            :: binary() | '_',
  user_id = <<>>                       :: binary() | '_',
  packet = #xmlel{}                    :: xmlel() | message() | '_'
}
).

-record(last_sync,
{
  us = {<<"">>, <<"">>}                :: {binary(), binary()} | '_',
  bare_peer = {<<"">>, <<"">>, <<"">>} :: ljid() | '_',
  packet = #xmlel{}                    :: xmlel() | '_',
  id = <<>>                            :: binary() | '_'
}
).

-record(last_call,
{
  us = {<<"">>, <<"">>}                :: {binary(), binary()} | '_',
  bare_peer = {<<"">>, <<"">>, <<"">>} :: ljid() | '_',
  id = <<>>                            :: binary() | '_',
  packet = #xmlel{}                    :: xmlel() | message() | '_'
}
).

-record(unread_msg_counter,
{
  us = {<<"">>, <<"">>}                :: {binary(), binary()} | '_',
  bare_peer = {<<"">>, <<"">>, <<"">>} :: ljid() | '_',
  type = <<>>                          :: binary() | '_',
  user_id = <<>>                       :: binary() | '_',
  origin_id = <<>>                     :: binary() | '_',
  id = <<>>                            :: binary() | '_'
}).

-record(request_job,
{
  server_id = <<>>                       :: binary() | '_',
  cs = {<<>>, <<>>}                      :: {binary(), binary()} | '_',
  usr = {<<>>, <<>>, <<>>}               :: {binary(), binary(), binary()} | '_'
}).

-define(TABLE_SIZE_LIMIT, 2000000000). % A bit less than 2 GiB.
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
  ejabberd_mnesia:create(?MODULE, user_card,
    [{disc_only_copies, [node()]},
      {type, bag},
      {attributes, record_info(fields, user_card)}]),
  ejabberd_mnesia:create(?MODULE, request_job,
    [{disc_only_copies, [node()]},
      {attributes, record_info(fields, request_job)}]),
  ejabberd_mnesia:create(?MODULE, last_msg,
    [{disc_only_copies, [node()]},
      {type, bag},
      {attributes, record_info(fields, last_msg)}]),
  ejabberd_mnesia:create(?MODULE, last_sync,
    [{disc_only_copies, [node()]},
      {type, bag},
      {attributes, record_info(fields, last_sync)}]),
  ejabberd_mnesia:create(?MODULE, last_call,
    [{disc_only_copies, [node()]},
      {type, bag},
      {attributes, record_info(fields, last_call)}]),
  ejabberd_mnesia:create(?MODULE, unread_msg_counter,
    [{disc_only_copies, [node()]},
      {type, bag},
      {attributes, record_info(fields, unread_msg_counter)}]),
  ejabberd_mnesia:create(?MODULE, invite_msg,
    [{disc_only_copies, [node()]},
      {type, bag},
      {attributes, record_info(fields, invite_msg)}]),
  register_iq_handlers(Host),
  register_hooks(Host),
  {ok, #state{host = Host}}.

terminate(_Reason, State) ->
  Host = State#state.host,
  unregister_hooks(Host),
  unregister_iq_handlers(Host).

handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast({request,User,Chat}, State) ->
  {LUser,LServer,LResource} = jid:tolower(User),
  From = jid:remove_resource(User),
  {PUser,PServer,_R} = jid:tolower(Chat),
  NewID = randoms:get_alphanum_string(32),
  NewIQ = #iq{type = get, id = NewID, from = From, to = Chat, sub_els = [#xabber_synchronization_query{stamp = <<"0">>}]},
  set_request_job(NewID,{LUser,LServer,LResource},{PUser,PServer}),
  ejabberd_router:route(NewIQ),
  {noreply, State};
handle_cast({user_send, #iq{from = #jid{luser = LUser, lserver = LServer}, to = #jid{luser = PUser, lserver = PServer}} = IQ}, State) ->
  Decline = xmpp:get_subtag(IQ,#xabbergroup_decline{}),
  case Decline of
    false ->
      ok;
    _ ->
      maybe_delete_invite_and_conversation(LUser,LServer,PUser,PServer)
  end,
  {noreply, State};
handle_cast({user_send, #presence{type = Type, from = #jid{luser = LUser, lserver = LServer},
  to = #jid{luser = PUser, lserver = PServer}}}, State) when Type == subscribe orelse Type == subscribed  ->
  delete_old_invites(LUser,LServer,PUser,PServer),
  {noreply, State};
handle_cast({user_send, #presence{type = Type, from = #jid{luser = LUser, lserver = LServer},
  to = #jid{luser = PUser, lserver = PServer}}}, State) when Type == unsubscribe orelse Type == unsubscribed  ->
  maybe_delete_invite_and_conversation(LUser,LServer,PUser,PServer),
  {noreply, State};
handle_cast({user_send,#message{id = ID, type = chat, from = #jid{luser =  LUser,lserver = LServer}, to = #jid{lserver = PServer, luser = PUser} = To, meta = #{stanza_id := TS, mam_archived := true}} = Pkt}, State) ->
  Invite = xmpp:get_subtag(Pkt, #xabbergroupchat_invite{}),
  Accept = xmpp:get_subtag(Pkt, #jingle_accept{}),
  Reject = xmpp:get_subtag(Pkt, #jingle_reject{}),
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  case Accept of
    #jingle_accept{} ->
      delete_last_call(To, LUser, LServer);
    _ ->
      ok
  end,
  case Reject of
    #jingle_reject{} ->
      store_special_message_id(LServer,LUser,Conversation,TS,ID,<<"reject">>),
      delete_last_call(To, LUser, LServer);
    _ ->
      ok
  end,
  case Invite of
    false ->
      Encrypted = xmpp:get_subtag(Pkt,#encrypted_message{}),
      case Encrypted of
        #encrypted_message{} ->
          create_conversation(LServer,LUser,Conversation,<<"">>,true),
          update_metainfo(read, LServer,LUser,Conversation,TS,true);
        _ ->
          update_metainfo(message, LServer,LUser,Conversation,TS,false),
          ejabberd_hooks:run(xabber_push_notification, LServer, [<<"outgoing">>, LUser, LServer,
            #stanza_id{id = integer_to_binary(TS), by = jid:make(LServer)}]),
          update_metainfo(read, LServer,LUser,Conversation,TS,false)
      end;
    _ ->
      ejabberd_hooks:run(xabber_push_notification, LServer, [<<"outgoing">>, LUser, LServer,
        #stanza_id{id = integer_to_binary(TS), by = jid:make(LServer)}]),
      store_special_message_id(LServer,LUser,Conversation,TS,ID,<<"invite">>),
      update_metainfo(message, LServer,LUser,Conversation,TS),
      update_metainfo(read, LServer,LUser,Conversation,TS)
  end,
  {noreply, State};
handle_cast({user_send,#message{type = chat, from = #jid{luser =  LUser,lserver = LServer}, to = #jid{luser =  PUser,lserver = PServer}} = Pkt}, State) ->
  Displayed = xmpp:get_subtag(Pkt, #message_displayed{}),
  IsLocal = lists:member(PServer,ejabberd_config:get_myhosts()),
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  Type = get_conversation_type(LServer,LUser,Conversation),
  case Displayed of
    #message_displayed{id = OriginID} when IsLocal == false andalso Type == <<"groupchat">> ->
      StanzaID = get_stanza_id_of_chat(Displayed,LUser,LServer,PUser,PServer,OriginID),
      update_metainfo(read, LServer,LUser,Conversation,StanzaID),
      ejabberd_hooks:run(xabber_push_notification, LServer, [<<"displayed">>, LUser, LServer, Displayed]),
      delete_msg(LUser, LServer, PUser, PServer, StanzaID);
    #message_displayed{id = OriginID} ->
      BareJID = jid:make(LUser,LServer),
      Displayed2 = filter_packet(Displayed,BareJID),
      StanzaID = get_stanza_id(Displayed2,BareJID,LServer,OriginID),
      IsEncrypted = mod_mam_sql:is_encrypted(LServer,StanzaID),
      case IsEncrypted of
        true ->
          update_metainfo(read, LServer,LUser,Conversation,StanzaID,true);
        _ ->
          update_metainfo(read, LServer,LUser,Conversation,StanzaID,false)
      end,
      ejabberd_hooks:run(xabber_push_notification, LServer, [<<"displayed">>, LUser, LServer, Displayed]);
    _ ->
      ok
  end,
  {noreply, State};
handle_cast({sm, #presence{type = available,from = #jid{lserver = PServer, luser = PUser}, to = #jid{lserver = LServer, luser = LUser}} = Presence},State) ->
  PktNew = xmpp:decode_els(Presence),
  IsChat = xmpp:get_subtag(PktNew, #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT}),
  XEl = xmpp:get_subtag(PktNew, #xabbergroupchat_x{}),
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  case IsChat of
    #xabbergroupchat_x{} ->
      update_metainfo(<<"groupchat">>, LServer,LUser,Conversation,IsChat);
    _ when XEl =/= false ->
      update_metainfo(<<"groupchat">>, LServer,LUser,Conversation,XEl);
    _ ->
      update_metainfo(<<"chat">>, LServer,LUser,Conversation,<<>>)
  end,
  {noreply, State};
handle_cast({sm, #presence{type = subscribe,from = From, to = #jid{lserver = LServer, luser = LUser}}},State) ->
  ejabberd_hooks:run(xabber_push_notification, LServer, [<<"subscribe">>, LUser, LServer, #presence{type = subscribe, from = From}]),
  Conversation = jid:to_string(jid:remove_resource(From)),
  create_conversation(LServer,LUser,Conversation,<<"">>,false),
  {noreply, State};
handle_cast({sm, #presence{type = unsubscribe,from = #jid{lserver = PServer, luser = PUser}, to = #jid{lserver = LServer, luser = LUser}}},State) ->
  maybe_delete_invite_and_conversation(LUser,LServer,PUser,PServer),
  {noreply, State};
handle_cast({sm, #presence{type = unsubscribed,from = #jid{lserver = PServer, luser = PUser}, to = #jid{lserver = LServer, luser = LUser}}},State) ->
  maybe_delete_invite_and_conversation(LUser,LServer,PUser,PServer),
  {noreply, State};
handle_cast({sm,#message{id = ID, type = chat, body = [], from = From, to = To, sub_els = SubEls, meta = #{stanza_id := TS}} = Pkt}, State) ->
  Propose = xmpp:get_subtag(Pkt, #jingle_propose{}),
  Accept = xmpp:get_subtag(Pkt, #jingle_accept{}),
  Reject = xmpp:get_subtag(Pkt, #jingle_reject{}),
  {LUser, LServer, _ } = jid:tolower(To),
  Conversation = jid:to_string(jid:remove_resource(From)),
  case Propose of
    #jingle_propose{} ->
      ejabberd_hooks:run(xabber_push_notification, LServer, [<<"call">>, LUser, LServer, Propose]),
      store_special_message_id(LServer,LUser,Conversation,TS,ID,<<"call">>),
      store_last_call(Pkt, From, LUser, LServer, TS);
    _ ->
      ok
  end,
  case Accept of
    #jingle_accept{} ->
      store_special_message_id(LServer,LUser,Conversation,TS,ID,<<"accept">>),
      delete_last_call(From, LUser, LServer);
    _ ->
      ok
  end,
  case Reject of
    #jingle_reject{} ->
      store_special_message_id(LServer,LUser,Conversation,TS,ID,<<"reject">>),
      delete_last_call(From, LUser, LServer);
    _ ->
      ok
  end,
  DecSubEls = lists:map(fun(El) -> xmpp:decode(El) end, SubEls),
  handle_sub_els(chat,DecSubEls,From,To),
  {noreply, State};
handle_cast({sm,#message{type = chat, body = [], from = From, to = To, sub_els = SubEls}}, State) ->
  DecSubEls = lists:map(fun(El) -> xmpp:decode(El) end, SubEls),
  handle_sub_els(chat,DecSubEls,From,To),
  {noreply, State};
handle_cast({sm,#message{id = ID, type = chat, from = Peer, to = To, meta = #{stanza_id := TS}} = Pkt}, State) ->
  {LUser, LServer, _ } = jid:tolower(To),
  {PUser, PServer, _} = jid:tolower(Peer),
  PktRefGrp = filter_reference(Pkt,<<"groupchat">>),
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  Type = get_conversation_type(LServer,LUser,Conversation),
  Invite = xmpp:get_subtag(PktRefGrp, #xabbergroupchat_invite{}),
  X = xmpp:get_subtag(Pkt, #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE}),
  OriginIDElemnt = xmpp:get_subtag(Pkt, #origin_id{}),
  OriginID = get_origin_id(OriginIDElemnt),
  IsLocal = lists:member(PServer,ejabberd_config:get_myhosts()),
  case Type of
    _ when Invite =/= false ->
      #xabbergroupchat_invite{jid = ChatJID} = Invite,
      case ChatJID of
        undefined ->
          store_special_message_id(LServer,LUser,Conversation,TS,OriginID,<<"invite">>),
          store_invite_information(LUser,LServer,PUser,PServer),
          ejabberd_hooks:run(xabber_push_notification, LServer, [<<"message">>, LUser, LServer,
            #stanza_id{id = integer_to_binary(TS), by = jid:make(LServer)}]),
          update_metadata(invite,<<"groupchat">>, LServer,LUser,Conversation);
        _ ->
          Chat = jid:to_string(jid:remove_resource(ChatJID)),
          store_special_message_id(LServer,LUser,Chat,TS,OriginID,<<"invite">>),
          ejabberd_hooks:run(xabber_push_notification, LServer, [<<"message">>, LUser, LServer,
            #stanza_id{id = integer_to_binary(TS), by = jid:make(LServer)}]),
          store_invite_information(LUser,LServer,ChatJID#jid.luser,ChatJID#jid.lserver),
          update_metadata(invite,<<"groupchat">>, LServer,LUser,Chat)
      end;
    _ when X =/= false andalso IsLocal == true ->
      FilPacket = filter_packet(Pkt,jid:remove_resource(Peer)),
      StanzaID = xmpp:get_subtag(FilPacket, #stanza_id{}),
      case StanzaID of
        false ->
          ok;
        _ ->
          TSGroupchat = StanzaID#stanza_id.id,
          store_special_message_id(LServer,LUser,Conversation,binary_to_integer(TSGroupchat),OriginID,<<"service">>),
          update_metainfo(message, LServer,LUser,Conversation,TS)
      end;
    _ when X =/= false andalso IsLocal == false ->
      FilPacket = filter_packet(Pkt,jid:remove_resource(Peer)),
      StanzaID = xmpp:get_subtag(FilPacket, #stanza_id{}),
      TSGroupchat = StanzaID#stanza_id.id,
      store_last_msg(Pkt, Peer, LUser, LServer,TSGroupchat, OriginID),
      ejabberd_hooks:run(xabber_push_notification, LServer, [<<"message">>, LUser, LServer,
        #stanza_id{id = integer_to_binary(TS), by = jid:make(LServer)}]),
      update_metainfo(message, LServer,LUser,Conversation,TS);
    <<"groupchat">> when IsLocal == false ->
      FilPacket = filter_packet(Pkt,jid:remove_resource(Peer)),
      StanzaID = xmpp:get_subtag(FilPacket, #stanza_id{}),
      TSGroupchat = StanzaID#stanza_id.id,
      store_last_msg(Pkt, Peer, LUser, LServer,TSGroupchat, OriginID),
      ejabberd_hooks:run(xabber_push_notification, LServer, [<<"message">>, LUser, LServer,
        #stanza_id{id = integer_to_binary(TS), by = jid:make(LServer)}]),
      update_metainfo(message, LServer,LUser,Conversation,binary_to_integer(TSGroupchat));
    <<"groupchat">> ->
      ejabberd_hooks:run(xabber_push_notification, LServer, [<<"message">>, LUser, LServer,
        #stanza_id{id = integer_to_binary(TS), by = jid:make(LServer)}]),
      update_metainfo(message, LServer,LUser,Conversation,TS);
    _ ->
      Propose = xmpp:get_subtag(Pkt, #jingle_propose{}),
      Accept = xmpp:get_subtag(Pkt, #jingle_accept{}),
      Reject = xmpp:get_subtag(Pkt, #jingle_reject{}),
      case Propose of
        #jingle_propose{} ->
          ejabberd_hooks:run(xabber_push_notification, LServer, [<<"call">>, LUser, LServer, Propose]),
          store_special_message_id(LServer,LUser,Conversation,TS,ID,<<"call">>),
          store_last_call(Pkt, Peer, LUser, LServer, TS);
        _ ->
          ok
      end,
      case Accept of
        #jingle_accept{} ->
          store_special_message_id(LServer,LUser,Conversation,TS,ID,<<"accept">>),
          delete_last_call(Peer, LUser, LServer);
        _ ->
          ok
      end,
      case Reject of
        #jingle_reject{} ->
          Conversation = jid:to_string(jid:remove_resource(Peer)),
          store_special_message_id(LServer,LUser,Conversation,TS,ID,<<"reject">>),
          delete_last_call(Peer, LUser, LServer);
        _ ->
          IsEncrypted = body_is_encrypted(Pkt),
          case IsEncrypted of
            true ->
              create_conversation(LServer,LUser,Conversation,<<"">>,true),
              update_metainfo(message, LServer,LUser,Conversation,TS,true);
            _ ->
              ejabberd_hooks:run(xabber_push_notification, LServer, [<<"message">>, LUser, LServer,
                #stanza_id{id = integer_to_binary(TS), by = jid:make(LServer)}]),
              update_metainfo(message, LServer,LUser,Conversation,TS,false)
          end
      end
  end,
  {noreply, State};
handle_cast({sm,#message{type = headline, body = [], from = From, to = To, sub_els = SubEls}}, State) ->
  DecSubEls = lists:map(fun(El) -> xmpp:decode(El) end, SubEls),
  handle_sub_els(headline,DecSubEls,From,To),
  {noreply, State};
handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%--------------------------------------------------------------------
%% Hooks handlers.
%%--------------------------------------------------------------------
register_hooks(Host) ->
  ejabberd_hooks:add(syncronization_query, Host, ?MODULE,
    check_conversation_type, 50),
  ejabberd_hooks:add(syncronization_query, Host, ?MODULE,
    create_synchronization_metadata, 60),
  ejabberd_hooks:add(iq_result_from_remote_server, Host, ?MODULE,
    iq_result_from_remote_server, 10),
  ejabberd_hooks:add(synchronization_event, Host, ?MODULE,
    get_last_ccc_state, 10),
  ejabberd_hooks:add(synchronization_event, Host, ?MODULE,
    make_responce_to_sync, 20),
  ejabberd_hooks:add(synchronization_request, Host, ?MODULE,
    check_user_for_sync, 10),
  ejabberd_hooks:add(synchronization_request, Host, ?MODULE,
    try_to_sync, 20),
  ejabberd_hooks:add(synchronization_request, Host, ?MODULE,
    make_responce_to_sync, 30),
  ejabberd_hooks:add(groupchat_send_message, Host, ?MODULE,
    groupchat_send_message, 10),
  ejabberd_hooks:add(groupchat_got_displayed, Host, ?MODULE,
    groupchat_got_displayed, 10),
  ejabberd_hooks:add(user_send_packet, Host, ?MODULE,
    user_send_packet, 101),
  ejabberd_hooks:add(sm_receive_packet, Host, ?MODULE,
    sm_receive_packet, 55),
  ejabberd_hooks:add(c2s_post_auth_features, Host, ?MODULE,
    c2s_stream_features, 50).

unregister_hooks(Host) ->
  ejabberd_hooks:delete(syncronization_query, Host, ?MODULE,
    check_conversation_type, 50),
  ejabberd_hooks:delete(syncronization_query, Host, ?MODULE,
    create_synchronization_metadata, 60),
  ejabberd_hooks:delete(iq_result_from_remote_server, Host, ?MODULE,
    iq_result_from_remote_server, 10),
  ejabberd_hooks:delete(synchronization_event, Host, ?MODULE,
    get_last_ccc_state, 10),
  ejabberd_hooks:delete(synchronization_event, Host, ?MODULE,
    make_responce_to_sync, 20),
  ejabberd_hooks:delete(synchronization_request, Host, ?MODULE,
    check_user_for_sync, 10),
  ejabberd_hooks:delete(synchronization_request, Host, ?MODULE,
    try_to_sync, 20),
  ejabberd_hooks:delete(synchronization_request, Host, ?MODULE,
    make_responce_to_sync, 30),
  ejabberd_hooks:delete(groupchat_send_message, Host, ?MODULE,
    groupchat_send_message, 10),
  ejabberd_hooks:delete(groupchat_got_displayed, Host, ?MODULE,
    groupchat_got_displayed, 10),
  ejabberd_hooks:delete(user_send_packet, Host, ?MODULE,
    user_send_packet, 101),
  ejabberd_hooks:delete(sm_receive_packet, Host, ?MODULE,
    sm_receive_packet, 55),
  ejabberd_hooks:delete(c2s_post_auth_features, Host, ?MODULE,
    c2s_stream_features, 50).

iq_result_from_remote_server(#iq{
  from = #jid{luser = ChatName, lserver = ChatServer},
  to = #jid{luser = LUser, lserver = LServer},
  type = result, id = ID} =IQ) ->
  case get_request_job(ID,{'_','_'},{'_','_','_'}) of
    [] ->
      ?DEBUG("Not our id ~p",[ID]);
    [#request_job{server_id = ID, usr = {LUser,LServer,_R}, cs = {ChatName,ChatServer}} = Job] ->
      Els = xmpp:get_els(IQ),
      Sync = case Els of
               [] ->
                 [];
               [F|_Rest] ->
                 F;
               _ ->
                 []
             end,
      SyncD = xmpp:decode(Sync),
      #xabber_synchronization{conversation = [Conv],stamp = Stamp} = SyncD,
      store_last_sync(Conv, ChatName, ChatServer, LUser,LServer, Stamp),
      delete_job(Job);
    _ ->
      ok
  end.

check_user_for_sync(_Acc,LServer,User,Chat,_Stamp) ->
  UserSubscription = mod_groupchat_users:check_user_if_exist(LServer,User,Chat),
  BlockToRead = mod_groupchat_restrictions:is_restricted(<<"read-messages">>,User,Chat),
  case UserSubscription of
    <<"both">> when BlockToRead == no ->
      ok;
    _ ->
      {stop,not_ok}
  end.

try_to_sync(_Acc,LServer,User,Chat,StampBinary) ->
  ChatJID = jid:from_string(Chat),
  Stamp = binary_to_integer(StampBinary),
  LUser = ChatJID#jid.luser,
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(conversation)s,
    @(retract)d,
    @(type)s,
    @(conversation_thread)s,
    @(read_until)s,
    @(delivered_until)s,
    @(displayed_until)s,
    @(updated_at)d
     from conversation_metadata"
    " where username=%(LUser)s and updated_at >= %(Stamp)d and conversation=%(User)s and %(LServer)H order by updated_at desc")) of
    {selected,[<<>>]} ->
      {stop,not_ok};
    {selected,[]} ->
      {stop,not_ok};
    {selected,[Sync]} ->
      Sync;
    _ ->
      {stop,not_ok}
  end.

make_responce_to_sync(Sync,_LServer,_User,Chat,_StampBinary) ->
  {_Conversation,_Retract,_T,Thread,_Read,_Delivered,_Display,UpdateAt} = Sync,
  {PUser, PServer,_} = jid:tolower(jid:from_string(Chat)),
  Chat = jid:to_string(jid:make(PUser,PServer)),
  Conv = #xabber_conversation{
    jid = jid:from_string(Chat),
    type = <<"groupchat">>,
    thread = Thread,
    stamp = integer_to_binary(UpdateAt)},
  Res = #xabber_synchronization{conversation = [Conv], stamp = integer_to_binary(UpdateAt)},
  {stop,{ok,Res}}.

c2s_stream_features(Acc, Host) ->
  case gen_mod:is_loaded(Host, ?MODULE) of
    true ->
      [#xabber_synchronization{}|Acc];
    false ->
      Acc
  end.

groupchat_send_message(From,ChatJID,Pkt) ->
  #jid{luser =  LUser,lserver = LServer} = ChatJID,
  #jid{lserver = PServer, luser = PUser} = From,
  #message{meta = #{stanza_id := TS, mam_archived := true}} = Pkt,
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  update_metainfo(read, LServer,LUser,Conversation,TS).

groupchat_got_displayed(From,ChatJID,TS) ->
  #jid{luser =  LUser,lserver = LServer} = ChatJID,
  #jid{lserver = PServer, luser = PUser} = From,
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  update_metainfo(read, LServer,LUser,Conversation,TS).

-spec sm_receive_packet(stanza()) -> stanza().
sm_receive_packet(#message{to = #jid{lserver = LServer}} = Pkt) ->
  Proc = gen_mod:get_module_proc(LServer, ?MODULE),
  gen_server:cast(Proc, {sm,Pkt}),
  Pkt;
sm_receive_packet(#presence{to = #jid{lserver = LServer}} = Pkt) ->
  Proc = gen_mod:get_module_proc(LServer, ?MODULE),
  gen_server:cast(Proc, {sm,Pkt}),
  Pkt;
sm_receive_packet(Acc) ->
  Acc.

-spec user_send_packet({stanza(), c2s_state()})
      -> {stanza(), c2s_state()}.
user_send_packet({#message{} = Pkt, #{lserver := LServer}} = Acc) ->
  Proc = gen_mod:get_module_proc(LServer, ?MODULE),
  gen_server:cast(Proc, {user_send,Pkt}),
  Acc;
user_send_packet({#presence{} = Pkt, #{lserver := LServer}} = Acc) ->
  Proc = gen_mod:get_module_proc(LServer, ?MODULE),
  gen_server:cast(Proc, {user_send,Pkt}),
  Acc;
user_send_packet({#iq{type = set} = Pkt, #{lserver := LServer}} = Acc) ->
  Proc = gen_mod:get_module_proc(LServer, ?MODULE),
  gen_server:cast(Proc, {user_send,Pkt}),
  Acc;
user_send_packet(Acc) ->
  Acc.

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

process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = get, sub_els = [#xabber_synchronization_query{stamp = undefined, rsm = undefined}  = Query], lang = Lang} = IQ) ->
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
process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = get, sub_els = [#xabber_synchronization_query{stamp = <<>>, rsm = undefined} = Query], lang = Lang} = IQ) ->
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
process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = get, sub_els = [#xabber_synchronization_query{stamp = Stamp, rsm = undefined}  = Query], lang = Lang} = IQ) ->
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
process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = get, sub_els = [#xabber_synchronization_query{stamp = undefined, rsm = RSM} = Query], lang = Lang} = IQ) ->
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
process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = get, sub_els = [#xabber_synchronization_query{stamp = <<>>, rsm = RSM} = Query], lang = Lang} = IQ) ->
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
process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = get, sub_els = [#xabber_synchronization_query{stamp = Stamp, rsm = RSM} = Query], lang = Lang} = IQ) ->
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
process_iq(#iq{from = UserJID, type = set, sub_els = [#xabber_delete{conversation = Conversations}]} = IQ ) ->
  case delete_conversations(UserJID,Conversations) of
    ok ->
      xmpp:make_iq_result(IQ);
    _ ->
      xmpp:make_error(IQ, xmpp:err_bad_request())
  end;
process_iq(#iq{lang = Lang, from = UserJID, type = set, sub_els = [#xabber_synchronization_pin{conversation = Conversation}]} = IQ ) ->
  case pin_conversation(UserJID, Conversation, Lang) of
    ok ->
      xmpp:make_iq_result(IQ);
    {error,Err} ->
      xmpp:make_error(IQ,Err);
    _ ->
      xmpp:make_error(IQ, xmpp:err_internal_server_error())
  end;
process_iq(#iq{lang = Lang, from = UserJID, type = set, sub_els = [#xabber_synchronization_archive{conversation = Conversation}]} = IQ ) ->
  case archive_conversation(UserJID, Conversation, Lang) of
    ok ->
      xmpp:make_iq_result(IQ);
    {error,Err} ->
      xmpp:make_error(IQ,Err);
    _ ->
      xmpp:make_error(IQ, xmpp:err_internal_server_error())
  end;
process_iq(#iq{lang = Lang, from = UserJID, type = set, sub_els = [#xabber_synchronization_unarchive{conversation = Conversation}]} = IQ ) ->
  case unarchive_conversation(UserJID, Conversation, Lang) of
    ok ->
      xmpp:make_iq_result(IQ);
    {error,Err} ->
      xmpp:make_error(IQ,Err);
    _ ->
      xmpp:make_error(IQ, xmpp:err_internal_server_error())
  end;
process_iq(#iq{lang = Lang, from = UserJID, type = set, sub_els = [#xabber_synchronization_unpin{conversation = Conversation}]} = IQ ) ->
  case unpin_conversation(UserJID, Conversation, Lang) of
    ok ->
      xmpp:make_iq_result(IQ);
    {error,Err} ->
      xmpp:make_error(IQ,Err);
    _ ->
      xmpp:make_error(IQ, xmpp:err_internal_server_error())
  end;
process_iq(IQ) ->
  xmpp:make_error(IQ, xmpp:err_bad_request()).

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
parse_query(#mam_query{}, _Lang) ->
  {ok, []}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

make_result(LServer, LUser, Stamp, RSM, Form) ->
  {QueryChats, QueryCount} = make_sql_query(LServer, LUser, Stamp, RSM, Form),
  {selected, _, Res} = ejabberd_sql:sql_query(LServer, QueryChats),
  {selected, _, [[CountBinary]]} = ejabberd_sql:sql_query(LServer, QueryCount),
  Count = binary_to_integer(CountBinary),
  ConvRes = convert_result(Res),
  ReplacedConv = lists:map(fun(El) ->
    make_result_el(LServer, LUser, El)
                   end, ConvRes
  ),
%%  ReplacedConv = replace_invites(LServer, LUser, Conv),
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
  #xabber_synchronization{conversation = ReplacedConv, stamp = LastStamp, rsm = ResRSM}.

convert_result(Result) ->
  lists:map(fun(El) ->
    [Conversation,Retract,Type,Thread,Read,Delivered,Display,UpdateAt,Status,Encrypted,Incognito,P2P] = El,
    {Conversation,binary_to_integer(Retract),Type,Thread,Read,Delivered,Display,binary_to_integer(UpdateAt),Status, to_atom_t_f(Encrypted), to_atom_t_f(Incognito), to_atom_t_f(P2P)} end, Result
  ).

to_atom_t_f(Binary) ->
  case Binary of
    <<"t">> ->
      true;
    _ ->
      false
  end.

make_result_el(LServer, LUser, El) ->
  {Conversation,Retract,Type,Thread,Read,Delivered,Display,UpdateAt,ConversationStatus,Encrypted,Incognito,P2P} = El,
  ConversationMetadata = ejabberd_hooks:run_fold(syncronization_query,
    LServer, [], [LUser,LServer,Conversation,Read,Delivered,Display,ConversationStatus,Retract,Type,Encrypted]),
  ConversationType = define_type(Type,Encrypted,Incognito,P2P),
  #xabber_conversation{stamp = integer_to_binary(UpdateAt), type = ConversationType, thread = Thread, jid = jid:from_string(Conversation), sub_els = ConversationMetadata}.

define_type(Type,Encrypted,Incognito,P2P) ->
  case Type of
    <<"groupchat">> when Incognito == false andalso P2P == false ->
      <<"group">>;
    <<"groupchat">> when Incognito =/= false andalso P2P =/= false ->
      <<"private">>;
    <<"groupchat">> when Incognito =/= false andalso P2P == false ->
      <<"incognito">>;
    _ when Encrypted =/= false ->
      <<"encrypted">>;
    _ ->
      Type
  end.

check_conversation_type(_Acc,_LUser,_LServer,_Conversation,_Read,_Delivered,_Display,ConversationStatus,_Retract,_Type,_Encrypted) ->
  case ConversationStatus of
    <<"deleted">> ->
      {stop,[#xabber_deleted_conversation{}]};
    _ ->
      []
  end.

create_synchronization_metadata(Acc,LUser,LServer,Conversation,Read,Delivered,Display,_ConversationStatus,Retract,Type,Encrypted) ->
  {PUser, PServer,_} = jid:tolower(jid:from_string(Conversation)),
  IsLocal = lists:member(PServer,ejabberd_config:get_myhosts()),
  case Type of
    <<"groupchat">> when IsLocal == true ->
      LastRead = get_groupchat_last_readed(PServer,PUser,LServer,LUser),
      User = jid:to_string(jid:make(LUser,LServer)),
      Chat = jid:to_string(jid:make(PUser,PServer)),
      Status = mod_groupchat_users:check_user_if_exist(LServer,User,Chat),
      Count = get_count_groupchat_messages(PServer,PUser,binary_to_integer(LastRead),Conversation,Status),
      LastMessage = get_last_groupchat_message(PServer,PUser,Status,LUser),
      LastCall = get_actual_last_call(LUser, LServer, PUser, PServer),
      Unread = #xabber_conversation_unread{count = Count, 'after' = LastRead},
      XabberDelivered = #xabber_conversation_delivered{id = Delivered},
      XabberDisplayed = #xabber_conversation_displayed{id = Display},
      User = jid:to_string(jid:make(LUser,LServer)),
      UserCard = mod_groupchat_users:form_user_card(User,Chat),
      SubEls = [Unread, XabberDisplayed, XabberDelivered] ++ LastMessage,
      {stop,[#xabber_metadata{node = ?NS_XABBER_REWRITE, sub_els = [#xabber_conversation_retract{version = Retract}]},
        #xabber_metadata{node = ?NS_JINGLE_MESSAGE,sub_els = LastCall},
        #xabber_metadata{node = ?NS_GROUPCHAT, sub_els = [UserCard]},
        #xabber_metadata{node = ?NS_XABBER_SYNCHRONIZATION, sub_els = SubEls}]};
    <<"groupchat">> when IsLocal == false ->
      Count = length(get_count(LUser, LServer, PUser, PServer)),
      UserCard = get_user_card(LUser, LServer, PUser, PServer),
      LastMessage = get_last_message(LUser, LServer, PUser, PServer),
      LastCall = get_actual_last_call(LUser, LServer, PUser, PServer),
      Unread = #xabber_conversation_unread{count = Count, 'after' = Read},
      XabberDelivered = #xabber_conversation_delivered{id = Delivered},
      XabberDisplayed = #xabber_conversation_displayed{id = Display},
      SubEls = [Unread, XabberDisplayed, XabberDelivered] ++ LastMessage,
      {stop,[#xabber_metadata{node = ?NS_XABBER_REWRITE, sub_els = [#xabber_conversation_retract{version = Retract}]},
        #xabber_metadata{node = ?NS_JINGLE_MESSAGE,sub_els = LastCall},
        #xabber_metadata{node = ?NS_GROUPCHAT, sub_els = UserCard},
        #xabber_metadata{node = ?NS_XABBER_SYNCHRONIZATION, sub_els = SubEls}]};
    _ when Encrypted == true ->
      Count = get_count_encrypted_messages(LServer,LUser,Conversation,binary_to_integer(Read)),
      LastMessage = get_last_encrypted_informative_message_for_chat(LServer,LUser,Conversation),
      Unread = #xabber_conversation_unread{count = Count, 'after' = Read},
      XabberDelivered = #xabber_conversation_delivered{id = Delivered},
      XabberDisplayed = #xabber_conversation_displayed{id = Display},
      SubEls = [Unread, XabberDisplayed, XabberDelivered] ++ LastMessage,
      {stop,[#xabber_metadata{node = ?NS_XABBER_REWRITE, sub_els = [#xabber_conversation_retract{version = Retract}]},
        #xabber_metadata{node = ?NS_XABBER_SYNCHRONIZATION, sub_els = SubEls}|Acc]};
    _ ->
      Count = get_count_messages(LServer,LUser,Conversation,binary_to_integer(Read)),
      LastMessage = get_last_informative_message_for_chat(LServer,LUser,Conversation),
      LastCall = get_actual_last_call(LUser, LServer, PUser, PServer),
      Unread = #xabber_conversation_unread{count = Count, 'after' = Read},
      XabberDelivered = #xabber_conversation_delivered{id = Delivered},
      XabberDisplayed = #xabber_conversation_displayed{id = Display},
      SubEls = [Unread, XabberDisplayed, XabberDelivered] ++ LastMessage,
      {stop,[#xabber_metadata{node = ?NS_XABBER_REWRITE, sub_els = [#xabber_conversation_retract{version = Retract}]},
        #xabber_metadata{node = ?NS_JINGLE_MESSAGE,sub_els = LastCall},
        #xabber_metadata{node = ?NS_XABBER_SYNCHRONIZATION, sub_els = SubEls}|Acc]}
  end.

get_last_informative_message_for_chat(LServer,LUser,Conversation) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(timestamp)d, @(xml)s, @(peer)s, @(kind)s, @(nick)s
     from archive"
    " where username=%(LUser)s and bare_peer=%(Conversation)s and %(LServer)H and txt notnull and txt !=''
    and timestamp not in (select timestamp from special_messages where %(LServer)H ) and encrypted = false
     order by timestamp desc limit 1")) of
    {selected,[<<>>]} ->
      [];
    {selected,[{TS, XML, Peer, Kind, Nick}]} ->
      Reject = get_reject(LServer,LUser,Conversation),
      case Reject of
        {TSReject,RejectMessage} when TSReject > TS ->
          RejectMessage;
        _ ->
          convert_message(TS, XML, Peer, Kind, Nick, LUser, LServer)
      end;
    _ ->
      []
  end.

get_last_encrypted_informative_message_for_chat(LServer,LUser,Conversation) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(timestamp)d, @(xml)s, @(peer)s, @(kind)s, @(nick)s
     from archive"
    " where username=%(LUser)s and bare_peer=%(Conversation)s and %(LServer)H and txt notnull and txt !=''
    and timestamp not in (select timestamp from special_messages where %(LServer)H ) and encrypted = true
     order by timestamp desc limit 1")) of
    {selected,[<<>>]} ->
      [];
    {selected,[{TS, XML, Peer, Kind, Nick}]} ->
      convert_message(TS, XML, Peer, Kind, Nick, LUser, LServer);
    _ ->
      []
  end.

store_last_call(Pkt, Peer, LUser, LServer, TS) ->
  case {mnesia:table_info(last_call, disc_only_copies),
    mnesia:table_info(last_call, memory)} of
    {[_|_], TableSize} when TableSize > ?TABLE_SIZE_LIMIT ->
      ?ERROR_MSG("Unread message counter too large, won't store message id for ~s@~s",
        [LUser, LServer]),
      {error, overflow};
    _ ->
      {PUser, PServer, _} = jid:tolower(Peer),
      F1 = fun() ->
        mnesia:write(
          #last_call{us = {LUser, LServer},
            id = integer_to_binary(TS),
            bare_peer = {PUser, PServer, <<>>},
            packet = Pkt
          })
           end,
      delete_last_call(Peer, LUser, LServer),
      case mnesia:transaction(F1) of
        {atomic, ok} ->
          Conversation = jid:to_string(jid:remove_resource(Peer)),
          update_metainfo(<<"chat">>, LServer,LUser,Conversation,<<>>),
          ?DEBUG("Save call ~p to ~p~n TS ~p ",[LUser,Peer,TS]),
          ok;
        {aborted, Err1} ->
          ?DEBUG("Cannot add message id to unread message counter of ~s@~s: ~s",
            [LUser, LServer, Err1]),
          Err1
      end
  end.

delete_last_call(Peer, LUser, LServer) ->
  {PUser, PServer, _} = jid:tolower(Peer),
  F1 = get_last_call(LUser, LServer, PUser, PServer),
  ?DEBUG("Delete call ~p to ~p~n Call ~p ",[LUser,Peer,F1]),
  lists:foreach(
    fun(Msg) ->
      mnesia:dirty_delete_object(Msg)
    end, F1).

get_last_call(LUser, LServer, PUser, PServer) ->
  FN = fun()->
    mnesia:match_object(last_call,
      {last_call, {LUser, LServer}, {PUser, PServer,<<>>},'_','_'},
      read)
       end,
  {atomic,MsgRec} = mnesia:transaction(FN),
  MsgRec.

get_actual_last_call(LUser, LServer, PUser, PServer) ->
  FN = fun()->
    mnesia:match_object(last_call,
      {last_call, {LUser, LServer}, {PUser, PServer,<<>>},'_','_'},
      read)
       end,
  {atomic,MsgRec} = mnesia:transaction(FN),
  TS = time_now(),
  TS10 = TS - 600000000,
  ActualCall = [X||X <- MsgRec, binary_to_integer(X#last_call.id) =< TS, binary_to_integer(X#last_call.id) >= TS10],
  OldCallToDelete = [X||X <- MsgRec, binary_to_integer(X#last_call.id) < TS10],
  lists:foreach(
    fun(Msg) ->
      mnesia:dirty_delete_object(Msg)
    end, OldCallToDelete),
  ?DEBUG("actual call ~p~n~n TS NOW ~p TS10 ~p",[ActualCall,TS,TS10]),
  case ActualCall of
    [] -> [];
    [#last_call{packet = Pkt}] -> [#xabber_conversation_call{sub_els = [Pkt]}];
    _ -> []
  end.

store_last_msg(Pkt, Peer, LUser, LServer, TS, OriginIDRecord) ->
  case {mnesia:table_info(last_msg, disc_only_copies),
    mnesia:table_info(last_msg, memory)} of
    {[_|_], TableSize} when TableSize > ?TABLE_SIZE_LIMIT ->
      ?ERROR_MSG("Last messages too large, won't store message id for ~s@~s",
        [LUser, LServer]),
      {error, overflow};
    _ ->
      {PUser, PServer, _} = jid:tolower(Peer),
      UserID = get_user_id(Pkt),
      case UserID of
        false -> ok;
        _ ->
          F1 = fun() ->
            mnesia:write(
              #last_msg{us = {LUser, LServer},
                bare_peer = {PUser, PServer, <<>>},
                id = TS,
                user_id = UserID,
                packet = Pkt
              })
               end,
          delete_last_msg(Peer, LUser, LServer),
          IsService = xmpp:get_subtag(Pkt,#xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE}),
          case mnesia:transaction(F1) of
            {atomic, ok} ->
              ?DEBUG("Save last msg ~p to ~p~n",[LUser,Peer]),
              OriginID = get_origin_id(OriginIDRecord),
              store_last_msg_in_counter(Peer, LUser, LServer, UserID, TS, OriginID, IsService),
              ok;
            {aborted, Err1} ->
              ?DEBUG("Cannot add last msg for ~s@~s: ~s",
                [LUser, LServer, Err1]),
              Err1
          end
      end
  end.

get_origin_id(#origin_id{id = OriginID}) ->
  OriginID;
get_origin_id(_OriginID) ->
  <<>>.

store_last_msg(Pkt, Peer, LUser, LServer, TS) ->
  case {mnesia:table_info(last_msg, disc_only_copies),
    mnesia:table_info(last_msg, memory)} of
    {[_|_], TableSize} when TableSize > ?TABLE_SIZE_LIMIT ->
      ?ERROR_MSG("Last messages too large, won't store message id for ~s@~s",
        [LUser, LServer]),
      {error, overflow};
    _ ->
      {PUser, PServer, _} = jid:tolower(Peer),
      UserID = get_user_id(Pkt),
      case UserID of
        false -> ok;
        _ ->
          F1 = fun() ->
            mnesia:write(
              #last_msg{us = {LUser, LServer},
                bare_peer = {PUser, PServer, <<>>},
                id = TS,
                user_id = UserID,
                packet = Pkt
              })
               end,
          delete_last_msg(Peer, LUser, LServer),
          case mnesia:transaction(F1) of
            {atomic, ok} ->
              ?DEBUG("Save last msg ~p to ~p~n",[LUser,Peer]),
              ok;
            {aborted, Err1} ->
              ?DEBUG("Cannot add last msg for ~s@~s: ~s",
                [LUser, LServer, Err1]),
              Err1
          end
      end
  end.


get_user_id(Pkt) ->
  get_id_from_x(xmpp:get_subtag(Pkt, #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT})).

get_id_from_x(false) ->
  false;
get_id_from_x(X) ->
  get_card_from_refence(xmpp:get_subtag(X,#xmppreference{})).

get_card_from_refence(false) ->
  false;
get_card_from_refence(Reference) ->
  get_id_from_card(xmpp:get_subtag(Reference, #xabbergroupchat_user_card{})).

get_id_from_card(#xabbergroupchat_user_card{id = ID}) ->
  ID;
get_id_from_card(_Card) ->
  false.

store_last_msg_in_counter(Peer, LUser, LServer, UserID, TS, OriginID, false) ->
  case {mnesia:table_info(last_msg, disc_only_copies),
    mnesia:table_info(last_msg, memory)} of
    {[_|_], TableSize} when TableSize > ?TABLE_SIZE_LIMIT ->
      ?ERROR_MSG("Unread counter too large, won't store message id for ~s@~s",
        [LUser, LServer]),
      {error, overflow};
    _ ->
      {PUser, PServer, _} = jid:tolower(Peer),
      F1 = fun() ->
        mnesia:write(
          #unread_msg_counter{us = {LUser, LServer},
            bare_peer = {PUser, PServer, <<>>},
            origin_id = OriginID,
            user_id = UserID,
            id = TS
          })
           end,
      case mnesia:transaction(F1) of
        {atomic, ok} ->
          ?DEBUG("Save last msg ~p to ~p~n",[LUser,Peer]),
          ok;
        {aborted, Err1} ->
          ?DEBUG("Cannot add unread counter for ~s@~s: ~s",
            [LUser, LServer, Err1]),
          Err1
      end
  end;
store_last_msg_in_counter(_Peer, _LUser, _LServer, _UserID, _TS, _OriginID, _IsService) ->
  ok.

delete_last_msg(Peer, LUser, LServer) ->
  {PUser, PServer,_R} = jid:tolower(Peer),
  Msgs = get_last_messages(LUser, LServer, PUser, PServer),
  lists:foreach(
    fun(Msg) ->
      mnesia:dirty_delete_object(Msg)
    end, Msgs).

get_count(LUser, LServer, PUser, PServer) ->
  FN = fun()->
    mnesia:match_object(unread_msg_counter,
      {unread_msg_counter, {LUser, LServer}, {PUser, PServer,<<>>},'_','_','_','_'},
      read)
       end,
  {atomic,Msgs} = mnesia:transaction(FN),
  Msgs.

get_last_message(LUser, LServer, PUser, PServer) ->
  FN = fun()->
    mnesia:match_object(last_msg,
      {last_msg, {LUser, LServer}, {PUser, PServer,<<>>},'_','_','_'},
      read)
       end,
  {atomic,MsgRec} = mnesia:transaction(FN),
  case MsgRec of
    [] ->
      Chat = jid:to_string(jid:make(PUser,PServer)),
      get_invite(LServer,LUser,Chat);
    _ ->
      SortFun = fun(E1,E2) -> ID1 = binary_to_integer(E1#last_msg.id), ID2 = binary_to_integer(E2#last_msg.id), ID1 > ID2 end,
      MsgSort = lists:sort(SortFun,MsgRec),
      [Msg|_Rest] = MsgSort,
      #last_msg{packet = Packet} = Msg,
      [#xabber_conversation_last{sub_els = [Packet]}]
  end.

get_last_messages(LUser, LServer, PUser, PServer) ->
  FN = fun()->
    mnesia:match_object(last_msg,
      {last_msg, {LUser, LServer}, {PUser, PServer,<<>>},'_','_','_'},
      read)
       end,
  {atomic,MsgRec} = mnesia:transaction(FN),
  MsgRec.

delete_msg(_LUser, _LServer, _PUser, _PServer, empty) ->
  ok;
delete_msg(LUser, LServer, PUser, PServer, TS) ->
  Msgs = get_count(LUser, LServer, PUser, PServer),
  MsgsToDelete = [X || X <- Msgs, X#unread_msg_counter.id =< TS],
  ?DEBUG("to delete ~p~n~n TS ~p",[MsgsToDelete,TS]),
  lists:foreach(
    fun(Msg) ->
      mnesia:dirty_delete_object(Msg)
    end, MsgsToDelete).

delete_one_msg(LUser, LServer, PUser, PServer, TS) ->
  Msgs = get_count(LUser, LServer, PUser, PServer),
  LastMsg = get_last_messages(LUser, LServer, PUser, PServer),
  case LastMsg of
    [#last_msg{id = TS,packet = _Pkt}] ->
      lists:foreach(
        fun(LMsg) ->
          mnesia:dirty_delete_object(LMsg)
        end, LastMsg);
    _ ->
      ok
  end,
  MsgsToDelete = [X || X <- Msgs, X#unread_msg_counter.id == TS],
  lists:foreach(
    fun(Msg) ->
      mnesia:dirty_delete_object(Msg)
    end, MsgsToDelete).

delete_user_msg(LUser, LServer, PUser, PServer, UserID) ->
  Msgs = get_count(LUser, LServer, PUser, PServer),
  MsgsToDelete = [X || X <- Msgs, X#unread_msg_counter.user_id == UserID],
  LastMsg = get_last_messages(LUser, LServer, PUser, PServer),
  case LastMsg of
    [#last_msg{user_id = UserID,packet = _Pkt}] ->
      lists:foreach(
        fun(LMsg) ->
          mnesia:dirty_delete_object(LMsg)
        end, LastMsg);
    _ ->
      ok
  end,
  lists:foreach(
    fun(Msg) ->
      mnesia:dirty_delete_object(Msg)
    end, MsgsToDelete).

delete_all_msgs(LUser, LServer, PUser, PServer) ->
  Msgs = get_count(LUser, LServer, PUser, PServer),
  Peer = jid:make(PUser,PServer),
  delete_last_msg(Peer, LUser, LServer),
  lists:foreach(
    fun(Msg) ->
      mnesia:dirty_delete_object(Msg)
    end, Msgs).

get_stanza_id(Pkt,BareJID) ->
  case xmpp:get_subtag(Pkt, #stanza_id{}) of
    #stanza_id{by = BareJID, id = StanzaID} ->
      StanzaID;
    _ ->
      empty
  end.

get_stanza_id_of_chat(Pkt,LUser,LServer,PUser,PServer,OriginID) ->
  BareJID = jid:make(LUser, LServer),
  case xmpp:get_subtag(Pkt, #stanza_id{}) of
    #stanza_id{by = BareJID, id = StanzaID} ->
      StanzaID;
    _ ->
      get_stanza_id_from_counter(LUser,LServer,PUser,PServer,OriginID)
  end.

get_stanza_id(Pkt,BareJID,LServer,OriginID) ->
  case xmpp:get_subtag(Pkt, #stanza_id{}) of
    #stanza_id{by = BareJID, id = StanzaID} ->
      StanzaID;
    _ ->
      LUser = BareJID#jid.luser,
      get_stanza_id_by_origin_id(LServer,OriginID,LUser)
  end.

get_stanza_id_from_counter(LUser,LServer,PUser,PServer,OriginID) ->
  Msgs = get_count(LUser, LServer, PUser, PServer),
  Msg = [X || X <- Msgs, X#unread_msg_counter.origin_id == OriginID],
  SortFun = fun(E1,E2) -> ID1 = binary_to_integer(E1#unread_msg_counter.id), ID2 = binary_to_integer(E2#unread_msg_counter.id), ID1 > ID2 end,
  SortMsg = lists:sort(SortFun,Msg),
  case SortMsg of
    [#unread_msg_counter{id = StanzaID}| _Rest] ->
      StanzaID;
    _ ->
      get_id_from_special_messages(LUser,LServer,PUser,PServer,OriginID)
  end.

get_id_from_special_messages(LUser,LServer,PUser,PServer,OriginID) ->
  Conv = jid:to_string(jid:make(PUser,PServer)),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(timestamp)s
     from special_messages"
    " where username=%(LUser)s and conversation=%(Conv)s and origin_id=%(OriginID)s and %(LServer)H order by timestamp desc")) of
    {selected,[<<>>]} ->
      empty;
    {selected,[]} ->
      empty;
    {selected,[{}]} ->
      empty;
    {selected,[{ID}]} ->
      ID;
    _ ->
      empty
  end.

store_last_sync(Sync, ChatName, ChatServer, PUser, PServer, TS) ->
  case {mnesia:table_info(last_sync, disc_only_copies),
    mnesia:table_info(last_sync, memory)} of
    {[_|_], TableSize} when TableSize > ?TABLE_SIZE_LIMIT ->
      ?ERROR_MSG("Last sync too large, won't store message id for ~s@~s",
        [PUser, PServer]),
      {error, overflow};
    _ ->
      F1 = fun() ->
        mnesia:write(
          #last_sync{us = {ChatName, ChatServer},
            id = TS,
            bare_peer = {PUser, PServer, <<>>},
            packet = Sync
          })
           end,
      delete_last_sync(ChatName, ChatServer, PUser, PServer),
      case mnesia:transaction(F1) of
        {atomic, ok} ->
          ok;
        {aborted, Err1} ->
          ?DEBUG("Cannot add message id to last sync of ~s@~s: ~s",
            [PUser, PServer, Err1]),
          Err1
      end
  end.

delete_last_sync(ChatName, ChatServer, PUser, PServer) ->
  F1 = get_last_sync(ChatName, ChatServer, PUser, PServer),

  lists:foreach(
    fun(Msg) ->
      mnesia:dirty_delete_object(Msg)
    end, F1).

get_last_sync(ChatName, ChatServer, PUser, PServer) ->
  FN = fun()->
    mnesia:match_object(last_sync,
      {last_sync, {ChatName, ChatServer}, {PUser, PServer,<<>>}, '_','_'},
      read)
       end,
  {atomic,MsgRec} = mnesia:transaction(FN),
  MsgRec.

update_metadata(invite,<<"groupchat">>, LServer,LUser,Conversation) ->
  Type = <<"groupchat">>,
  Status = <<"active">>,
  ?DEBUG("save groupchat ~p ~p",[LUser,Conversation]),
  TS = time_now(),
  ?SQL_UPSERT(
    LServer,
    "conversation_metadata",
    ["!username=%(LUser)s",
      "!conversation=%(Conversation)s",
      "type=%(Type)s",
      "updated_at=%(TS)d",
      "status=%(Status)s",
      "metadata_updated_at=%(TS)d",
      "server_host=%(LServer)s"]).


get_privacy(#xabbergroupchat_privacy{cdata = Privacy}) ->
  Privacy;
get_privacy(_Privacy) ->
  <<"public">>.

update_metainfo(_Any, _LServer,_LUser,_Conversation, empty) ->
  ?DEBUG("No id in displayed",[]),
  ok;
update_metainfo(<<"groupchat">>, LServer,LUser,Conversation,X) ->
  Type = <<"groupchat">>,
  Privacy = get_privacy(xmpp:get_subtag(X, #xabbergroupchat_privacy{})),
  Parent = X#xabbergroupchat_x.parent,
  case Privacy of
    <<"incognito">> when Parent == undefined ->
      TS = time_now(),
      ejabberd_sql:sql_query(
        LServer,
        ?SQL("update conversation_metadata set type = %(Type)s, metadata_updated_at = %(TS)d,  incognito = 'true'
    where username=%(LUser)s and conversation=%(Conversation)s and incognito = 'false' and %(LServer)H")
      );
    _ when Parent =/= undefined ->
      TS = time_now(),
      ejabberd_sql:sql_query(
        LServer,
        ?SQL("update conversation_metadata set type = %(Type)s, metadata_updated_at = %(TS)d,  p2p = 'true'
    where username=%(LUser)s and conversation=%(Conversation)s and p2p = 'false' and %(LServer)H")
      );
    _ ->
      TS = time_now(),
      ejabberd_sql:sql_query(
        LServer,
        ?SQL("update conversation_metadata set type = %(Type)s, metadata_updated_at = %(TS)d
    where username=%(LUser)s and conversation=%(Conversation)s and type != %(Type)s and %(LServer)H")
      )
  end;
update_metainfo(<<"chat">>, LServer,LUser,Conversation,_StanzaID) ->
  Type = <<"chat">>,
  ?DEBUG("save chat ~p ~p",[LUser,Conversation]),
  TS = time_now(),
 ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set type = %(Type)s, metadata_updated_at = %(TS)d
    where username=%(LUser)s and conversation=%(Conversation)s and type != %(Type)s and %(LServer)H")
  );
update_metainfo(message, LServer,LUser,Conversation,_StanzaID) ->
  ?DEBUG("save new message ~p ~p ",[LUser,Conversation]),
  TS = time_now(),
  Status = <<"active">>,
  ?SQL_UPSERT(
    LServer,
    "conversation_metadata",
    ["!username=%(LUser)s",
      "!conversation=%(Conversation)s",
      "updated_at=%(TS)d",
      "metadata_updated_at=%(TS)d",
      "status=%(Status)s",
      "server_host=%(LServer)s"]);
update_metainfo(delivered, LServer,LUser,Conversation,StanzaID) ->
  ?DEBUG("save delivered ~p ~p ~p",[LUser,Conversation,StanzaID]),
  TS = time_now(),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set metadata_updated_at = %(TS)d, delivered_until = %(StanzaID)s
    where username=%(LUser)s and conversation=%(Conversation)s and delivered_until::bigint <= %(StanzaID)d and %(LServer)H")
  );
update_metainfo(read, LServer,LUser,Conversation,StanzaID) ->
  TS = time_now(),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set metadata_updated_at = %(TS)d, read_until = %(StanzaID)s
    where username=%(LUser)s and conversation=%(Conversation)s and read_until::bigint <= %(StanzaID)d and %(LServer)H")
  );
update_metainfo(displayed, LServer,LUser,Conversation,StanzaID) ->
  ?DEBUG("save displayed ~p ~p ~p",[LUser,Conversation,StanzaID]),
  TS = time_now(),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set metadata_updated_at = %(TS)d, displayed_until = %(StanzaID)s
    where username=%(LUser)s and conversation=%(Conversation)s and displayed_until::bigint <= %(StanzaID)d and %(LServer)H")
  ).

update_metainfo(_Any, _LServer,_LUser,_Conversation, empty,_Type) ->
  ?DEBUG("No id in displayed",[]),
  ok;
update_metainfo(message, LServer,LUser,Conversation,_StanzaID,Encrypted) ->
  ?DEBUG("save new message ~p ~p ",[LUser,Conversation]),
  TS = time_now(),
  Status = <<"active">>,
  ?SQL_UPSERT(
    LServer,
    "conversation_metadata",
    ["!username=%(LUser)s",
      "!conversation=%(Conversation)s",
      "!encrypted=%(Encrypted)b",
      "updated_at=%(TS)d",
      "metadata_updated_at=%(TS)d",
      "status=%(Status)s",
      "server_host=%(LServer)s"]);
update_metainfo(delivered, LServer,LUser,Conversation,StanzaID,Encrypted) ->
  ?DEBUG("save delivered ~p ~p ~p",[LUser,Conversation,StanzaID]),
  TS = time_now(),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set metadata_updated_at = %(TS)d, delivered_until = %(StanzaID)s
    where username=%(LUser)s and conversation=%(Conversation)s and encrypted = %(Encrypted)b and delivered_until::bigint <= %(StanzaID)d and %(LServer)H")
  );
update_metainfo(read, LServer,LUser,Conversation,StanzaID,Encrypted) ->
  TS = time_now(),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set metadata_updated_at = %(TS)d, read_until = %(StanzaID)s
    where username=%(LUser)s and conversation=%(Conversation)s and encrypted = %(Encrypted)b and read_until::bigint <= %(StanzaID)d and %(LServer)H")
  );
update_metainfo(displayed, LServer,LUser,Conversation,StanzaID,Encrypted) ->
  ?DEBUG("save displayed ~p ~p ~p",[LUser,Conversation,StanzaID]),
  TS = time_now(),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set metadata_updated_at = %(TS)d, displayed_until = %(StanzaID)s
    where username=%(LUser)s and conversation=%(Conversation)s and encrypted = %(Encrypted)b and displayed_until::bigint <= %(StanzaID)d and %(LServer)H")
  ).

get_conversation_type(LServer,LUser,Conversation) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(type)s
     from conversation_metadata"
    " where username=%(LUser)s and conversation=%(Conversation)s and %(LServer)H")) of
    {selected,[<<>>]} ->
      not_ok;
    {selected,[{Type}]} ->
      Type;
    _ ->
      not_ok
  end.

update_retract(LServer,LUser,Conversation,NewVersion,Stanza)  ->
  TS = time_now(),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set
    retract = %(NewVersion)d, metadata_updated_at = %(TS)d
     where username=%(LUser)s and conversation=%(Conversation)s and retract < %(NewVersion)d and %(LServer)H")) of
    {updated,1} ->
      ejabberd_hooks:run(xabber_push_notification, LServer, [<<"update">>, LUser, LServer, xmpp:decode(Stanza)]),
      ok;
    _Other ->
      not_ok
  end.

get_last_stamp(LServer, LUser) ->
  SUser = ejabberd_sql:escape(LUser),
  case ejabberd_sql:sql_query(
    LServer,
    [<<"select max(metadata_updated_at) from conversation_metadata where username = '">>,SUser,<<"' ;">>]) of
    {selected,_MAX,[[null]]} ->
      <<"0">>;
    {selected,_MAX,[[Version]]} ->
      Version
  end.

get_last_message(LServer,LUser,PUser) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(timestamp)d, @(xml)s, @(peer)s, @(kind)s, @(nick)s
     from archive"
    " where username=%(LUser)s and bare_peer=%(PUser)s and %(LServer)H and txt notnull and txt !='' order by timestamp desc limit 1")) of
    {selected,[<<>>]} ->
      undefined;
    {selected,[{TS, XML, Peer, Kind, Nick}]} ->
      Reject = get_reject(LServer,LUser,PUser),
      case Reject of
        {TSReject,RejectMessage} when TSReject > TS ->
          RejectMessage;
        _ ->
          convert_message(TS, XML, Peer, Kind, Nick, LUser, LServer)
      end;
    _ ->
      undefined
  end.

get_last_previous_message(LServer,LUser,PUser,TS) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(timestamp)d, @(xml)s, @(peer)s, @(kind)s, @(nick)s
     from archive"
    " where username=%(LUser)s and bare_peer=%(PUser)s and timestamp < %(TS)d and txt notnull and txt !='' and %(LServer)H order by timestamp desc limit 1")) of
    {selected,[<<>>]} ->
      undefined;
    {selected,[{NewTS, XML, Peer, Kind, Nick}]} ->
      convert_message(NewTS, XML, Peer, Kind, Nick, LUser, LServer);
    _ ->
      undefined
  end.


get_count_messages(LServer,LUser,PUser,TS) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(count(*))d
     from archive"
    " where username=%(LUser)s and bare_peer=%(PUser)s and txt notnull and txt !='' and timestamp > %(TS)d and timestamp not in (select timestamp from special_messages where username = %(LUser)s )
     and encrypted = false and %(LServer)H")) of
    {selected,[{Count}]} ->
      Count;
    _ ->
      0
  end.

get_count_encrypted_messages(LServer,LUser,PUser,TS) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(count(*))d
     from archive"
    " where username=%(LUser)s and bare_peer=%(PUser)s and txt notnull and txt !='' and timestamp > %(TS)d and timestamp not in (select timestamp from special_messages where username = %(LUser)s )
    and encrypted = true and %(LServer)H")) of
    {selected,[{Count}]} ->
      Count;
    _ ->
      0
  end.

get_last_groupchat_message(LServer,LUser,Status,User) ->
  Chat = jid:to_string(jid:make(LUser,LServer)),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(timestamp)d, @(xml)s, @(peer)s, @(kind)s, @(nick)s
     from archive"
    " where username=%(LUser)s  and txt notnull and txt !='' and %(LServer)H order by timestamp desc limit 1")) of
    {selected,[<<>>]} ->
      get_invite(LServer,User,Chat);
    {selected,[{TS, XML, Peer, Kind, Nick}]} when Status == <<"both">> ->
      convert_message(TS, XML, Peer, Kind, Nick, LUser, LServer);
    _ ->
      get_invite(LServer,User,Chat)
  end.

get_invite(LServer,LUser,Chat) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(timestamp)d
     from special_messages"
    " where username=%(LUser)s and conversation = %(Chat)s and type = 'invite' and %(LServer)H order by timestamp desc limit 1")) of
    {selected,[<<>>]} ->
      [];
    {selected,[{TS}]} ->
      case ejabberd_sql:sql_query(
        LServer,
        ?SQL("select
    @(timestamp)d, @(xml)s, @(peer)s, @(kind)s, @(nick)s
     from archive"
        " where username = %(LUser)s and timestamp = %(TS)d and %(LServer)H order by timestamp desc limit 1")) of
        {selected,[<<>>]} ->
          [];
        {selected,[{TS, XML, Peer, Kind, Nick}]}->
          convert_message(TS, XML, Peer, Kind, Nick, LUser, LServer);
        _ ->
          []
      end;
    _ ->
      []
  end.

get_reject(LServer,LUser,Conversation) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(timestamp)d
     from special_messages"
    " where username=%(LUser)s and conversation = %(Conversation)s and type = 'reject' and %(LServer)H order by timestamp desc limit 1")) of
    {selected,[<<>>]} ->
      {0,[]};
    {selected,[{TS}]} ->
      case ejabberd_sql:sql_query(
        LServer,
        ?SQL("select
    @(timestamp)d, @(xml)s, @(peer)s, @(kind)s, @(nick)s
     from archive"
        " where username = %(LUser)s and timestamp = %(TS)d and %(LServer)H order by timestamp desc limit 1")) of
        {selected,[<<>>]} ->
          {0,[]};
        {selected,[{TS, XML, Peer, Kind, Nick}]}->
          {TS,convert_message(TS, XML, Peer, Kind, Nick, LUser, LServer)};
        _ ->
          {0,[]}
      end;
    _ ->
      {0,[]}
  end.

get_count_groupchat_messages(LServer,LUser,TS,Conversation,Status) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(count(*))d
     from archive"
    " where username=%(LUser)s  and txt notnull and txt !='' and timestamp > %(TS)d and timestamp not in (select timestamp from special_messages where conversation = %(Conversation)s and %(LServer)H ) and %(LServer)H")) of
    {selected,[{Count}]} when Status == <<"both">> ->
      Count;
    _ ->
      0
  end.

get_groupchat_last_readed(PServer,PUser,LServer,LUser) ->
  Conv = jid:to_string(jid:make(LUser,LServer)),
  case ejabberd_sql:sql_query(
    PServer,
    ?SQL("select
    @(read_until)s
     from conversation_metadata"
    " where username=%(PUser)s and conversation=%(Conv)s and %(PServer)H order by updated_at")) of
    {selected,[<<>>]} ->
      <<"0">>;
    {selected,[{Sync}]} ->
      Sync;
    _ ->
      <<"0">>
  end.

store_special_message_id(LServer,LUser,Conv,TS,OriginID,Type) ->
  ejabberd_sql:sql_query(
    LServer,
  ?SQL_INSERT(
    "special_messages",
    ["username=%(LUser)s",
      "conversation=%(Conv)s",
      "timestamp=%(TS)d",
      "origin_id=%(OriginID)s",
      "type=%(Type)s",
      "server_host=%(LServer)s"])).


convert_message(TS, XML, Peer, Kind, Nick, LUser, LServer) ->
  case mod_mam_sql:make_archive_el(integer_to_binary(TS), XML, Peer, Kind, Nick, chat, jid:make(LUser,LServer), jid:make(LUser,LServer)) of
    {ok, ArchiveElement} ->
      #forwarded{sub_els = [Message]} = ArchiveElement,
      [#xabber_conversation_last{sub_els = [Message]}];
    _ ->
      []
  end.

get_stanza_id_by_origin_id(LServer,OriginID, LUser) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(stanza_id)d
     from origin_id"
    " where id=%(OriginID)s and username=%(LUser)s and %(LServer)H")) of
    {selected,[<<>>]} ->
      0;
    {selected,[{StanzaID}]} ->
      StanzaID;
    _ ->
      0
  end.

%%%===================================================================
%%% Handle sub_els
%%%===================================================================

handle_sub_els(chat, [#message_displayed{id = OriginID} = Displayed], From, To) ->
  {PUser, PServer, _} = jid:tolower(From),
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  {LUser,LServer,_} = jid:tolower(To),
  BareJID = jid:make(LUser,LServer),
  Type = get_conversation_type(LServer,LUser,Conversation),
  PeerJID = jid:make(PUser,PServer),
  case Type of
    <<"groupchat">> ->
      Displayed2= filter_packet(Displayed,PeerJID),
      StanzaID = get_stanza_id(Displayed2,PeerJID,LServer,OriginID),
      update_metainfo(displayed, LServer,LUser,Conversation,StanzaID);
    _ ->
      Displayed2 = filter_packet(Displayed,BareJID),
      StanzaID = get_stanza_id(Displayed2,BareJID,LServer,OriginID),
      IsEncrypted = mod_mam_sql:is_encrypted(LServer,StanzaID),
      case IsEncrypted of
        true ->
          update_metainfo(displayed, LServer,LUser,Conversation,StanzaID,true);
        _ ->
          update_metainfo(displayed, LServer,LUser,Conversation,StanzaID,false)
      end
  end;
handle_sub_els(chat, [#message_received{id = OriginID} = Delivered], From, To) ->
  {PUser, PServer, _} = jid:tolower(From),
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  {LUser,LServer,_} = jid:tolower(To),
  BareJID = jid:make(LUser,LServer),
  Delivered2 = filter_packet(Delivered,BareJID),
  StanzaID1 = get_stanza_id(Delivered2,BareJID,LServer,OriginID),
  IsEncrypted = mod_mam_sql:is_encrypted(LServer,StanzaID1),
  case IsEncrypted of
    true ->
      update_metainfo(delivered, LServer,LUser,Conversation,StanzaID1,true);
    _ ->
      update_metainfo(delivered, LServer,LUser,Conversation,StanzaID1,false)
  end;
handle_sub_els(headline, [#unique_received{} = UniqueReceived], From, To) ->
  case UniqueReceived of
    #unique_received{forwarded = Forwarded} when Forwarded =/= undefined ->
      #forwarded{sub_els = [Message]} = Forwarded,
      MessageD = xmpp:decode(Message),
      {PUser, PServer, _} = jid:tolower(From),
      PeerJID = jid:make(PUser, PServer),
      {LUser,LServer,_} = jid:tolower(To),
      Conversation = jid:to_string(PeerJID),
      StanzaID = get_stanza_id(MessageD,PeerJID),
      IsLocal = lists:member(PServer,ejabberd_config:get_myhosts()),
      case IsLocal of
        false ->
          store_last_msg(MessageD, PeerJID, LUser, LServer, StanzaID),
          delete_msg(LUser, LServer, PUser, PServer, StanzaID),
          update_metainfo(read, LServer,LUser,Conversation,StanzaID),
          update_metainfo(delivered, LServer,LUser,Conversation,StanzaID);
        _ ->
          update_metainfo(delivered, LServer,LUser,Conversation,StanzaID)
      end;
    _ ->
      ok
  end;
handle_sub_els(headline, [#xabber_retract_message{version = _Version, conversation = _Conv, id = undefined}], _From, _To) ->
  ok;
handle_sub_els(headline, [#xabber_retract_message{version = _Version, conversation = undefined, id = _ID}], _From, _To) ->
  ok;
handle_sub_els(headline, [#xabber_retract_message{version =  undefined, conversation = _Conv, id = _ID}], _From, _To) ->
  ok;
handle_sub_els(headline, [#xabber_retract_message{version = Version, conversation = ConversationJID, id = StanzaID} = Retract], _From, To) ->
  #jid{luser = LUser, lserver = LServer} = To,
  #jid{luser = PUser, lserver = PServer} = ConversationJID,
  delete_one_msg(LUser, LServer, PUser, PServer, integer_to_binary(StanzaID)),
  Conversation = jid:to_string(ConversationJID),
  update_retract(LServer,LUser,Conversation,Version,Retract),
  ok;
handle_sub_els(headline, [#xabber_retract_user{version = Version, id = UserID, conversation = ConversationJID} = Retract], _From, To) ->
  #jid{luser = LUser, lserver = LServer} = To,
  #jid{luser = PUser, lserver = PServer} = ConversationJID,
  Conversation = jid:to_string(ConversationJID),
  case update_retract(LServer,LUser,Conversation,Version,Retract) of
    ok ->
      delete_user_msg(LUser, LServer, PUser, PServer, UserID);
    _ ->
      ok
  end;
handle_sub_els(headline, [#xabber_retract_all{version = Version, conversation = ConversationJID} = Retract], _From, To) ->
  #jid{luser = LUser, lserver = LServer} = To,
  #jid{luser = PUser, lserver = PServer} = ConversationJID,
  Conversation = jid:to_string(ConversationJID),
  case update_retract(LServer,LUser,Conversation,Version,Retract) of
    ok ->
      delete_all_msgs(LUser, LServer, PUser, PServer);
    _ ->
      ok
  end;
handle_sub_els(headline, [#xabber_replace{version = undefined, conversation = _ConversationJID} = _Retract], _From, _To) ->
  ok;
handle_sub_els(headline, [#xabber_replace{version = Version, conversation = ConversationJID} = Retract], _From, To) ->
  #jid{luser = LUser, lserver = LServer} = To,
  Conversation = jid:to_string(ConversationJID),
  update_retract(LServer,LUser,Conversation,Version,Retract),
  ok;
%%handle_sub_els(headline, [#xabbergroupchat_replace{version = Version} = Retract], _From, To) ->
%%  #jid{luser = LUser, lserver = LServer} = To,
%%  ok;
handle_sub_els(headline, [#xabbergroupchat_x{type = <<"echo">>, sub_els = [Message]}], From, To) ->
  MessageD = xmpp:decode(Message),
  {PUser, PServer, _} = jid:tolower(From),
  PeerJID = jid:make(PUser, PServer),
  {LUser,LServer,_} = jid:tolower(To),
  Conversation = jid:to_string(PeerJID),
  StanzaID = get_stanza_id(MessageD,PeerJID),
  IsLocal = lists:member(PServer,ejabberd_config:get_myhosts()),
  case IsLocal of
    false ->
      get_and_store_user_card(LServer,LUser,PeerJID,MessageD),
      store_last_msg(MessageD, PeerJID, LUser, LServer, StanzaID),
      delete_msg(LUser, LServer, PUser, PServer, StanzaID),
      update_metainfo(read, LServer,LUser,Conversation,StanzaID),
      update_metainfo(delivered, LServer,LUser,Conversation,StanzaID);
    _ ->
      update_metainfo(delivered, LServer,LUser,Conversation,StanzaID)
  end,
  ok;
handle_sub_els(_Type, _SubEls, _From, _To) ->
  ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

filter_packet(Pkt,BareJID) ->
  Els = xmpp:get_els(Pkt),
  NewEls = lists:filtermap(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"stanza-id">> andalso NS == ?NS_SID_0) ->
        try xmpp:decode(El) of
          #stanza_id{by = By} ->
            By == BareJID
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          true
      end
    end, Els),
  xmpp:set_els(Pkt, NewEls).

filter_reference(Pkt,Type) ->
  Els = xmpp:get_els(Pkt),
  NewEls = lists:filtermap(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"reference">> andalso NS == ?NS_REFERENCE_0) ->
        try xmpp:decode(El) of
          #xmppreference{type = TypeRef} ->
            TypeRef == Type
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

make_sql_query(LServer, User, TS, RSM, Form) when TS == 0 orelse TS == <<"0">> ->
  {Max, Direction, Chat} = get_max_direction_chat(RSM),
  SServer = ejabberd_sql:escape(LServer),
  SUser = ejabberd_sql:escape(User),
  Timestamp = TS,
  Pinned =  proplists:get_value(filter_pinned, Form),
  PinnedFirst = proplists:get_value(pinned_first, Form),
  Archived = proplists:get_value(filter_archived, Form),
  PinnedClause = case Pinned of
                  false ->
                    [<<"and pinned = false ">>];
                  true ->
                    [<<"and pinned = true ">>];
                  _ ->
                    []
                end,
  ArchivedClause = case Archived of
                   false ->
                     [<<"and archived = false ">>];
                   true ->
                     [<<"and archived = true ">>];
                   _ ->
                     []
                 end,
  PinnedFirstClause = case PinnedFirst of
                   false ->
                     [];
                   true ->
                     [<<" pinned desc, pinned_at desc, ">>];
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
  delivered_until,
  displayed_until,
  updated_at,
  status,
  encrypted,
  incognito,
  p2p
  from conversation_metadata where username = '">>,SUser,<<"' and
  metadata_updated_at > '">>,Timestamp,<<"' and status != 'deleted' ">>],
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
          <<" GROUP BY conversation, retract, type, conversation_thread, read_until, delivered_until, displayed_until,
  updated_at, status, encrypted, pinned, pinned_at, archived, archived_at, incognito, p2p ORDER BY updated_at ASC ">>,
          LimitClause, <<") AS c ORDER BY ">>, PinnedFirstClause ,<<" updated_at DESC;">>];
      _ ->
        [Query, <<" GROUP BY conversation, retract, type, conversation_thread, read_until,
        delivered_until,  displayed_until, updated_at, status, encrypted, pinned, pinned_at, archived, archived_at, incognito, p2p
        ORDER BY ">>, PinnedFirstClause ,<<" updated_at DESC ">>,
          LimitClause, <<";">>]
    end,
  case ejabberd_sql:use_new_schema() of
    true ->
      {QueryPage,[<<"SELECT COUNT(*) FROM (">>,Conversations,<<" and server_host='">>,
        SServer, <<"' ">>,
        <<" GROUP BY conversation, retract, type, conversation_thread, read_until, delivered_until,
        displayed_until, updated_at, status, encrypted, pinned, pinned_at, archived, archived_at, incognito, p2p) as subquery;">>]};
    false ->
      {QueryPage,[<<"SELECT COUNT(*) FROM (">>,Conversations,
        <<" GROUP BY conversation, retract, type, conversation_thread, read_until, delivered_until,
        displayed_until, updated_at, status, encrypted, pinned, pinned_at, archived, archived_at, incognito, p2p) as subquery;">>]}
  end;
make_sql_query(LServer, User, TS, RSM, Form) ->
  {Max, Direction, Chat} = get_max_direction_chat(RSM),
  SServer = ejabberd_sql:escape(LServer),
  SUser = ejabberd_sql:escape(User),
  Timestamp = ejabberd_sql:escape(TS),
  Pinned =  proplists:get_value(filter_pinned, Form),
  PinnedFirst = proplists:get_value(pinned_first, Form),
  Archived = proplists:get_value(filter_archived, Form),
  PinnedClause = case Pinned of
                   false ->
                     [<<"and pinned = false ">>];
                   true ->
                     [<<"and pinned = true ">>];
                   _ ->
                     []
                 end,
  ArchivedClause = case Archived of
                     false ->
                       [<<"and archived = false ">>];
                     true ->
                       [<<"and archived = true ">>];
                     _ ->
                       []
                   end,
  PinnedFirstClause = case PinnedFirst of
                        false ->
                          [];
                        true ->
                          [<<" pinned desc, pinned_at desc, ">>];
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
  delivered_until,
  displayed_until,
  updated_at,
  status,
  encrypted,
  incognito,
  p2p
  from conversation_metadata where username = '">>,SUser,<<"' and 
  metadata_updated_at > '">>,Timestamp,<<"'">>],
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
        % ID can be empty because of
        % XEP-0059: Result Set Management
        % 2.5 Requesting the Last Page in a Result Set
        [<<"SELECT * FROM (">>, Query,
          <<" GROUP BY conversation, retract, type, conversation_thread, read_until, delivered_until, displayed_until,
  updated_at, status, encrypted, pinned, pinned_at, archived, archived_at, incognito, p2p ORDER BY updated_at ASC ">>,
          LimitClause, <<") AS c ORDER BY ">>, PinnedFirstClause ,<<" updated_at DESC;">>];
      _ ->
        [Query, <<" GROUP BY conversation, retract, type, conversation_thread, read_until, delivered_until,  displayed_until, updated_at, status, encrypted,
        pinned, pinned_at, archived, archived_at, incognito, p2p
        ORDER BY ">>, PinnedFirstClause ,<<" updated_at DESC ">>,
          LimitClause, <<";">>]
    end,
  case ejabberd_sql:use_new_schema() of
    true ->
      {QueryPage,[<<"SELECT COUNT(*) FROM (">>,Conversations,<<" and server_host='">>,
        SServer, <<"' ">>,
        <<" GROUP BY conversation, retract, type, conversation_thread, read_until, delivered_until,  displayed_until,
        updated_at, status, encrypted, pinned, pinned_at, archived, archived_at, incognito, p2p ) as subquery;">>]};
    false ->
      {QueryPage,[<<"SELECT COUNT(*) FROM (">>,Conversations,
        <<" GROUP BY conversation, retract, type, conversation_thread, read_until, delivered_until,  displayed_until,
        updated_at, status, encrypted, pinned, pinned_at, archived, archived_at, incognito, p2p ) as subquery;">>]}
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

delete_conversations(UserJID,Conversations) ->
  LUser = UserJID#jid.luser,
  LServer = UserJID#jid.lserver,
  ConvList = parse_conv(Conversations),
  lists:foreach(fun(Conversation) ->
    delete_conversation(LServer,LUser,Conversation)
                end, ConvList).

pin_conversation(#jid{lserver = LServer, luser = LUser}, #xabber_conversation{type = Type, jid = ConversationJID, thread = Thread}, Lang) ->
  TS = time_now(),
  Conversation = jid:to_string(ConversationJID),
  IsArchived = is_archived(LServer,LUser,Conversation,Type,Thread),
  case IsArchived of
    false ->
      case ejabberd_sql:sql_query(
        LServer,
        ?SQL("update conversation_metadata set pinned = 'true', pinned_at=%(TS)d where username = %(LUser)s and conversation = %(Conversation)s
    and type = %(Type)s and conversation_thread = %(Thread)s")) of
        {updated,N} when N > 0 ->
          make_ccc_push(LServer,LUser,Conversation,TS,Type,Thread,pinned);
        _ ->
          {error,xmpp:err_item_not_found()}
      end;
    true ->
      Txt = <<"Message cannot be pinned because it in archive. Remove from archive before pin">>,
      {error, xmpp:err_bad_request(Txt,Lang)};
    _ ->
      error
  end;
pin_conversation(_JID,_Conv,_Lang) ->
  {error,xmpp:err_bad_request()}.

unpin_conversation(#jid{lserver = LServer, luser = LUser}, #xabber_conversation{type = Type, jid = ConversationJID, thread = Thread}, _Lang) ->
  TS = 0,
  Conversation = jid:to_string(ConversationJID),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set pinned = 'false', pinned_at=%(TS)d where username = %(LUser)s and conversation = %(Conversation)s
    and type = %(Type)s and conversation_thread = %(Thread)s")) of
    {updated,N} when N > 0 ->
      make_ccc_push(LServer,LUser,Conversation,TS,Type,Thread,unpinned);
    _ ->
      {error,xmpp:err_item_not_found()}
  end;
unpin_conversation(_JID,_Conv,_Lang) ->
  {error,xmpp:err_bad_request()}.

archive_conversation(#jid{lserver = LServer, luser = LUser}, #xabber_conversation{type = Type, jid = ConversationJID, thread = Thread},Lang) ->
  TS = time_now(),
  Conversation = jid:to_string(ConversationJID),
  IsPinned = is_pinned(LServer,LUser,Conversation,Type,Thread),
  case IsPinned of
    false ->
      case ejabberd_sql:sql_query(
        LServer,
        ?SQL("update conversation_metadata set archived = 'true', archived_at=%(TS)d where username = %(LUser)s and conversation = %(Conversation)s
    and type = %(Type)s and conversation_thread = %(Thread)s")) of
        {updated,N} when N > 0 andalso IsPinned =/= true ->
          make_ccc_push(LServer,LUser,Conversation,TS,Type,Thread,archived);
        _ ->
          {error,xmpp:err_item_not_found()}
      end;
    true ->
      Txt = <<"Unpin message before archivation">>,
      {error, xmpp:err_bad_request(Txt,Lang)};
    _ ->
      error
  end;
archive_conversation(_JID,_Conv,_Lang) ->
  {error,xmpp:err_bad_request()}.

unarchive_conversation(#jid{lserver = LServer, luser = LUser}, #xabber_conversation{type = Type, jid = ConversationJID, thread = Thread},_Lang) ->
  TS = time_now(),
  Conversation = jid:to_string(ConversationJID),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set archived = 'false', archived_at=0 where username = %(LUser)s and conversation = %(Conversation)s
    and type = %(Type)s and conversation_thread = %(Thread)s")) of
    {updated,N} when N > 0 ->
      make_ccc_push(LServer,LUser,Conversation,TS,Type,Thread,unarchived);
    _ ->
      {error,xmpp:err_item_not_found()}
  end;
unarchive_conversation(_JID,_Conv,_Lang) ->
  {error,xmpp:err_bad_request()}.

is_pinned(LServer,LUser,Conversation,Type,Thread) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(pinned)b
       from conversation_metadata where username = %(LUser)s and conversation = %(Conversation)s
    and type = %(Type)s and conversation_thread = %(Thread)s")) of
    {selected,[{Query}]} ->
      Query;
    _ ->
      error
  end.

is_archived(LServer,LUser,Conversation,Type,Thread) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(archived)b
       from conversation_metadata where username = %(LUser)s and conversation = %(Conversation)s
    and type = %(Type)s and conversation_thread = %(Thread)s")) of
    {selected,[{Query}]} ->
      Query;
    _ ->
      error
  end.

delete_conversation(LServer,LUser,Conversation) ->
  TS = time_now(),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set status = 'deleted', updated_at=%(TS)d, metadata_updated_at=%(TS)d where username = %(LUser)s and conversation = %(Conversation)s")) of
    {updated,N} when N > 0 ->
      make_ccc_push(LServer,LUser,Conversation,TS,deleted);
    _ ->
      ok
  end.

parse_conv(Convs) ->
  lists:map(fun(Con) ->
    #xabber_conversation{jid = JID} = Con,
    jid:to_string(jid:remove_resource(JID))
            end, Convs).

%% invite logic

store_invite_information(LUser,LServer,PUser,PServer) ->
  NewInvite = #invite_msg{us = {LUser,LServer}, bare_peer = {PUser,PServer,<<>>}},
  mnesia:dirty_write(NewInvite).

get_invite_information(LUser,LServer,PUser,PServer) ->
  FN = fun()->
    mnesia:match_object(invite_msg,
      {invite_msg, {LUser, LServer}, {PUser, PServer,<<>>}},
      read)
       end,
  {atomic,MsgRec} = mnesia:transaction(FN),
  MsgRec.

maybe_delete_invite_and_conversation(LUser,LServer,PUser,PServer) ->
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  Type = get_conversation_type(LServer,LUser,Conversation),
  case Type of
    <<"groupchat">> ->
      Invites = get_invite_information(LUser,LServer,PUser,PServer),
      lists:foreach(fun(Invite) ->
        delete_invite(Invite) end, Invites
      ),
      delete_conversation(LServer,LUser,Conversation);
    _ ->
      ok
  end.

delete_old_invites(LUser,LServer,PUser,PServer) ->
  Invites = get_invite_information(LUser,LServer,PUser,PServer),
  lists:foreach(fun(Invite) ->
    delete_invite(Invite) end, Invites
  ).

delete_invite(#invite_msg{} = Invite) ->
  mnesia:dirty_delete_object(Invite).
%% request jobs

set_request_job(ServerID, {LUser,LServer,LResource}, {PUser,PServer}) ->
  RequestJob = #request_job{server_id = ServerID, usr = {LUser,LServer,LResource}, cs = {PUser,PServer}},
  mnesia:dirty_write(RequestJob).

get_request_job(ServerID,{PUser,PServer},{LUser,LServer,LResource}) ->
  FN = fun()->
    mnesia:match_object(request_job,
      {request_job, ServerID,{PUser,PServer},{LUser,LServer,LResource}},
      read)
       end,
  {atomic,Jobs} = mnesia:transaction(FN),
  Jobs.

-spec delete_job(#request_job{}) -> ok.
delete_job(#request_job{} = J) ->
  mnesia:dirty_delete_object(J).

make_ccc_push(LServer,LUser,Conversation, TS, deleted) ->
  UserResources = ejabberd_sm:user_resources(LUser,LServer),
  Conv = #xabber_conversation{jid = jid:from_string(Conversation), sub_els = [#xabber_deleted_conversation{}]},
  Query = #xabber_synchronization_query{stamp = integer_to_binary(TS), sub_els = [Conv]},
  lists:foreach(fun(Res) ->
    From = jid:make(LUser,LServer),
    To = jid:make(LUser,LServer,Res),
    IQ = #iq{from = From, to = To, type = set, id = randoms:get_string(), sub_els = [Query]},
    ejabberd_router:route(IQ)
                end, UserResources).

make_ccc_push(LServer,LUser,Conversation, TS, Type, Thread, PushType) ->
  Element = case PushType of
              pinned ->
                #xabber_pinned_conversation{};
              archived ->
                #xabber_archived_conversation{};
              unarchived ->
                #xabber_unarchived_conversation{};
              unpinned ->
                #xabber_unpinned_conversation{}
            end,
  UserResources = ejabberd_sm:user_resources(LUser,LServer),
  Conv = #xabber_conversation{jid = jid:from_string(Conversation), type = Type, thread = Thread, sub_els = [Element]},
  Query = #xabber_synchronization_query{stamp = integer_to_binary(TS), sub_els = [Conv]},
  lists:foreach(fun(Res) ->
    From = jid:make(LUser,LServer),
    To = jid:make(LUser,LServer,Res),
    IQ = #iq{from = From, to = To, type = set, id = randoms:get_string(), sub_els = [Query]},
    ejabberd_router:route(IQ)
                end, UserResources).

create_conversation(LServer,LUser,Conversation,Thread,Encrypted) ->
  TS = time_now(),
  Status = <<"active">>,
  ?SQL_UPSERT(
    LServer,
    "conversation_metadata",
    ["!username=%(LUser)s",
      "!conversation=%(Conversation)s",
      "!encrypted=%(Encrypted)b",
      "updated_at=%(TS)d",
      "conversation_thread=%(Thread)s",
      "metadata_updated_at=%(TS)d",
      "status=%(Status)s",
      "server_host=%(LServer)s"]).

get_and_store_user_card(LServer,LUser,PeerJID,Message) ->
  X = xmpp:get_subtag(Message,#xabbergroupchat_x{xmlns = ?NS_GROUPCHAT}),
  Ref = xmpp:get_subtag(X,#xmppreference{}),
  Card = xmpp:get_subtag(Ref,#xabbergroupchat_user_card{}),
  case Card of
    false ->
      ok;
    _ ->
      store_card(LServer,LUser,PeerJID,Card)
  end.

store_card(LServer,LUser,Peer,Pkt) ->
  case {mnesia:table_info(user_card, disc_only_copies),
    mnesia:table_info(user_card, memory)} of
    {[_|_], TableSize} when TableSize > ?TABLE_SIZE_LIMIT ->
      ?ERROR_MSG("Last messages too large, won't store message id for ~s@~s",
        [LUser, LServer]),
      {error, overflow};
    _ ->
      {PUser, PServer, _} = jid:tolower(Peer),
      F1 = fun() ->
        mnesia:write(
          #user_card{us = {LUser, LServer},
            bare_peer = {PUser, PServer, <<>>},
            packet = Pkt
          })
           end,
      delete_previous_card(Peer, LUser, LServer),
      case mnesia:transaction(F1) of
        {atomic, ok} ->
          ?DEBUG("Save last msg ~p to ~p~n",[LUser,Peer]),
          ok;
        {aborted, Err1} ->
          ?DEBUG("Cannot add last msg for ~s@~s: ~s",
            [LUser, LServer, Err1]),
          Err1
      end
  end.

delete_previous_card(Peer, LUser, LServer) ->
  {PUser, PServer,_R} = jid:tolower(Peer),
  Msgs = get_last_card(LUser, LServer, PUser, PServer),
  lists:foreach(
    fun(Msg) ->
      mnesia:dirty_delete_object(Msg)
    end, Msgs).

get_last_card(LUser, LServer, PUser, PServer) ->
  FN = fun()->
    mnesia:match_object(user_card,
      {user_card, {LUser, LServer}, {PUser, PServer,<<>>}, '_'},
      read)
       end,
  {atomic,MsgRec} = mnesia:transaction(FN),
  MsgRec.

get_user_card(LUser, LServer, PUser, PServer) ->
  case get_last_card(LUser, LServer, PUser, PServer) of
    [] ->
      [];
    [F|_R] ->
      #user_card{packet = Pkt} = F,
      [Pkt]
  end.

-spec body_is_encrypted(message()) -> boolean().
body_is_encrypted(#message{sub_els = SubEls}) ->
  lists:keyfind(<<"encrypted">>, #xmlel.name, SubEls) /= false.