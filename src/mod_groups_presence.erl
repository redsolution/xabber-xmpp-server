%%%-------------------------------------------------------------------
%%% File    : mod_groups_presence.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Work with presence in group chats
%%% Created : 17 May 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_groups_presence).
-author('andrey.gagarin@redsolution.com').
-behavior(gen_mod).
-behavior(gen_server).
-include("logger.hrl").
-include("xmpp.hrl").
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2]).
-export([start/2, stop/1, depends/2, mod_options/1]).
-export([
         form_presence/2, form_presence/1,
         form_presence_unavailable/0,
         form_unsubscribe_presence/0,
         form_unsubscribed_presence/0,
         process_presence/1,
  send_info_to_index/2, get_global_index/1, send_message_to_index/2,
  chat_created/4, groupchat_changed/5, send_presence/3,
  change_present_state/2, revoke_invite/2
        ]).
-export([
  get_present/1,
  select_sessions/2,
  delete_all_user_sessions/2]).

%% records
-type state() :: map().
-export_type([state/0]).

-record(presence_state, {host = <<"">> :: binary()}).
-record(participant_session, {group, username, server, resource, ts}).

start(Host, Opts) ->
  gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
  gen_mod:stop_child(?MODULE, Host).

depends(_Host, _Opts) ->  [].

mod_options(_Host) -> [].

init([Host, _Opts]) ->
  register_hooks(Host),
  ejabberd_mnesia:create(?MODULE, participant_session,
    [{ram_copies, [node()]},
      {attributes, record_info(fields, participant_session)},
      {type, bag}]),
  Hosts = lists:sort(ejabberd_config:get_myhosts()),
  %% run task once for all hosts
  case Hosts of
    [Host | _] ->
      erlang:send_after(3600000, %% 60 minutes
        self(), 'delete_zombie_sessions');
    _ ->
      ok
  end,
  {ok, #presence_state{host = Host}}.

terminate(_Reason, State) ->
  Host = State#presence_state.host,
  unregister_hooks(Host).

register_hooks(Host) ->
  ejabberd_hooks:add(groupchat_created, Host, ?MODULE, chat_created, 15),
  ejabberd_hooks:add(revoke_invite, Host, ?MODULE, revoke_invite, 10),
  ejabberd_hooks:add(groupchat_properties_changed, Host, ?MODULE, groupchat_changed, 10).

unregister_hooks(Host) ->
  ejabberd_hooks:delete(groupchat_created, Host, ?MODULE, chat_created, 15),
  ejabberd_hooks:delete(revoke_invite, Host, ?MODULE, revoke_invite, 10),
  ejabberd_hooks:delete(groupchat_properties_changed, Host, ?MODULE, groupchat_changed, 10).

handle_call(_Request, _From, _State) ->
  erlang:error(not_implemented).

handle_cast(#presence{to = To} = Presence, State) ->
  Server = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  process_presence(mod_groups_chats:get_chat_active(Server,Chat),Presence),
  {noreply, State};
handle_cast(_Request, State) ->
  {noreply, State}.

handle_info('delete_zombie_sessions', State) ->
  kill_zombies(),
  erlang:send_after(1200000, %% 20 minutes
    self(), 'delete_zombie_sessions'),
  {noreply, State};

handle_info(_Info, State) ->
  {noreply, State}.

%%delete_session_from_counter_after(GroupJID, UserJID, Timeout) ->
%%  timer:sleep(Timeout),
%%%%  checking if the group was deleted
%%  case ejabberd_sm:get_session_sid(GroupJID#jid.luser, GroupJID#jid.lserver, <<"Group">>) of
%%    none ->
%%      ok;
%%    _ ->
%%      Resource = UserJID#jid.lresource,
%%      Server = GroupJID#jid.lserver,
%%      Chat = jid:to_string(jid:remove_resource(GroupJID)),
%%      Username = jid:to_string(jid:remove_resource(UserJID)),
%%      PresentNum = get_present(Chat),
%%      Ss = select_session(Resource,Username,Chat),
%%      lists:foreach(fun(S) -> mnesia:dirty_delete_object(S) end, Ss),
%%      mod_groups_users:update_last_seen(Server,Username,Chat),
%%      send_notification(UserJID, GroupJID, PresentNum, not_present)
%%  end.

revoke_invite(Chat,User) ->
  ChatJID = jid:from_string(Chat),
  FromChat = jid:replace_resource(ChatJID,<<"Group">>),
  UserJID = jid:from_string(User),
  Presence = #presence{from = FromChat, to = UserJID, type = unsubscribe, id = randoms:get_string()},
  ejabberd_router:route(Presence).

groupchat_changed(LServer, Chat, _User, ChatProperties, Status) ->
  ChatJID = jid:from_string(Chat),
  FromChat = jid:replace_resource(ChatJID,<<"Group">>),
  Users = mod_groups_users:user_list_to_send(LServer,Chat),
  case Status of
    <<"inactive">> ->
      delete_all_sessions(Chat),
      send_presence(form_presence_unavailable(Chat),Users,FromChat);
    _ ->
      {HumanStatus, Show} = mod_groups_chats:define_human_status_and_show(LServer, Chat, Status),
      send_presence(form_presence(Chat,Show,HumanStatus),Users,FromChat)
  end,
  maybe_send_to_index(LServer, Chat, ChatProperties).

maybe_send_to_index(LServer, Chat, ChatProperties) ->
  IsIndexChanged = proplists:get_value(global_indexing_changed, ChatProperties),
  case IsIndexChanged of
    true ->
      send_presence_to_index(LServer, Chat);
    _ ->
      send_info_to_index(LServer,Chat)
  end.

send_presence(_Message,[],_From) ->
  ok;
send_presence(Message,Users,From) ->
  [{User}|RestUsers] = Users,
  To = jid:from_string(User),
  ejabberd_router:route(From,To,Message),
  send_presence(Message,RestUsers,From).

chat_created(LServer,User,Chat,_Lang) ->
  Presence = form_presence_with_type(LServer, User, Chat, subscribe),
  Presence2 = form_presence_with_type(LServer, User, Chat, subscribed),
  ejabberd_router:route(Presence2),
  ejabberd_router:route(Presence).

form_presence_with_type(LServer, User, Chat, Type) ->
  ChatJID = jid:from_string(Chat),
  send_info_to_index(LServer,Chat),
  From = jid:replace_resource(ChatJID,<<"Group">>),
  To = jid:from_string(User),
  {selected,[{Name,Anonymous,_Search,_Model,_Desc,_Message,_ContactList,_DomainList,ParentChat,Status}]} =
    mod_groups_chats:get_all_information_chat(Chat,LServer),
  Members = mod_groups_chats:count_users(LServer,Chat),
  {CollectState,P2PState} = mod_groups_inspector:get_collect_state(Chat,User),
  Hash = mod_groups_inspector:get_chat_avatar_id(Chat),
  VcardX = #vcard_xupdate{hash = Hash},
  SubEls = case ParentChat of
             <<"0">> ->
               [
                 #xabbergroupchat_x{
                   xmlns = ?NS_GROUPCHAT,
                   members = Members,
                   sub_els = [
                     #xabbergroupchat_name{cdata = Name},
                     #xabbergroupchat_privacy{cdata = Anonymous},
                     #collect{cdata = CollectState},
                     #xabbergroup_peer{cdata = P2PState}
                   ]
                 },
                 VcardX
               ];
             _ ->
               [
                 #xabbergroupchat_x{
                   xmlns = ?NS_GROUPCHAT,
                   members = Members,
                   parent = jid:from_string(ParentChat),
                   sub_els = [
                     #xabbergroupchat_name{cdata = Name},
                     #xabbergroupchat_privacy{cdata = Anonymous}
                   ]
                 },
                 VcardX
               ]
           end,
  {HumanStatus, Show} = case ParentChat of
                  <<"0">> ->
                    mod_groups_chats:define_human_status_and_show(LServer, Chat, Status);
                  _ ->
                    {[#text{data = <<"Private chat">>}],undefined}
                end,
  #presence{from = From, to = To, type = Type, id = randoms:get_string(), sub_els = SubEls, status = HumanStatus, show = Show}.

process_presence(#presence{to=To} = Presence) ->
  Server = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  process_presence(mod_groups_chats:get_chat_active(Server,Chat),Presence).

process_presence({selected,[]},Packet) ->
  Packet;
process_presence(false, Packet) ->
  Packet;
process_presence(<<"inactive">>, _Packet) ->
  drop;
process_presence(_,Packet) ->
  answer_presence(Packet).

is_chat(Sub) ->
  case lists:keyfind(xabbergroupchat_x,1,Sub) of
     false ->
       false;
    _ ->
      true
  end.


search_for_hash(Hash) ->
 case Hash of
   false ->
     undefined;
   _ ->
     Hash#vcard_xupdate.hash
 end.

answer_presence(#presence{to = To, from = From, type = available} = Presence) ->
  DecodedPresence = xmpp:decode_els(Presence),
  Decoded = DecodedPresence#presence.sub_els,
  case is_chat(Decoded) of
    true ->
      Server = To#jid.lserver,
      Chat = jid:to_string(jid:remove_resource(To)),
      User = jid:to_string(jid:remove_resource(From)),
      Result = ejabberd_hooks:run_fold(groupchat_presence_unsubscribed_hook,
        Server, [], [{Server,User,Chat,#xabbergroupchat_user_card{},<<"en">>}]),
      case Result of
        ok ->
          delete_all_user_sessions(User,Chat),
          ejabberd_router:route(To,From,#presence{type = unsubscribe});
        _ ->
          ok
      end;
    false ->
      answer_presence(From, To, Decoded)
  end;
answer_presence(#presence{to=To, from = From, type = subscribe, sub_els = Sub} = Presence) ->
  Server = To#jid.lserver,
  User = jid:to_string(jid:remove_resource(From)),
  ChatJid = jid:to_string(jid:remove_resource(To)),
  Decoded = lists:map(fun(N)-> xmpp:decode(N) end, Sub),
  Collect = lists:keyfind(collect,1,Decoded),
  case Collect of
    false ->
      ok;
    _ ->
      {collect,Status} = Collect,
      case Status of
        <<"false">> ->
          mod_groups_inspector:block_parse_chat(Server,User,ChatJid);
        <<"true">> ->
          mod_groups_inspector:unblock_parse_chat(Server,User,ChatJid)
      end
  end,
  IsAnon = mod_groups_chats:is_anonim(Server,ChatJid),
  PeerToPeer = lists:keyfind(xabbergroup_peer,1,Decoded),
  case PeerToPeer of
    false ->
      ok;
    _ ->
      {xabbergroup_peer,_JID,_ID,PeerState} = PeerToPeer,
      ValidStates = [<<"true">>,<<"false">>],
      case lists:member(PeerState,ValidStates) of
        true when IsAnon ->
          mod_groups_users:change_peer_to_peer_invitation_state(Server,User,ChatJid,PeerState);
        _ ->
          ?DEBUG("Not change state",[])
      end
  end,
  Result = ejabberd_hooks:run_fold(groupchat_presence_hook, Server, [], [Presence]),
  FromChat = jid:replace_resource(To,<<"Group">>),
  case Result of
    not_ok ->
      ejabberd_router:route(FromChat,From,form_unsubscribed_presence());
    _ ->
      ejabberd_router:route(form_presence_with_type(Server, User, ChatJid, subscribed)),
      ejabberd_router:route(form_presence_with_type(Server, User, ChatJid, subscribe)),
      ejabberd_router:route(FromChat,From, mod_groups_vcard:get_pubsub_meta())
  end;
answer_presence(#presence{to=To, from = From, lang = Lang, type = subscribed}) ->
  Server = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  FromChat = jid:replace_resource(To,<<"Group">>),
  Result = ejabberd_hooks:run_fold(groupchat_presence_subscribed_hook, Server, [], [{Server,From,Chat,Lang}]),
  case Result of
    ok ->
      User = jid:to_string(jid:remove_resource(From)),
      ejabberd_router:route(form_presence_with_type(Server, User, Chat, subscribed)),
      ejabberd_router:route(FromChat,From, mod_groups_vcard:get_pubsub_meta());
    not_ok ->
      ejabberd_router:route(FromChat,From,form_unsubscribed_presence());
    _ ->
      ok
  end;
answer_presence(#presence{lang = Lang,to = ChatJID, from = UserJID, type = unsubscribe}) ->
  Server = ChatJID#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(ChatJID)),
  User = jid:to_string(jid:remove_resource(UserJID)),
  UserCard = mod_groups_users:form_user_card(User,Chat),
  ChatJIDRes = jid:replace_resource(ChatJID,<<"Group">>),
  Result = ejabberd_hooks:run_fold(groupchat_presence_unsubscribed_hook, Server, [], [{Server,User,Chat,UserCard,Lang}]),
  case Result of
    ok ->
      delete_all_user_sessions(User,Chat),
      ejabberd_router:route(ChatJIDRes,UserJID,#presence{type = unsubscribe, id = randoms:get_string()}),
      ejabberd_router:route(ChatJIDRes,UserJID,#presence{type = unavailable, id = randoms:get_string()});
    alone ->
      alone;
    _ ->
      error
  end;
answer_presence(#presence{lang = Lang,to = ChatJID, from = UserJID, type = unsubscribed}) ->
  Server = ChatJID#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(ChatJID)),
  User = jid:to_string(jid:remove_resource(UserJID)),
  case mod_groups_users:check_if_exist(Server,Chat,User) of
    true ->
      UserCard = mod_groups_users:form_user_card(User,Chat),
      ChatJIDRes = jid:replace_resource(ChatJID,<<"Group">>),
      Result = ejabberd_hooks:run_fold(groupchat_presence_unsubscribed_hook, Server, [], [{Server,User,Chat,UserCard,Lang}]),
      case Result of
        ok ->
          delete_all_user_sessions(User,Chat),
          ejabberd_router:route(ChatJIDRes,UserJID,#presence{type = unsubscribe, id = randoms:get_string()}),
          ejabberd_router:route(ChatJIDRes,UserJID,#presence{type = unavailable, id = randoms:get_string()});
        alone ->
          alone;
        _ ->
          error
      end;
    _ ->
      ok
  end;
answer_presence(#presence{to = To, from = From, type = unavailable}) ->
change_present_state(To,From);
answer_presence(Presence) ->
  ?DEBUG("Drop presence ~p",[Presence]).

answer_presence(From, To, SubEls)->
  ChatJid = jid:to_string(jid:make(To#jid.luser,To#jid.lserver,<<>>)),
  Resource = From#jid.lresource,
  User = jid:to_string(jid:remove_resource(From)),
  Server = To#jid.lserver,
  IsExist = mod_groups_users:check_if_exist(Server,ChatJid,User),
  Key = lists:keyfind(vcard_xupdate,1, SubEls),
  Collect = lists:keyfind(collect,1, SubEls),
  case Collect of
    false ->
      ok;
    _ ->
      {collect,CStatus} = Collect,
      case CStatus of
        <<"false">> ->
          mod_groups_inspector:block_parse_chat(Server,User,ChatJid);
        <<"true">> ->
          mod_groups_inspector:unblock_parse_chat(Server,User,ChatJid)
      end
  end,
  NewHash = search_for_hash(Key),
  OldHash = mod_groups_vcard:get_vcard_avatar_hash(Server,User),
  IsAnon = mod_groups_chats:is_anonim(Server,ChatJid),
  case NewHash of
    OldHash -> ok;
    <<>> -> delete_photo_if_exist;
    undefined -> ok;
    _ when not IsAnon ->
      ejabberd_router:route(jid:replace_resource(To,<<"Group">>),jid:remove_resource(From), mod_groups_vcard:get_vcard());
    _ ->
      ok
  end,
  PeerToPeer = lists:keyfind(xabbergroup_peer,1, SubEls),
  case PeerToPeer of
    false ->
      ok;
    _ ->
      {xabbergroup_peer,_JID,_ID,PeerState} = PeerToPeer,
      ValidStates = [<<"true">>,<<"false">>],
      case lists:member(PeerState,ValidStates) of
        true when IsAnon ->
          mod_groups_users:change_peer_to_peer_invitation_state(Server,User,ChatJid,PeerState);
        _ ->
          ok
      end
  end,
  FromChat = jid:replace_resource(To,<<"Group">>),
  Present = lists:keyfind(x_present,1, SubEls),
  NotPresent = lists:keyfind(x_not_present,1, SubEls),
  PresentNum = get_present(ChatJid),
  if
    Present == false andalso NotPresent == false andalso IsExist ->
      mod_groups_vcard:make_chat_notification_message(Server,ChatJid,From),
      ejabberd_router:route(FromChat,From,form_presence(ChatJid,User)),
      if
        not IsAnon ->
          mod_groups_vcard:maybe_update_avatar(From,To,Server);
        true -> ok
      end;
    Present =/= false andalso NotPresent == false andalso IsExist ->
      mod_groups_users:update_last_seen(Server,User,ChatJid),
      case set_session(Resource, User, ChatJid) of
        ok ->
          send_notification(From, To, PresentNum, present);
        _ ->
          ignore
      end;
    Present == false andalso NotPresent =/= false andalso IsExist ->
      change_present_state(To,From);
    true ->
      ok
  end.

get_present(Group) ->
  Sessions = select_all_sessions(Group),
  AllUsersSession = [{U,S}||{participant_session, _G, U, S, _R, _TS} <- Sessions],
  UniqueOnline = lists:usort(AllUsersSession),
  integer_to_binary(length(UniqueOnline)).

change_present_state(To,From) ->
  Resource = From#jid.lresource,
  Server = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  Username = jid:to_string(jid:remove_resource(From)),
  PresentNum = get_present(Chat),
  delete_session(Resource,Username,Chat),
  mod_groups_users:update_last_seen(Server,Username,Chat),
  send_notification(From, To, PresentNum, not_present).

send_notification(From, To, PresentNum, PresentType) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  FromChat = jid:replace_resource(To,<<"Group">>),
  ActualPresentNum = get_present(Chat),
  case ActualPresentNum of
    PresentNum  when PresentType == present ->
      %% notify only the connecting device about the actual count
      User = [{jid:to_string(From)}],
      send_presence(form_presence(Chat),User,FromChat);
    PresentNum ->
      %% someone left, but the counter didn't change
      ok;
    _ ->
      %% notify everyone about the counter change
      Users = get_users_with_session(Chat),
      send_presence(form_presence(Chat), Users, FromChat)
  end.

get_users_with_session(Chat) ->
  SS = select_all_sessions(Chat),
  Users = [jid:make(U,S,R)||{participant_session, _, U, S, R, _} <- SS],
%%  todo: refactoring
  [{jid:to_string(J)} || J <- Users].

get_global_index(Server) ->
  gen_mod:get_module_opt(Server, mod_groups, global_indexs).

send_message_to_index(ChatJID, Message) ->
  Server = ChatJID#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(ChatJID)),
  case mod_groups_chats:is_global_indexed(Server,Chat) of
    true ->
      GlobalIndexes = get_global_index(Server),
      lists:foreach(fun(Index) ->
        To = jid:from_string(Index),
        MessageDecoded = xmpp:decode(Message),
        M = xmpp:set_from_to(MessageDecoded,ChatJID,To),
        ejabberd_router:route(M) end, GlobalIndexes);
    _ ->
      ok
  end.

send_info_to_index(Server,Chat) ->
  case mod_groups_chats:is_global_indexed(Server,Chat) of
    true ->
      send_presence_to_index(Server, Chat);
    _ ->
      ok
  end.

send_presence_to_index(Server, Chat) ->
  GlobalIndexs =   get_global_index(Server),
  ChatJID = jid:from_string(Chat),
  lists:foreach(fun(Index) ->
    {selected,[{Name,Anonymous,IndexValue,Model,Desc,Message,_ContactList,_DomainList,ParentChat,Status}]} =
      mod_groups_chats:get_all_information_chat(Chat,Server),
    {HumanStatus, Show} =  case ParentChat of
                             <<"0">> ->
                               mod_groups_chats:define_human_status_and_show(Server, Chat, Status);
                             _ ->
                               {[#text{data = <<"Private chat">>}],undefined}
                           end,
    Parent = case ParentChat of
               <<"0">> ->
                 undefined;
               _ ->
                 jid:from_string(ParentChat)
             end,
    Groupchat_x = #xabbergroupchat_x{
      xmlns = ?NS_GROUPCHAT,
      members = mod_groups_chats:count_users(Server,Chat),
      parent = Parent,
      sub_els =
      [
        #xabbergroupchat_name{cdata = Name},
        #xabbergroupchat_privacy{cdata = Anonymous},
        #xabbergroupchat_index{cdata = IndexValue},
        #xabbergroupchat_pinned_message{cdata = integer_to_binary(Message)},
        #xabbergroupchat_membership{cdata = Model},
        #xabbergroupchat_description{cdata = Desc}
      ]},
    To = jid:from_string(Index),
    FromChat = jid:replace_resource(ChatJID,<<"Group">>),
    Presence = #presence{id = randoms:get_string(), type = available,
      from = FromChat, to = To, sub_els = [Groupchat_x], status = HumanStatus, show = Show},
    ejabberd_router:route(Presence) end, GlobalIndexs
  ).

form_presence_unavailable() ->
      #xmlel{
         name = <<"presence">>,
         attrs = [
                  {<<"type">>, <<"unavailable">>},
                  {<<"xmlns">>, <<"jabber:client">>}
                 ],
         children = [#xmlel{
                        name = <<"x">>,
                        attrs = [
                                 {<<"xmlns">>, ?NS_GROUPCHAT}
                                ]
                       }
                    ]
        }.

form_presence_unavailable(Chat) ->
  {Groupchat_x, HumanStatus, Show} = info_about_chat(Chat),
  #presence{type = unavailable, id = randoms:get_string(), sub_els = [Groupchat_x], status = HumanStatus, show = Show}.

form_presence(ChatJid) ->
  {Groupchat_x, HumanStatus, Show} = info_about_chat(ChatJid),

  #presence{type = available, id = randoms:get_string(), sub_els = [Groupchat_x], status = HumanStatus, show = Show}.

form_presence(ChatJID, Show, Status) ->
  {Groupchat_x, _HumanStatus, Show} = info_about_chat(ChatJID),
  #presence{type = available, id = randoms:get_string(), sub_els = [Groupchat_x], status = Status, show = Show}.

form_presence(Chat,User) ->
  ChatJID = jid:from_string(Chat),
  LServer = ChatJID#jid.lserver,
  {selected,[{Name,Anonymous,_Search,_Model,_Desc,_Message,_ContactList,_DomainList,ParentChat,Status}]} =
    mod_groups_chats:get_all_information_chat(Chat,LServer),
  Members = mod_groups_chats:count_users(LServer,Chat),
  {CollectState,P2PState} = mod_groups_inspector:get_collect_state(Chat,User),
  Hash = mod_groups_inspector:get_chat_avatar_id(Chat),
  VcardX = #vcard_xupdate{hash = Hash},
  SubEls = case ParentChat of
             <<"0">> ->
               [
                 #xabbergroupchat_x{
                   xmlns = ?NS_GROUPCHAT,
                   members = Members,
                   sub_els = [
                     #xabbergroupchat_name{cdata = Name},
                     #xabbergroupchat_privacy{cdata = Anonymous},
                     #collect{cdata = CollectState},
                     #xabbergroup_peer{cdata = P2PState}
                   ]
                 },
                 VcardX
               ];
             _ ->
               [
                 #xabbergroupchat_x{
                   xmlns = ?NS_GROUPCHAT,
                   members = Members,
                   parent = jid:from_string(ParentChat),
                   sub_els = [
                     #xabbergroupchat_name{cdata = Name},
                     #xabbergroupchat_privacy{cdata = Anonymous}
                   ]
                 },
                 VcardX
               ]
           end,
  {HumanStatus, Show} = case ParentChat of
                  <<"0">> ->
                    mod_groups_chats:define_human_status_and_show(LServer, Chat, Status);
                  _ ->
                    {[#text{data = <<"Private chat">>}],undefined}
                end,
  #presence{type = available, id = randoms:get_string(), sub_els = SubEls, status = HumanStatus, show = Show}.



info_about_chat(ChatJid) ->
  S = jid:from_string(ChatJid),
  Server = S#jid.lserver,
  case mod_groups_chats:get_all_information_chat(ChatJid,Server) of
    {selected,[{Name,Anonymous,_,_,_,Message,_,_,ParentChat,Status}]} ->
      info_about_chat(ChatJid, {Name, Anonymous, Message, ParentChat, Status});
    _ ->
      %% Happens when deleting a group
      {#xabbergroupchat_x{xmlns = ?NS_GROUPCHAT}, [],undefined}
  end.
info_about_chat(ChatJid, {Name, Anonymous, Message, ParentChat, Status}) ->
  S = jid:from_string(ChatJid),
  Server = S#jid.lserver,
  Present = case Status of
              <<"inactive">> ->
                <<"0">>;
              _ ->
                get_present(ChatJid)
            end,
  {HumanStatus, Show} =  case ParentChat of
                   <<"0">> ->
                     mod_groups_chats:define_human_status_and_show(Server, ChatJid, Status);
                   _ ->
                     {[#text{data = <<"Private chat">>}],undefined}
                 end,
  Parent = case ParentChat of
             <<"0">> ->
               undefined;
             _ ->
               jid:from_string(ParentChat)
           end,
  {#xabbergroupchat_x{
      xmlns = ?NS_GROUPCHAT,
      members = mod_groups_chats:count_users(Server,ChatJid),
      present = Present,
      parent = Parent,
      sub_els =
      [
        #xabbergroupchat_name{cdata = Name},
        #xabbergroupchat_privacy{cdata = Anonymous},
        #xabbergroupchat_pinned_message{cdata = integer_to_binary(Message)}
      ]}, HumanStatus, Show}.

form_unsubscribe_presence() ->
      #xmlel{
         name = <<"presence">>,
         attrs = [
                  {<<"type">>, <<"unsubscribe">>}
                 ]
        }.

form_unsubscribed_presence() ->
      #xmlel{
         name = <<"presence">>,
         attrs = [
                  {<<"type">>, <<"unsubscribed">>}
                 ]
        }.

%%%===================================================================
%%% present functions
%%%===================================================================
-spec set_session(binary(),binary(),binary()) -> ok | ignore.
set_session(Resource, User, Group) ->
  {Username, Server, _} = jid:tolower(jid:from_string(User)),
  Result = case select_session(Resource, User, Group) of
             [#participant_session{} = SS] ->
               delete_session(SS),
               ignore;
             _ -> ok
           end,
  Session = #participant_session{
    group = Group,
    username = Username,
    server = Server,
    resource =  Resource,
    ts = misc:now_to_usec(erlang:now())
  },
  mnesia:dirty_write(Session),
  Result.

delete_session(Resource, User, Group) ->
  S = select_session(Resource, User, Group),
  lists:foreach(fun(N) -> delete_session(N) end, S).

-spec delete_session(#participant_session{}) -> ok.
delete_session(S) ->
  mnesia:dirty_delete_object(S).

select_session(Resource, User, Group) ->
  {LUser, LServer, _} = jid:tolower(jid:from_string(User)),
  FN = fun()->
    mnesia:match_object(participant_session,
      {participant_session, Group, LUser, LServer, Resource, '_'},
      read)
       end,
  {atomic,Session} = mnesia:transaction(FN),
  Session.

select_all_sessions(Group) ->
  mnesia:dirty_read(participant_session, Group).

select_sessions(User, Group) ->
  {LUser, LServer, _} = jid:tolower(jid:from_string(User)),
  FN = fun()->
    mnesia:match_object(participant_session,
      {participant_session, Group, LUser, LServer, '_', '_'},
      read)
       end,
  {atomic,Sessions} = mnesia:transaction(FN),
  Sessions.

delete_all_user_sessions(User, Chat) ->
  Sessions = select_sessions(User,Chat),
  lists:foreach(fun(Session) ->
    delete_session(Session) end, Sessions).

delete_all_sessions(Chat) ->
  Sessions = select_all_sessions(Chat),
  lists:foreach(fun(Session) ->
    delete_session(Session) end, Sessions).

%% delete sessions older than 1 hour
kill_zombies() ->
  FN = fun()->
    TS = misc:now_to_usec(erlang:now()) - 3600000000,
    MatchHead = #participant_session{_='_', _='_' , _='_', _='_', ts = '$1'},
    Guards = [{'<', '$1', TS}],
    SS = mnesia:select(participant_session,[{MatchHead, Guards, ['$_']}]),
    lists:foreach(fun(O) ->
      ?WARNING_MSG("Delete session older than 1 hour. Group: ~p; user: ~p",
        [O#participant_session.group, #participant_session.username]),
      mnesia:delete_object(O) end, SS)
       end,
  mnesia:transaction(FN),
  ok.
