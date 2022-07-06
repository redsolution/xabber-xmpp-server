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

%% gen_mod callbacks.
-export([start/2,stop/1,reload/3,depends/2,mod_options/1]).

%% gen_server callbacks.
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

%% hooks
-export([c2s_stream_features/2, sm_receive_packet/1, user_send_packet/1,
  groupchat_got_displayed/3, process_messages/0]).

%% iq
-export([process_iq/1]).

%%
-export([get_count/4, delete_msg/5, get_last_message/4, get_last_messages/4,get_actual_last_call/4,get_last_call/4]).

%%
-export([get_last_message/3, get_count_messages/4, get_last_groupchat_message/4, get_last_previous_message/4]).

%%
-export([get_stanza_id/2, get_stanza_id_from_counter/5, get_user_cards/4,update_mam_prefs/3]).

% syncronization_query hook
-export([create_synchronization_metadata/12, get_invite_information/4]).
-type c2s_state() :: ejabberd_c2s:state().

%% Delete after updating servers
-export([update_table/1]).

-record(old_unread_msg_counter,
{
  us = {<<"">>, <<"">>}                :: {binary(), binary()} | '_',
  bare_peer = {<<"">>, <<"">>, <<"">>} :: ljid() | '_',
  type = <<>>                          :: binary() | '_',
  user_id = <<>>                       :: binary() | '_',
  origin_id = <<>>                     :: binary() | '_',
  id = <<>>                            :: binary() | '_'
}).

%% records
-record(state, {host = <<"">> :: binary()}).

-record(invite_msg,
{
  us = {<<"">>, <<"">>}                :: {binary(), binary()} | '_',
  bare_peer = {<<"">>, <<"">>, <<"">>} :: ljid() | '_',
  id = 0                               :: non_neg_integer() | '_'
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
  id = <<>>                            :: binary() | '_',
  ts = <<>>                            :: binary() | '_'
}).

-record(request_job,
{
  server_id = <<>>                       :: binary() | '_',
  cs = {<<>>, <<>>}                      :: {binary(), binary()} | '_',
  usr = {<<>>, <<>>, <<>>}               :: {binary(), binary(), binary()} | '_'
}).

-define(TABLE_SIZE_LIMIT, 2000000000). % A bit less than 2 GiB.
-define(NS_XABBER_SYNCHRONIZATION_CHAT, <<"https://xabber.com/protocol/synchronization#chat">>).
-define(CHAT_NS,?NS_XABBER_SYNCHRONIZATION_CHAT).
-define(NS_OMEMO, <<"urn:xmpp:omemo:2">>).
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
handle_cast({sm, #presence{type = available,from = #jid{lserver = PServer, luser = PUser}, to = #jid{lserver = LServer, luser = LUser}} = Presence},State) ->
  PktNew = xmpp:decode_els(Presence),
  IsChat = xmpp:get_subtag(PktNew, #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT}),
  IsChannel = xmpp:get_subtag(PktNew, #channel_x{xmlns = ?NS_CHANNELS}),
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  {NewType, X} = if
                  IsChat =/= false -> {?NS_GROUPCHAT, IsChat} ;
                  IsChannel =/= false -> {?NS_CHANNELS, IsChannel};
                  true -> {?CHAT_NS, <<>>}
                end,
  CurrentType = get_conversation_type(LServer,LUser,Conversation),
  IsSameType = lists:member(NewType, CurrentType),
  if
    IsSameType ->
      pass;
    NewType == ?NS_GROUPCHAT orelse NewType == ?NS_CHANNELS ->
      update_mam_prefs(add,jid:make(LUser,LServer),jid:make(PUser,PServer)),
      update_type(NewType, LServer,LUser,Conversation,X);
    NewType == ?CHAT_NS ->
      update_mam_prefs(remove,jid:make(LUser,LServer),jid:make(PUser,PServer)),
      update_type(NewType, LServer,LUser,Conversation,X);
    true ->
      pass
  end,
  {noreply, State};
handle_cast({sm, #presence{type = subscribe,from = From, to = #jid{lserver = LServer, luser = LUser}} = Presence},State) ->
  X = xmpp:get_subtag(Presence, #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT}),
  {Type, GroupInfo} = case X of
                         false ->
                           maybe_push_notification(LUser, LServer,jid:to_string(jid:remove_resource(From)),
                             ?CHAT_NS,<<"subscribe">>,#presence{type = subscribe, from = From}),
                           {?CHAT_NS, <<>>};
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
  create_conversation(LServer,LUser,Conversation,<<"">>,false,Type,GroupInfo),
  {noreply, State};
handle_cast({sm, #presence{type = unsubscribe,from = #jid{lserver = PServer, luser = PUser}, to = #jid{lserver = LServer, luser = LUser}}},State) ->
  maybe_delete_invite_and_conversation(LUser,LServer,PUser,PServer),
  {noreply, State};
handle_cast({sm, #presence{type = unsubscribed,from = #jid{lserver = PServer, luser = PUser}, to = #jid{lserver = LServer, luser = LUser}}},State) ->
  maybe_delete_invite_and_conversation(LUser,LServer,PUser,PServer),
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
    create_synchronization_metadata, 60),
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
    create_synchronization_metadata, 60),
  ejabberd_hooks:delete(groupchat_got_displayed, Host, ?MODULE,
    groupchat_got_displayed, 10),
  ejabberd_hooks:delete(user_send_packet, Host, ?MODULE,
    user_send_packet, 101),
  ejabberd_hooks:delete(sm_receive_packet, Host, ?MODULE,
    sm_receive_packet, 55),
  ejabberd_hooks:delete(c2s_post_auth_features, Host, ?MODULE,
    c2s_stream_features, 50).

c2s_stream_features(Acc, Host) ->
  case gen_mod:is_loaded(Host, ?MODULE) of
    true ->
      [#xabber_synchronization{}|Acc];
    false ->
      Acc
  end.

groupchat_got_displayed(From,ChatJID,TS) ->
  #jid{luser =  LUser,lserver = LServer} = ChatJID,
  #jid{lserver = PServer, luser = PUser} = From,
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  update_metainfo(read, LServer,LUser,Conversation,TS,?CHAT_NS).

-spec sm_receive_packet(stanza()) -> stanza().
sm_receive_packet(#message{to = #jid{luser = LUser, lserver = LServer}} = Pkt) ->
  Proc = get_subprocess(LUser,LServer),
  Proc ! {in, Pkt},
  Pkt;
sm_receive_packet(#presence{to = #jid{lserver = LServer}} = Pkt) ->
  Proc = gen_mod:get_module_proc(LServer, ?MODULE),
  gen_server:cast(Proc, {sm,Pkt}),
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
process_iq(#iq{type = set, sub_els = [#xabber_synchronization_query{
  sub_els = [#xabber_conversation{status = undefined, mute = undefined, pinned = undefined} ]}]} = IQ) ->
  xmpp:make_error(IQ, xmpp:err_bad_request());
process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = set,
  sub_els = [#xabber_synchronization_query{
    sub_els = [#xabber_conversation{status = Status, mute = undefined, pinned = undefined} = Conversation]}]} = IQ) ->
  Result = case Status of
             deleted ->
               delete_conversation(LServer, LUser,Conversation);
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
    sub_els =[#xabber_conversation{mute = undefined, pinned = Order} = Conversation]}]} = IQ) when Order /= undefined ->
  iq_result(IQ, pin_conversation(LServer, LUser, Conversation));
process_iq(#iq{from = #jid{luser = LUser, lserver = LServer}, type = set,
  sub_els = [#xabber_synchronization_query{
    sub_els =[#xabber_conversation{mute = Period, pinned = undefined} = Conversation]}]} = IQ) when Period /= undefined->
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
process_message(in,#message{type = chat, body = [], from = From, to = To, sub_els = SubEls} = Pkt)->
  check_voip_msg(Pkt),
  DecSubEls = lists:map(fun(El) -> xmpp:decode(El) end, SubEls),
  handle_sub_els(chat,DecSubEls,From,To);
process_message(in,#message{id = _ID, type = chat, from = Peer, to = To, meta = #{stanza_id := TS}} = Pkt)->
  {LUser, LServer, _ } = jid:tolower(To),
  {PUser, PServer, _} = jid:tolower(Peer),
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  Invite = xmpp:get_subtag(Pkt, #xabbergroupchat_invite{}),
  GroupSysMsg = xmpp:get_subtag(Pkt, #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE}),
  GroupMsg = xmpp:get_subtag(Pkt, #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT}),
  OriginIDElemnt = xmpp:get_subtag(Pkt, #origin_id{}),
  OriginID = get_origin_id(OriginIDElemnt),
  IsLocal = lists:member(PServer,ejabberd_config:get_myhosts()),
  Type = case get_conversation_type(LServer,LUser,Conversation) of
           [] when GroupSysMsg =/= false orelse GroupMsg =/= false-> ?NS_GROUPCHAT;
           [T] -> T;
           _ -> undefined
         end,
  if
    Invite  =/= false ->
      #xabbergroupchat_invite{jid = ChatJID} = Invite,
      case ChatJID of
        undefined ->
          %% Bad invite
          ok;
%%          update_metainfo(message, LServer,LUser,Conversation,TS),
%%          maybe_push_notification(LUser,LServer,Conversation,?CHAT_NS,
%%            <<"message">>,#stanza_id{id = integer_to_binary(TS), by = jid:remove_resource(To)});
        _ ->
          Chat = jid:to_string(jid:remove_resource(ChatJID)),
          store_special_message_id(LServer,LUser,Chat,TS,OriginID,<<"invite">>),
          store_invite_information(LUser,LServer,ChatJID#jid.luser,ChatJID#jid.lserver, TS),
          create_conversation(LServer,LUser,Chat,<<>>,false,?NS_GROUPCHAT,<<>>),
          update_mam_prefs(add,To,ChatJID),
          maybe_push_notification(LUser,LServer,Conversation,?CHAT_NS,
            <<"message">>,#stanza_id{id = integer_to_binary(TS), by = jid:remove_resource(To)})
      end;
    Type == ?NS_GROUPCHAT; Type == ?NS_CHANNELS ->
      FilPacket = filter_packet(Pkt,jid:remove_resource(Peer)),
      StanzaID = xmpp:get_subtag(FilPacket, #stanza_id{}),
      case StanzaID of
        false ->
          %% Bad message
          ok;
        _ ->
          TSGroupchat = StanzaID#stanza_id.id,
          if
            IsLocal andalso GroupSysMsg ->
              store_special_message_id(LServer,LUser,Conversation,binary_to_integer(TSGroupchat),OriginID,<<"service">>);
            IsLocal ->
              pass;
            true ->
              store_last_msg(Pkt, Peer, LUser, LServer,TSGroupchat, OriginID)
          end,
          update_metainfo(LServer,LUser,Conversation, Type),
          maybe_push_notification(LUser,LServer,Conversation,Type,<<"message">>,StanzaID)
      end;
    true ->
      case check_voip_msg(Pkt) of
        false ->
          case body_is_encrypted(Pkt) of
            {true, NS} ->
              maybe_push_notification(LUser,LServer,Conversation,NS,
                <<"message">>,#stanza_id{id = integer_to_binary(TS), by = jid:remove_resource(To)}),
              create_conversation(LServer,LUser,Conversation,<<"">>,true,NS,<<>>),
              update_metainfo(LServer, LUser, Conversation,NS);
            _ ->
              maybe_push_notification(LUser,LServer,Conversation,?CHAT_NS,
                <<"message">>,#stanza_id{id = integer_to_binary(TS), by = jid:remove_resource(To)}),
              update_metainfo(LServer, LUser, Conversation,?CHAT_NS)
          end;
        _ ->
          ok
      end
  end;
process_message(in, #message{type = headline, body = [], from = From, to = To, sub_els = SubEls})->
  DecSubEls = lists:map(fun(El) -> xmpp:decode(El) end, SubEls),
  handle_sub_els(headline,DecSubEls,From,To);
process_message(out, #message{id = ID, type = chat, from = #jid{luser =  LUser,lserver = LServer},
  to = #jid{lserver = PServer, luser = PUser} = To,
  meta = #{stanza_id := TS, mam_archived := true}} = Pkt)->
  Invite = xmpp:get_subtag(Pkt, #xabbergroupchat_invite{}),
  Accept = xmpp:get_subtag(Pkt, #jingle_accept{}),
  Reject = xmpp:get_subtag(Pkt, #jingle_reject{}),
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  if
    is_record(Accept, jingle_accept) ->
      maybe_push_notification(LUser,LServer,<<"data">>,Accept),
      delete_last_call(To, LUser, LServer);
    is_record(Reject, jingle_reject) ->
      maybe_push_notification(LUser,LServer,<<"data">>,Reject),
      store_special_message_id(LServer,LUser,Conversation,TS,ID,<<"reject">>),
      delete_last_call(To, LUser, LServer);
    Invite =/= false ->
      maybe_push_notification(LUser,LServer,<<"outgoing">>,
        #stanza_id{id = integer_to_binary(TS), by = jid:make(LServer)}),
      store_special_message_id(LServer,LUser,Conversation,TS,ID,<<"invite">>);
    true ->
      Encrypted = body_is_encrypted(Pkt),
      Type = case Encrypted of
                      {true, NS} ->
                        create_conversation(LServer,LUser,Conversation,<<"">>,true,NS,<<>>),
                        NS;
                      _ ->
                        update_metainfo(LServer,LUser,Conversation,undefined),
                        undefined
                    end,
      update_metainfo(read, LServer,LUser,Conversation,TS,Type),
      maybe_push_notification(LUser,LServer,<<"outgoing">>,
        #stanza_id{id = integer_to_binary(TS), by = jid:make(LServer)})
  end;
process_message(out, #message{type = chat, from = #jid{luser =  LUser,lserver = LServer},
  to = #jid{luser =  PUser,lserver = PServer}} = Pkt)->
  Displayed = xmpp:get_subtag(Pkt, #message_displayed{}),
  IsLocal = lists:member(PServer,ejabberd_config:get_myhosts()),
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  Type = case get_conversation_type(LServer,LUser,Conversation) of
           [T] -> T;
           _ -> undefined
         end,
  case Displayed of
    #message_displayed{id = OriginID} when Type == ?NS_GROUPCHAT ->
      FilPacket = filter_packet(Displayed,jid:make(PUser,PServer)),
      StanzaID = case xmpp:get_subtag(FilPacket, #stanza_id{}) of
                   #stanza_id{id = SID} ->
                     SID;
                   _ ->
                     get_stanza_id_from_counter(LUser,LServer,PUser,PServer,OriginID)
                 end,
      update_metainfo(read, LServer,LUser,Conversation,StanzaID,Type),
      maybe_push_notification(LUser,LServer,<<"displayed">>,Displayed),
      if
        IsLocal -> pass;
        true ->
          delete_msg(LUser, LServer, PUser, PServer, StanzaID)
      end;
    #message_displayed{id = OriginID} ->
      BareJID = jid:make(LUser,LServer),
      Displayed2 = filter_packet(Displayed,BareJID),
      StanzaID = get_stanza_id(Displayed2,BareJID,LServer,OriginID),
      Type1 = case Type of
                undefined ->
                  case mod_mam_sql:is_encrypted(LServer,StanzaID) of
                    {true, NS} -> NS;
                    _-> ?CHAT_NS
                  end;
                _-> Type
              end,
      update_metainfo(read, LServer,LUser,Conversation,StanzaID,Type1),
      maybe_push_notification(LUser,LServer,<<"displayed">>,Displayed);
    _ ->
      ok
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
  read_until, delivered_until, displayed_until, updated_at, status,
  encrypted, pinned, mute, group_info
  from conversation_metadata where username = '">>,SUser,<<"' and
  conversation = '">>,SConversation,<<"' and type = '">>,SType,<<"'">>,HostClause,<<";">>],
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
  #xabber_synchronization_query{sub_els = ReplacedConv, stamp = LastStamp, rsm = ResRSM}.

convert_result(Result) ->
  lists:map(fun(El) ->
    [Conversation,Retract,Type,Thread,
      Read,Delivered,Display,UpdateAt,
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
      Read,Delivered,Display,binary_to_integer(UpdateAt),
      binary_to_atom(Status,utf8),ejabberd_sql:to_bool(Encrypted),
      Pinned,binary_to_integer(Mute), GroupXelem} end, Result).

make_result_el(LServer, LUser, El) ->
  {Conversation,Retract,Type,Thread,Read,
    Delivered,Display,UpdateAt,ConversationStatus,Encrypted,Pinned,Mute,GroupInfo} = El,
  ConversationMetadata = ejabberd_hooks:run_fold(syncronization_query,
    LServer, [], [LUser,LServer,Conversation,Read,Delivered,Display,ConversationStatus,Retract,Type,Encrypted,GroupInfo]),
  CElem = #xabber_conversation{stamp = integer_to_binary(UpdateAt), type = Type, status = ConversationStatus,
    thread = Thread, jid = jid:from_string(Conversation), pinned = Pinned, sub_els = ConversationMetadata},
  Now = time_now() div 1000000,
  if
    Mute >= Now -> CElem#xabber_conversation{mute = integer_to_binary(Mute)};
    true -> CElem
  end.

create_synchronization_metadata(_Acc,_LUser,_LServer,_Conversation,
    _Read,_Delivered,_Display,deleted,_Retract,_Type,_Encrypted,_GroupInfo) ->
  {stop,[]};
create_synchronization_metadata(Acc,LUser,LServer,Conversation,
    Read,Delivered,Display,_ConversationStatus,Retract,Type,Encrypted,GroupInfo) ->
  {PUser, PServer,_} = jid:tolower(jid:from_string(Conversation)),
  IsLocal = lists:member(PServer,ejabberd_config:get_myhosts()),
  case Type of
    ?NS_CHANNELS when IsLocal == false ->
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
        #xabber_metadata{node = ?NS_CHANNELS, sub_els = UserCard},
        #xabber_metadata{node = ?NS_XABBER_SYNCHRONIZATION, sub_els = SubEls}]};
    ?NS_CHANNELS ->
      LastRead = get_groupchat_last_readed(PServer,PUser,LServer,LUser),
      User = jid:to_string(jid:make(LUser,LServer)),
      Chat = jid:to_string(jid:make(PUser,PServer)),
      Status = mod_channels_users:check_user_if_exist(LServer,User,Chat),
      Count = get_count_groupchat_messages(User,Chat,binary_to_integer(LastRead),Conversation,Status),
      LastMessage = get_last_groupchat_message(PServer,PUser,Status,LUser),
      LastCall = get_actual_last_call(LUser, LServer, PUser, PServer),
      Unread = #xabber_conversation_unread{count = Count, 'after' = LastRead},
      XabberDelivered = #xabber_conversation_delivered{id = Delivered},
      XabberDisplayed = #xabber_conversation_displayed{id = Display},
      User = jid:to_string(jid:make(LUser,LServer)),
      UserCard = mod_channels_users:form_user_card(User,Chat),
      SubEls = [Unread, XabberDisplayed, XabberDelivered] ++ LastMessage,
      {stop,[#xabber_metadata{node = ?NS_XABBER_REWRITE, sub_els = [#xabber_conversation_retract{version = Retract}]},
        #xabber_metadata{node = ?NS_JINGLE_MESSAGE,sub_els = LastCall},
        #xabber_metadata{node = ?NS_CHANNELS, sub_els = [UserCard]},
        #xabber_metadata{node = ?NS_XABBER_SYNCHRONIZATION, sub_els = SubEls}]};
    ?NS_GROUPCHAT when IsLocal == true ->
      LastRead = get_groupchat_last_readed(PServer,PUser,LServer,LUser),
      User = jid:to_string(jid:make(LUser,LServer)),
      Chat = jid:to_string(jid:make(PUser,PServer)),
      Status = mod_groups_users:check_user_if_exist(LServer,User,Chat),
      Count = get_count_groupchat_messages(User,Chat,binary_to_integer(LastRead),Conversation,Status),
      LastMessage = get_last_groupchat_message(PServer,PUser,Status,LUser),
      LastCall = get_actual_last_call(LUser, LServer, PUser, PServer),
      Unread = #xabber_conversation_unread{count = Count, 'after' = LastRead},
      XabberDelivered = #xabber_conversation_delivered{id = Delivered},
      XabberDisplayed = #xabber_conversation_displayed{id = Display},
      User = jid:to_string(jid:make(LUser,LServer)),
      UserCard = mod_groups_users:form_user_card(User,Chat),
      SubEls = [Unread, XabberDisplayed, XabberDelivered] ++ LastMessage,
      {stop,[#xabber_metadata{node = ?NS_XABBER_REWRITE, sub_els = [#xabber_conversation_retract{version = Retract}]},
        #xabber_metadata{node = ?NS_JINGLE_MESSAGE,sub_els = LastCall},
        #xabber_metadata{node = ?NS_GROUPCHAT, sub_els = [UserCard] ++ GroupInfo},
        #xabber_metadata{node = ?NS_XABBER_SYNCHRONIZATION, sub_els = SubEls}]};
    ?NS_GROUPCHAT when IsLocal == false ->
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
        #xabber_metadata{node = ?NS_GROUPCHAT, sub_els = UserCard ++ GroupInfo},
        #xabber_metadata{node = ?NS_XABBER_SYNCHRONIZATION, sub_els = SubEls}]};
    _ when Encrypted == true ->
      Count = get_count_encrypted_messages(LServer,LUser,Conversation,binary_to_integer(Read)),
      LastMessage = get_last_encrypted_informative_message_for_chat(LServer,LUser,Conversation),
      Unread = #xabber_conversation_unread{count = Count, 'after' = Read},
      XabberDelivered = #xabber_conversation_delivered{id = Delivered},
      XabberDisplayed = #xabber_conversation_displayed{id = Display},
      SubEls = [Unread, XabberDisplayed, XabberDelivered] ++ LastMessage,
      RetractVersion = mod_retract:get_version(LServer,LUser,<<"encrypted">>),
      {stop,[#xabber_metadata{node = ?NS_XABBER_REWRITE, sub_els = [#xabber_conversation_retract{version = RetractVersion}]},
        #xabber_metadata{node = ?NS_XABBER_SYNCHRONIZATION, sub_els = SubEls}|Acc]};
    _ ->
      Count = get_count_messages(LServer,LUser,Conversation,binary_to_integer(Read)),
      LastMessage = get_last_informative_message_for_chat(LServer,LUser,Conversation),
      LastCall = get_actual_last_call(LUser, LServer, PUser, PServer),
      Unread = #xabber_conversation_unread{count = Count, 'after' = Read},
      XabberDelivered = #xabber_conversation_delivered{id = Delivered},
      XabberDisplayed = #xabber_conversation_displayed{id = Display},
      SubEls = [Unread, XabberDisplayed, XabberDelivered] ++ LastMessage,
      RetractVersion = mod_retract:get_version(LServer,LUser,<<>>),
      {stop,[#xabber_metadata{node = ?NS_XABBER_REWRITE, sub_els = [#xabber_conversation_retract{version = RetractVersion}]},
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
     order by timestamp desc NULLS LAST limit 1")) of
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
     order by timestamp desc NULLS LAST limit 1")) of
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
          update_metainfo(call, LServer,LUser,Conversation,TS,?CHAT_NS),
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

store_last_msg(Pkt, Peer, LUser, LServer, StanzaID, OriginIDRecord) ->
  case {mnesia:table_info(last_msg, disc_only_copies),
    mnesia:table_info(last_msg, memory)} of
    {[_|_], TableSize} when TableSize > ?TABLE_SIZE_LIMIT ->
      ?ERROR_MSG("Last messages too large, won't store message id for ~s@~s",
        [LUser, LServer]),
      {error, overflow};
    _ ->
      {PUser, PServer, _} = jid:tolower(Peer),
      IsService = xmpp:get_subtag(Pkt,#xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE}),
      Res = get_user_id(Pkt),
      UserID = case Res of
                 false when IsService =/= false ->
                   jid:to_string(jid:remove_resource(Peer));
                 _ ->
                   Res
               end,
      case UserID of
        false -> ok;
        _ ->
          F1 = fun() ->
            mnesia:write(
              #last_msg{us = {LUser, LServer},
                bare_peer = {PUser, PServer, <<>>},
                id = StanzaID,
                user_id = UserID,
                packet = Pkt
              })
               end,
          delete_last_msg(Peer, LUser, LServer),
          case mnesia:transaction(F1) of
            {atomic, ok} ->
              ?DEBUG("Save last msg ~p to ~p~n",[LUser,Peer]),
              OriginID = get_origin_id(OriginIDRecord),
              store_last_msg_in_counter(Peer, LUser, LServer, UserID, StanzaID, OriginID, IsService),
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

store_last_msg_in_counter(Peer, LUser, LServer, UserID, StanzaID, OriginID, false) ->
  case {mnesia:table_info(unread_msg_counter, disc_only_copies),
    mnesia:table_info(unread_msg_counter, memory)} of
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
            id = StanzaID,
            ts = time_now()
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
      {unread_msg_counter, {LUser, LServer}, {PUser, PServer,<<>>},'_','_','_','_','_'},
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

delete_msg(_LUser, _LServer, _PUser, _PServer, undefined) ->
  ok;
delete_msg(LUser, LServer, PUser, PServer, StanzaID) ->
  Msgs = get_count(LUser, LServer, PUser, PServer),
  MsgsToDelete = case [M#unread_msg_counter.ts || M <- Msgs, M#unread_msg_counter.id == StanzaID] of
                   [] ->
                     [X || X <- Msgs, X#unread_msg_counter.ts =< time_now()];
                   TSList ->
                     [X || X <- Msgs, X#unread_msg_counter.ts =< lists:max(TSList)]
                 end,
  ?DEBUG("to delete ~p~n",[MsgsToDelete]),
  lists:foreach(fun(Msg) -> mnesia:dirty_delete_object(Msg) end, MsgsToDelete).

delete_one_msg(LUser, LServer, PUser, PServer, StanzaID) ->
  Msgs = get_count(LUser, LServer, PUser, PServer),
  LastMsg = get_last_messages(LUser, LServer, PUser, PServer),
  case LastMsg of
    [#last_msg{id = StanzaID,packet = _Pkt}] ->
      lists:foreach(
        fun(LMsg) ->
          mnesia:dirty_delete_object(LMsg)
        end, LastMsg);
    _ ->
      ok
  end,
  MsgsToDelete = [X || X <- Msgs, X#unread_msg_counter.id == StanzaID],
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
      undefined
  end.

get_stanza_id(Pkt,BareJID,LServer,OriginID) ->
  case xmpp:get_subtag(Pkt, #stanza_id{}) of
    #stanza_id{by = BareJID, id = StanzaID} ->
      StanzaID;
    _ ->
      LUser = BareJID#jid.luser,
      mod_unique:get_stanza_id_by_origin_id(LServer,OriginID,LUser)
  end.

get_stanza_id_from_counter(LUser,LServer,PUser,PServer,OriginID) ->
  Msgs = get_count(LUser, LServer, PUser, PServer),
  Msg = [X || X <- Msgs, X#unread_msg_counter.origin_id == OriginID],
  SortMsg = lists:reverse(lists:keysort(#unread_msg_counter.ts,Msg)),
  case SortMsg of
    [#unread_msg_counter{id = StanzaID}| _Rest] ->
      StanzaID;
    _ ->
      undefined
  end.

get_privacy(#xabbergroupchat_privacy{cdata = Privacy}) ->
  Privacy;
get_privacy(_Privacy) ->
  <<"public">>.

update_metainfo(LServer, LUser, Conversation, undefined) ->
  F = fun () ->
    case ejabberd_sql:sql_query_t(
      ?SQL("select @(type)s,@(status)s,@(mute)d from conversation_metadata
       where username = %(LUser)s and conversation = %(Conversation)s and not encrypted and %(LServer)H" )) of
      {selected,[]} ->
        conversation_sql_upsert(LServer, LUser, Conversation , []);
      {selected,[{Type, Status, Mute}]} ->
        metainfo_sql_update(LServer, LUser, Conversation, Type, Status, Mute);
      _->
        ok
    end end,
  ejabberd_sql:sql_transaction(LServer, F);
update_metainfo(LServer, LUser, Conversation, Type) ->
  ?DEBUG("save new message ~p ~p ~p ",[LUser,Conversation,Type]),
  F = fun () ->
    case ejabberd_sql:sql_query_t(
      ?SQL("select @(status)s,@(mute)d from conversation_metadata
       where username = %(LUser)s and conversation = %(Conversation)s and type=%(Type)s ")) of
      {selected,[]} ->
        conversation_sql_upsert(LServer, LUser, Conversation , [{type, Type}]);
      {selected,[{Status, Mute}]} ->
        metainfo_sql_update(LServer, LUser, Conversation, Type, Status, Mute);
      _ ->
        error
    end end,
  ejabberd_sql:sql_transaction(LServer, F).

metainfo_sql_update(LServer, LUser, Conversation, Type, Status, Mute) ->
  TS = time_now(),
  TSSec = TS div 1000000,
  {NewStatus, NewMute} = if
                           Mute > TSSec -> {Status, Mute};
                           true -> {<<"active">>, 0}
                         end,
  ejabberd_sql:sql_query_t(
    ?SQL("update conversation_metadata set updated_at=%(TS)d, metadata_updated_at = %(TS)d,
          status=%(NewStatus)s, mute=%(NewMute)d
          where username=%(LUser)s and conversation=%(Conversation)s and type = %(Type)s and %(LServer)H")
  ).

update_type(NewType, LServer,LUser,Conversation,X) ->
  GroupInfo = case X of
                #xabbergroupchat_x{} ->
                  Privacy = get_privacy(xmpp:get_subtag(X, #xabbergroupchat_privacy{})),
                  case X#xabbergroupchat_x.parent of
                    undefined -> Privacy;
                    Parent -> <<Privacy/binary,$,,(jid:to_string(Parent))/binary>>
                  end;
                _-> <<>>
              end,
  TS = time_now(),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata
     set type = %(NewType)s, metadata_updated_at = %(TS)d, group_info = %(GroupInfo)s
     where username=%(LUser)s and conversation=%(Conversation)s and type != %(NewType)s and %(LServer)H")
  ).

update_metainfo(_Any, _LServer,_LUser,_Conversation, undefined,_Type) ->
  ?DEBUG("No id in displayed",[]),
  ok;
update_metainfo(call, LServer,LUser,Conversation,_StanzaID, Type) ->
  ?DEBUG("save new call ~p ~p ",[LUser,Conversation]),
  TS = time_now(),
  ?SQL_UPSERT(
    LServer,
    "conversation_metadata",
    ["!username=%(LUser)s",
      "!conversation=%(Conversation)s",
      "!type=%(Type)s",
      "metadata_updated_at=%(TS)d",
      "server_host=%(LServer)s"]);
update_metainfo(delivered, LServer,LUser,Conversation,StanzaID,Type) ->
  ?DEBUG("save delivered ~p ~p ~p",[LUser,Conversation,StanzaID]),
  TS = time_now(),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set metadata_updated_at = %(TS)d, delivered_until = %(StanzaID)s
    where username=%(LUser)s and conversation=%(Conversation)s and type = %(Type)s
     and delivered_until::bigint <= %(StanzaID)d and %(LServer)H")
  );
update_metainfo(read, LServer,LUser,Conversation,StanzaID,undefined) ->
  TS = time_now(),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set metadata_updated_at = %(TS)d, read_until = %(StanzaID)s
    where username=%(LUser)s and conversation=%(Conversation)s and not encrypted
     and read_until::bigint <= %(StanzaID)d  and %(LServer)H")
  );
update_metainfo(read, LServer,LUser,Conversation,StanzaID,Type) ->
  TS = time_now(),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set metadata_updated_at = %(TS)d, read_until = %(StanzaID)s
    where username=%(LUser)s and conversation=%(Conversation)s and type = %(Type)s
     and read_until::bigint <= %(StanzaID)d and %(LServer)H")
  );
update_metainfo(displayed, LServer,LUser,Conversation,StanzaID,Type) ->
  ?DEBUG("save displayed ~p ~p ~p",[LUser,Conversation,StanzaID]),
  TS = time_now(),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set metadata_updated_at = %(TS)d, displayed_until = %(StanzaID)s
    where username=%(LUser)s and conversation=%(Conversation)s and type = %(Type)s and
     displayed_until::bigint <= %(StanzaID)d and %(LServer)H")
  ).

-spec get_conversation_type(binary(),binary(),binary()) -> list() | error.
get_conversation_type(LServer,LUser,Conversation) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(type)s
     from conversation_metadata"
    " where username=%(LUser)s and conversation=%(Conversation)s and %(LServer)H")) of
    {selected,[]} -> [];
%%    {selected,[{Type}]} -> Type;
    {selected, List} -> [T || {T} <- List];
    _ -> error
  end.

update_group_retract(LServer,LUser,Conversation,NewVersion,Stanza) ->
  TS = time_now(),
  Type = ?NS_GROUPCHAT,
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set
    retract = %(NewVersion)d, metadata_updated_at = %(TS)d
     where username=%(LUser)s and conversation=%(Conversation)s and type =%(Type)s
      and retract < %(NewVersion)d and %(LServer)H")) of
    {updated,1} ->
      maybe_push_notification(LUser,LServer,Conversation,Type,<<"update">>,xmpp:decode(Stanza)),
      ok;
    _Other ->
      not_ok
  end.

update_retract(LServer,LUser,Conversation,NewVersion,RetractType,TS) ->
%%  TS = time_now(),
  case RetractType of
    <<"encrypted">> ->
      case ejabberd_sql:sql_query(
        LServer,
        ?SQL("update conversation_metadata set
    retract = %(NewVersion)d, metadata_updated_at = %(TS)d
     where username=%(LUser)s and conversation=%(Conversation)s and encrypted='true' and retract < %(NewVersion)d and %(LServer)H")) of
        {updated,1} ->
          ok;
        _Other ->
          error
      end;
    _ ->
      case ejabberd_sql:sql_query(
        LServer,
        ?SQL("update conversation_metadata set
    retract = %(NewVersion)d, metadata_updated_at = %(TS)d
     where username=%(LUser)s and conversation=%(Conversation)s and encrypted='false' and retract < %(NewVersion)d and %(LServer)H")) of
        {updated,1} ->
          ok;
        _Other ->
          error
      end
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
    " where username=%(LUser)s and bare_peer=%(PUser)s and %(LServer)H and txt notnull and txt !='' order by timestamp desc NULLS LAST limit 1")) of
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
    " where username=%(LUser)s and bare_peer=%(PUser)s and timestamp < %(TS)d and txt notnull and txt !='' and %(LServer)H order by timestamp desc NULLS LAST limit 1")) of
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

get_last_groupchat_message(LServer,LUser,<<"both">>,User) ->
  Chat = jid:to_string(jid:make(LUser,LServer)),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(timestamp)d, @(xml)s, @(peer)s, @(kind)s, @(nick)s
     from archive"
    " where username=%(LUser)s  and txt notnull and txt !='' and %(LServer)H order by timestamp desc NULLS LAST limit 1")) of
    {selected,[{TS, XML, Peer, Kind, Nick}]} ->
      convert_message(TS, XML, Peer, Kind, Nick, LUser, LServer);
    _ ->
      get_invite(LServer,User,Chat)
  end;
get_last_groupchat_message(LServer,LUser,_Status,User) ->
  Chat = jid:to_string(jid:make(LUser,LServer)),
  get_invite(LServer,User,Chat).

get_invite(LServer,LUser,Chat) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(timestamp)d
     from special_messages"
    " where username=%(LUser)s and conversation = %(Chat)s and type = 'invite' and %(LServer)H order by timestamp desc  NULLS LAST limit 1")) of
    {selected,[<<>>]} ->
      [];
    {selected,[{TS}]} ->
      case ejabberd_sql:sql_query(
        LServer,
        ?SQL("select
    @(timestamp)d, @(xml)s, @(peer)s, @(kind)s, @(nick)s
     from archive"
        " where username = %(LUser)s and timestamp = %(TS)d and %(LServer)H order by timestamp desc NULLS LAST limit 1")) of
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
    " where username=%(LUser)s and conversation = %(Conversation)s and type = 'reject' and %(LServer)H order by timestamp desc NULLS LAST limit 1")) of
    {selected,[<<>>]} ->
      {0,[]};
    {selected,[{TS}]} ->
      case ejabberd_sql:sql_query(
        LServer,
        ?SQL("select
    @(timestamp)d, @(xml)s, @(peer)s, @(kind)s, @(nick)s
     from archive"
        " where username = %(LUser)s and timestamp = %(TS)d and %(LServer)H order by timestamp desc NULLS LAST limit 1")) of
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


get_count_groupchat_messages(BareUser,Chat,TS,Conversation,<<"both">>) ->
  {ChatUser, ChatServer, _ } = jid:tolower(jid:from_string(Chat)),
  case ejabberd_sql:sql_query(
    ChatServer,
    ?SQL("select
    @(count(*))d
     from archive"
    " where username=%(ChatUser)s  and txt notnull and txt !='' and bare_peer not in (%(BareUser)s,%(Chat)s) and timestamp > %(TS)d and timestamp not in (select timestamp from special_messages where conversation = %(Conversation)s and %(ChatServer)H ) and %(ChatServer)H")) of
    {selected,[{Count}]} ->
      Count;
    _ ->
      0
  end;
get_count_groupchat_messages(_LServer,_LUser,_TS,_Conversation,_Status) ->
  0.

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
  {Type1, StanzaID} = if
                        Type == ?NS_GROUPCHAT ->
                          Displayed2= filter_packet(Displayed,PeerJID),
                          {Type, get_stanza_id(Displayed2,PeerJID,LServer,OriginID)};
                        Type =/= undefined ->
                          Displayed2 = filter_packet(Displayed,BareJID),
                          {Type, get_stanza_id(Displayed2,BareJID,LServer,OriginID)};
                        true ->
                          Displayed2 = filter_packet(Displayed,BareJID),
                          SID = get_stanza_id(Displayed2,BareJID,LServer,OriginID),
                          case mod_mam_sql:is_encrypted(LServer,SID) of
                            {true, NS} -> {NS, SID};
                            _-> {?CHAT_NS, SID}
                          end
                      end,
  update_metainfo(displayed, LServer,LUser,Conversation,StanzaID,Type1);
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
      update_metainfo(delivered, LServer,LUser,Conversation,StanzaID1,NS);
    _ ->
      update_metainfo(delivered, LServer,LUser,Conversation,StanzaID1,?CHAT_NS)
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
  delete_one_msg(LUser, LServer, PUser, PServer, integer_to_binary(StanzaID)),
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
  Conversation = jid:to_string(ConversationJID),
  case update_group_retract(LServer,LUser,Conversation,Version,Retract) of
    ok ->
      delete_user_msg(LUser, LServer, PUser, PServer, UserID);
    _ ->
      ok
  end;
handle_sub_els(headline, [
  #xabber_retract_all{type = Type, version = Version,
  conversation = ConversationJID} = Retract], _From, To)
  when ConversationJID =/= undefined andalso Version =/= undefined ->
  #jid{luser = LUser, lserver = LServer} = To,
  #jid{luser = PUser, lserver = PServer} = ConversationJID,
  Conversation = jid:to_string(ConversationJID),
  TS = time_now(),
  case update_retract(LServer,LUser,Conversation,Version,Type,TS) of
    ok ->
      delete_all_msgs(LUser, LServer, PUser, PServer),
      send_push_about_retract(LServer,LUser,Conversation,Retract,Type,TS);
    _ ->
      pass
  end,
  ok;
handle_sub_els(headline, [#xabber_replace{version = undefined, conversation = _ConversationJID} = _Retract],
    _From, _To) ->
  ok;
handle_sub_els(headline, [#xabber_replace{type = Type, version = Version, conversation = ConversationJID} = Replace],
    _From, To) ->
  #jid{luser = LUser, lserver = LServer} = To,
  Conversation = jid:to_string(ConversationJID),
  maybe_change_last_msg(LServer, LUser, ConversationJID, Replace),
  TS = time_now(),
  case update_retract(LServer,LUser,Conversation,Version,Type,TS) of
    ok ->
      send_push_about_retract(LServer,LUser,Conversation,Replace,Type,TS);
    _->
      pass
  end,
  ok;
%%handle_sub_els(headline, [#xabbergroupchat_replace{version = Version} = Retract], _From, To) ->
%%  #jid{luser = LUser, lserver = LServer} = To,
%%  ok;
handle_sub_els(headline, [#delivery_x{ sub_els = [Message]}], From, To) ->
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
      update_metainfo(read, LServer,LUser,Conversation,StanzaID,?NS_GROUPCHAT);
    _ ->
      pass
  end,
  update_metainfo(delivered, LServer,LUser,Conversation,StanzaID,?NS_GROUPCHAT),
  ok;
handle_sub_els(_Type, _SubEls, _From, _To) ->
  ok.

%%%===================================================================
%%% Check VoIP message
%%%===================================================================
check_voip_msg(#message{id = ID, type = chat,
  from = From, to = To, meta = #{stanza_id := TS}} = Pkt)->
  Propose = xmpp:get_subtag(Pkt, #jingle_propose{}),
  Accept = xmpp:get_subtag(Pkt, #jingle_accept{}),
  Reject = xmpp:get_subtag(Pkt, #jingle_reject{}),
  {LUser, LServer, _ } = jid:tolower(To),
  Conversation = jid:to_string(jid:remove_resource(From)),
  if
    is_record(Propose, jingle_propose) ->
      maybe_push_notification(LUser,LServer,<<"call">>,Pkt),
      store_special_message_id(LServer,LUser,Conversation,TS,ID,<<"call">>),
      update_metainfo(call, LServer,LUser,Conversation,TS,?CHAT_NS),
      store_last_call(Pkt, From, LUser, LServer, TS),
      true;
    is_record(Accept, jingle_accept) ->
      store_special_message_id(LServer,LUser,Conversation,TS,ID,<<"accept">>),
      maybe_push_notification(LUser,LServer,<<"data">>,Accept),
      update_metainfo(call, LServer,LUser,Conversation,TS,?CHAT_NS),
      delete_last_call(From, LUser, LServer),
      true;
    is_record(Reject, jingle_reject) ->
      store_special_message_id(LServer,LUser,Conversation,TS,ID,<<"reject">>),
      maybe_push_notification(LUser,LServer,<<"data">>,Reject),
      update_metainfo(call, LServer,LUser,Conversation,TS,?CHAT_NS),
      delete_last_call(From, LUser, LServer),
      true;
    true ->
      false
  end.

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

time_now() ->
  {MSec, Sec, USec} = erlang:timestamp(),
  (MSec*1000000 + Sec)*1000000 + USec.

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
          <<" GROUP BY conversation, retract, type, conversation_thread, read_until, delivered_until, displayed_until,
  updated_at, status, encrypted, pinned, mute, group_info ORDER BY updated_at ASC ">>,
          LimitClause, <<") AS c ORDER BY ">>, PinnedFirstClause ,<<" updated_at DESC;">>];
      _ ->
        [Query, <<" GROUP BY conversation, retract, type, conversation_thread, read_until,
        delivered_until,  displayed_until, updated_at, status, encrypted, pinned, mute, group_info
        ORDER BY ">>, PinnedFirstClause ,<<" updated_at DESC ">>,
          LimitClause, <<";">>]
    end,
  case ejabberd_sql:use_new_schema() of
    true ->
      {QueryPage,[<<"SELECT COUNT(*) FROM (">>,Conversations,<<" and server_host='">>,
        SServer, <<"' ">>,
        <<" GROUP BY conversation, retract, type, conversation_thread, read_until, delivered_until,
        displayed_until, updated_at, status, encrypted, pinned, mute, group_info) as subquery;">>]};
    false ->
      {QueryPage,[<<"SELECT COUNT(*) FROM (">>,Conversations,
        <<" GROUP BY conversation, retract, type, conversation_thread, read_until, delivered_until,
        displayed_until, updated_at, status, encrypted, pinned, mute, group_info) as subquery;">>]}
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
    ?SQL("update conversation_metadata set pinned=%(Num)d, metadata_updated_at=%(TS)d
     where username = %(LUser)s and conversation = %(Conversation)s and type = %(Type)s and status!='deleted'
      and conversation_thread = %(Thread)s")) of
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

mute_conversation(LServer, LUser, #xabber_conversation{type = Type, jid = ConvJID, thread = Thread, mute = Mute}) ->
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
    ?SQL("update conversation_metadata set mute=%(SetMute)d, metadata_updated_at=%(TS)d
     where username = %(LUser)s and conversation = %(Conversation)s and type = %(Type)s and status!='deleted'
      and conversation_thread = %(Thread)s")) of
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
      ?SQL("update conversation_metadata set status = 'archived', metadata_updated_at=%(TS)d
       where username = %(LUser)s and conversation = %(Conversation)s and type = %(Type)s
        and status!='deleted' and conversation_thread = %(Thread)s")) of
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
    ?SQL("update conversation_metadata set status = 'active', metadata_updated_at=%(TS)d
     where username = %(LUser)s and conversation = %(Conversation)s  and type = %(Type)s and status!='deleted'
      and conversation_thread = %(Thread)s")) of
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

delete_conversation(LServer,LUser,#xabber_conversation{type = Type, jid = JID}) ->
  Conversation = jid:to_string(jid:remove_resource(JID)),
  TS = time_now(),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("update conversation_metadata set status = 'deleted',
     updated_at=%(TS)d, metadata_updated_at=%(TS)d
      where username = %(LUser)s and conversation = %(Conversation)s and type = %(Type)s")) of
    {updated,0} ->
      {error,xmpp:err_item_not_found()};
    {updated,_N} ->
      make_sync_push(LServer,LUser,Conversation,TS,Type),
      ok;
    _ ->
      {error,xmpp:err_internal_server_error()}
  end;
delete_conversation(_,_,_) ->
  {error,xmpp:err_bad_request()}.

is_muted(LUser,LServer, Conversation, Type) ->
  Now = time_now() div 1000000,
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @('true')b
       from conversation_metadata where username = %(LUser)s and conversation = %(Conversation)s
    and type = %(Type)s and mute > %(Now)d")) of
    {selected,[{Result}]} -> Result;
    _ -> false
  end.

maybe_push_notification(LUser, LServer, PushType, PushPayload)->
  Proc = gen_mod:get_module_proc(LServer, ?MODULE),
  gen_server:cast(Proc, {send_push, LUser, LServer, PushType, PushPayload}).

maybe_push_notification(LUser, LServer, Conversation, CType, PushType, PushPayload)
  when <<LUser/binary,$@,LServer/binary>> /= Conversation ->
  case mod_xabber_entity:get_entity_type(LUser,LServer) of
    user ->
      Proc = gen_mod:get_module_proc(LServer, ?MODULE),
      gen_server:cast(Proc, {send_push, LUser, LServer, Conversation,CType, PushType, PushPayload});
    _ ->
      pass
  end;
maybe_push_notification(_, _, _, _, _, _) ->
  %%  ignore notifications from yourself
  pass.

send_push_about_retract(LServer,LUser,Conversation,PushPayload,RetractType,TS) ->
  CType = case RetractType of
            <<"encrypted">> ->
              ?NS_OMEMO;
            _ ->
              case get_conversation_type(LServer,LUser,Conversation) of
                [T] -> T;
                _-> ?CHAT_NS
              end
          end,
  make_sync_push(LServer,LUser,Conversation, TS, CType),
  maybe_push_notification(LUser,LServer,Conversation,CType,<<"update">>,xmpp:decode(PushPayload)).

%% invite logic

store_invite_information(LUser,LServer,PUser,PServer, ID) ->
  NewInvite = #invite_msg{us = {LUser,LServer}, bare_peer = {PUser,PServer,<<>>}, id = ID},
  mnesia:dirty_write(NewInvite).

get_invite_information(LUser,LServer,PUser,PServer) ->
  FN = fun()->
    mnesia:match_object(invite_msg,
      {invite_msg, {LUser, LServer}, {PUser, PServer,<<>>}, '_'},
      read)
       end,
  {atomic,MsgRec} = mnesia:transaction(FN),
  MsgRec.

maybe_delete_invite_and_conversation(LUser,LServer,PUser,PServer) ->
  Conversation = jid:to_string(jid:make(PUser,PServer)),
  Type = get_conversation_type(LServer,LUser,Conversation),
  case Type of
    [?NS_GROUPCHAT] ->
      Invites = get_invite_information(LUser,LServer,PUser,PServer),
      lists:foreach(fun(Invite) ->
        delete_invite(Invite) end, Invites
      ),
      delete_conversation(LServer,LUser,#xabber_conversation{jid = jid:make(PUser,PServer), type = ?NS_GROUPCHAT});
    _ ->
      ok
  end.

delete_old_invites(LUser,LServer,PUser,PServer) ->
  Invites = get_invite_information(LUser,LServer,PUser,PServer),
  lists:foreach(fun(Invite) ->
    delete_invite(Invite) end, Invites
  ).

delete_invite(#invite_msg{us = {LUser,LServer}, id = ID} = Invite) ->
  mod_retract:delete_message(LServer, LUser, ID),
  mnesia:dirty_delete_object(Invite).

make_sync_push(LServer,LUser,Conversation, TS, Type) ->
  case get_conversation_info(LServer,LUser,Conversation,Type) of
    {error, Why} ->
      ?ERROR_MSG("Get conversation info error: ~p;"
      " user:~p, conversation:~p, type:~p",[Why, {LUser,LServer}, Conversation,Type]);
    CnElem ->
      UserResources = ejabberd_sm:user_resources(LUser,LServer),
      Query = #xabber_synchronization_query{stamp = integer_to_binary(TS), sub_els = [CnElem]},
      lists:foreach(fun(Res) ->
        From = jid:make(LUser,LServer),
        To = jid:make(LUser,LServer,Res),
        IQ = #iq{from = From, to = To, type = set, id = randoms:get_string(), sub_els = [Query]},
        ejabberd_router:route(IQ)
                    end, UserResources)
  end.

create_conversation(LServer,LUser,Conversation,Thread,Encrypted,Type,GroupInfo) ->
  F = fun() ->
    Options = [{type, Type}, {thread, Thread}, {encrypted, Encrypted}, {'group_info', GroupInfo}],
    conversation_sql_upsert(LServer, LUser, Conversation , Options)
    end,
  ejabberd_sql:sql_transaction(LServer, F).

conversation_sql_upsert(LServer, LUser, Conversation , Options) ->
  Type = proplists:get_value(type, Options, ?CHAT_NS),
  Thread = proplists:get_value(thread, Options, <<"">>),
  Encrypted = proplists:get_value(encrypted, Options, false),
  GroupInfo = proplists:get_value('group_info', Options, <<"">>),
  Status = proplists:get_value('status', Options, <<"active">>),
  TS = time_now(),
  ?SQL_UPSERT_T(
    "conversation_metadata",
    ["!username=%(LUser)s",
      "!conversation=%(Conversation)s",
      "!type=%(Type)s",
      "updated_at=%(TS)d",
      "conversation_thread=%(Thread)s",
      "metadata_updated_at=%(TS)d",
      "status=%(Status)s",
      "group_info=%(GroupInfo)s",
      "encrypted=%(Encrypted)b",
      "server_host=%(LServer)s"]).

get_and_store_user_card(LServer,LUser,PeerJID,Message) ->
  X = xmpp:get_subtag(Message,#xabbergroupchat_x{xmlns = ?NS_GROUPCHAT}),
  Ch_X = xmpp:get_subtag(Message,#channel_x{xmlns = ?NS_CHANNELS}),
  maybe_store_card(LServer,LUser,PeerJID,#xabbergroupchat_user_card{},X),
  maybe_store_card(LServer,LUser,PeerJID,#channel_user_card{},Ch_X).

maybe_store_card(_LServer,_LUser,_PeerJID, _Type, false) ->
  ok;
maybe_store_card(LServer,LUser,PeerJID, CardType, X) ->
  Ref = xmpp:get_subtag(X,#xmppreference{}),
  case Ref of
    false -> ok;
    _ ->
      Card = xmpp:get_subtag(Ref, CardType),
      case Card of
        false -> ok;
        _ ->
          store_card(LServer,LUser,PeerJID,Card)
      end
  end.


store_card(LServer,LUser,Peer,Pkt) ->
  case {mnesia:table_info(user_card, disc_only_copies),
    mnesia:table_info(user_card, memory)} of
    {[_|_], TableSize} when TableSize > ?TABLE_SIZE_LIMIT ->
      ?ERROR_MSG("user_card table too large, won't store card ~s@~s",
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
      delete_user_cards(Peer, LUser, LServer),
      case mnesia:transaction(F1) of
        {atomic, ok} -> ok;
        {aborted, Err} ->
          ?ERROR_MSG("Cannot store card for ~s@~s: ~s", [LUser, LServer, Err]), Err
      end
  end.

delete_user_cards(Peer, LUser, LServer) ->
  {PUser, PServer,_R} = jid:tolower(Peer),
  Msgs = get_user_cards(LUser, LServer, PUser, PServer),
  lists:foreach(
    fun(Msg) ->
      mnesia:dirty_delete_object(Msg)
    end, Msgs).

get_user_cards(LUser, LServer, PUser, PServer) ->
  FN = fun()->
    mnesia:match_object(user_card,
      {user_card, {LUser, LServer}, {PUser, PServer,<<>>}, '_'},
      read)
       end,
  {atomic,MsgRec} = mnesia:transaction(FN),
  MsgRec.

get_user_card(LUser, LServer, PUser, PServer) ->
  case get_user_cards(LUser, LServer, PUser, PServer) of
    [] ->
      [];
    [F|_R] ->
      #user_card{packet = Pkt} = F,
      [Pkt]
  end.

body_is_encrypted(Pkt) ->
  SubEls = xmpp:get_els(Pkt),
  Patterns = [<<"urn:xmpp:otr">>, <<"urn:xmpp:omemo">>],
  lists:foldl(fun(El, Acc0) ->
    NS0 = xmpp:get_ns(El),
    NS1 = lists:foldl(fun(P, Acc1) ->
      case binary:match(NS0,P) of
        nomatch -> Acc1;
        _ -> NS0
      end  end, none, Patterns),
    if
      NS1 == none-> Acc0;
      true -> {true, NS1}
    end
              end, false, SubEls).

maybe_change_last_msg(LServer, LUser, ConversationJID, Replace) ->
  {PUser, PServer, _PRes} = jid:tolower(ConversationJID),
  ReplaceID = Replace#xabber_replace.id,
  M = get_last_message_with_timestamp(LUser, LServer, PUser, PServer, ReplaceID),
  case M of
    false -> ok;
    _ ->
      #xabber_replace{ xabber_replace_message = XabberReplaceMessage} = Replace,
      #xabber_replace_message{body = Text, sub_els = NewEls} = XabberReplaceMessage,
      MD = xmpp:decode(M),
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
      MessageDecoded = MD#message{sub_els = Els2, body = NewBody},
      change_last_msg(MessageDecoded, ConversationJID, LUser, LServer,ReplaceID)
  end.

get_last_message_with_timestamp(LUser, LServer, PUser, PServer, Timestamp) ->
  TS = case is_integer(Timestamp) of
         true ->
           integer_to_binary(Timestamp);
         _ ->
           Timestamp
       end,
  FN = fun()->
    mnesia:match_object(last_msg,
      {last_msg, {LUser, LServer}, {PUser, PServer,<<>>},'_','_','_'},
      read)
       end,
  {atomic,MsgRec} = mnesia:transaction(FN),
  case MsgRec of
    [] ->
      false;
    _ ->
      SortFun = fun(E1,E2) -> ID1 = binary_to_integer(E1#last_msg.id), ID2 = binary_to_integer(E2#last_msg.id), ID1 > ID2 end,
      MsgSort = lists:sort(SortFun,MsgRec),
      [Msg|_Rest] = MsgSort,
      #last_msg{packet = Packet, id = ID} = Msg,
      case ID of
        TS ->
          Packet;
        _ ->
          false
      end
  end.

change_last_msg(Pkt, Peer, LUser, LServer, Timestamp) ->
  case {mnesia:table_info(last_msg, disc_only_copies),
    mnesia:table_info(last_msg, memory)} of
    {[_|_], TableSize} when TableSize > ?TABLE_SIZE_LIMIT ->
      ?ERROR_MSG("Last messages too large, won't store message id for ~s@~s",
        [LUser, LServer]),
      {error, overflow};
    _ ->
      TS = case is_integer(Timestamp) of
             true ->
               integer_to_binary(Timestamp);
             _ ->
               Timestamp
           end,
      {PUser, PServer, _} = jid:tolower(Peer),
      IsService = xmpp:get_subtag(Pkt,#xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE}),
      Res = get_user_id(Pkt),
      UserID = case Res of
                 false when IsService =/= false ->
                   jid:to_string(jid:remove_resource(Peer));
                 _ ->
                   Res
               end,
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
              ok;
            {aborted, Err1} ->
              ?DEBUG("Cannot add last msg for ~s@~s: ~s",
                [LUser, LServer, Err1]),
              Err1
          end
      end
  end.

-spec update_mam_prefs(atom(), jid(), jid()) -> stanza() | error.
update_mam_prefs(_Action, User, User) ->
%%  skip for myself
  ok;
update_mam_prefs(Action, User, Contact) ->
  case get_mam_prefs(User) of
    #mam_prefs{never=Never0} = Prefs ->
      Never1 = case Action of
                 add -> Never0 ++ [Contact];
                 _ ->
                   L1 = lists:usort([jid:tolower(jid:remove_resource(J)) || J <- Never0]),
                   L2 = L1 -- [jid:tolower(Contact)],
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

get_mam_prefs(#jid{lserver = LServer} = User) ->
  IQ = #iq{from = User,
    to = #jid{lserver = LServer},
    type = get, sub_els = [#mam_prefs{xmlns = ?NS_MAM_2}]},
  case mod_mam:pre_process_iq_v0_3(IQ) of
    #iq{type = result, sub_els = [#mam_prefs{} = Prefs]} ->
      Prefs;
    _ ->
      error
  end.

update_table(unread_msg_counter) ->
%%  For updating old installations
%%  It works only when starting in debug shell
  Transformer1 = fun({_V1, V2, V3 ,V4, V5, V6, V7}) -> {old_unread_msg_counter, V2, V3 ,V4, V5, V6, V7} end,
  Transformer2 = fun({_V1, V2, V3 ,V4, V5, V6, V7}) -> {unread_msg_counter, V2, V3 ,V4, V5, V6, V7, V7} end,
    {atomic, ok} = mnesia:transform_table(unread_msg_counter, Transformer1,
      record_info(fields, old_unread_msg_counter),
      old_unread_msg_counter),
    {atomic, ok} = mnesia:transform_table(unread_msg_counter, Transformer2,
      record_info(fields, unread_msg_counter),
      unread_msg_counter);
update_table(_) ->
  ok.
