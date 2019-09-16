%%%-------------------------------------------------------------------
%%% File    : mod_groupchat_presence.erl
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

-module(mod_groupchat_presence).
-author('andrey.gagarin@redsolution.com').
-behavior(gen_mod).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("mod_groupchat_present.hrl").

-export([start/2, stop/1, depends/2, mod_options/1, mod_opt_type/1]).
-export([
         form_presence/2, form_presence/1,
         form_presence_unavailable/0,
         form_presence_vcard_update/1,
         form_subscribe_presence/1,
         form_subscribed_presence/0,
         form_unsubscribe_presence/0,
         form_unsubscribed_presence/0,
         form_updated_presence/1,
         process_presence/1,
  send_info_to_index/2, get_global_index/1, send_message_to_index/2
        ]).
start(_Host, _Opts) ->
    ok.

stop(_Host) ->
    ok.

depends(_Host, _Opts) ->  [].

mod_opt_type(xabber_global_indexs) ->
  fun (L) -> lists:map(fun iolist_to_binary/1, L) end.

mod_options(_Host) -> [
  {xabber_global_indexs, []}
].

process_presence(#presence{to=To} = Packet) ->
  Server = To#jid.lserver,
  ChatJid = jid:to_string(jid:make(To#jid.luser,Server,<<>>)),
  process_presence(mod_groupchat_sql:search_for_chat(Server,ChatJid),Packet).

process_presence({selected,[]},Packet) ->
  Packet;
process_presence(_,Packet) ->
  answer_presence(Packet).

is_chat(SubEls) ->
  Sub = lists:map(fun(N) -> xmpp:decode(N) end, SubEls),
  case lists:keyfind(xabbergroupchat_x,1,Sub) of
     false ->
       false;
    _ ->
      true
  end.


search_for_hash(Hash) ->
 case Hash of
   false ->
     <<>>;
   _ ->
     Hash#vcard_xupdate.hash
 end.

answer_presence(#presence{to = To, from = From, type = available,
  sub_els = SubEls}) ->
  case is_chat(SubEls) of
    true ->
      Server = To#jid.lserver,
      Chat = To#jid.luser,
      ChatJid = jid:to_string(jid:remove_resource(From)),
      mod_groupchat_inspector_sql:delete_user_chat(ChatJid,Server,Chat);
    false ->
      ChatJid = jid:to_string(jid:make(To#jid.luser,To#jid.lserver,<<>>)),
      Resource = From#jid.lresource,
      User = jid:to_string(jid:remove_resource(From)),
      Server = To#jid.lserver,
      Status = mod_groupchat_inspector_sql:check_user(User,Server,ChatJid),
      Decoded = lists:map(fun(N)-> xmpp:decode(N) end, SubEls),
      Key = lists:keyfind(vcard_xupdate,1,Decoded),
      Collect = lists:keyfind(collect,1,Decoded),
      case Collect of
        false ->
          ok;
        _ ->
          {collect,Status} = Collect,
          case Status of
            <<"false">> ->
              mod_groupchat_inspector:block_parse_chat(Server,User,ChatJid);
            <<"true">> ->
              mod_groupchat_inspector:unblock_parse_chat(Server,User,ChatJid)
          end
      end,
      NewHash = search_for_hash(Key),
      OldHash = mod_groupchat_sql:get_hash(Server,User),
      case NewHash of
        OldHash ->
          ok;
        <<>> ->
          delete_photo_if_exist;
        undefined ->
          ok;
        _ ->
          mod_groupchat_sql:update_hash(Server,User,NewHash),
          mod_groupchat_sql:set_update_status(Server,User,<<"true">>)
      end,
      Chats = mod_groupchat_inspector:chats_to_parse_vcard(Server,User),
      IsAnon = mod_groupchat_inspector:is_anonim(Server,ChatJid),
      PeerToPeer = lists:keyfind(xabbergroup_peer,1,Decoded),
      case PeerToPeer of
        false ->
          ok;
        _ ->
          {xabbergroup_peer,_JID,_ID,PeerState} = PeerToPeer,
          ValidStates = [<<"true">>,<<"false">>],
          case lists:member(PeerState,ValidStates) of
            true when IsAnon == yes ->
              mod_groupchat_users:change_peer_to_peer_invitation_state(Server,User,ChatJid,PeerState);
            _ ->
              ?DEBUG("Not change state",[])
          end
      end,
      case lists:member({ChatJid},Chats) of
        true when IsAnon == no->
          ejabberd_router:route(jid:replace_resource(To,<<"Groupchat">>),jid:remove_resource(From),mod_groupchat_vcard:get_pubsub_meta()),
          ejabberd_router:route(jid:replace_resource(To,<<"Groupchat">>),jid:remove_resource(From),mod_groupchat_vcard:get_vcard());
        _ ->
          ok
      end,
      FromChat = jid:replace_resource(To,<<"Groupchat">>),
      Present = lists:keyfind(x_present,1,Decoded),
      NotPresent = lists:keyfind(x_not_present,1,Decoded),
      PresentNum = get_present(ChatJid),
      case Present of
        false when NotPresent == false andalso Status == exist ->
          ejabberd_router:route(FromChat,From,form_presence(ChatJid,User));
        _  when Present =/= false andalso NotPresent == false andalso Status == exist ->
          mod_groupchat_sql:update_last_seen(Server,User,ChatJid),
          mod_groupchat_present_mnesia:set_session(#chat_session{
            id = randoms:get_string(),
            resource =  Resource,
            user = User,
            chat = ChatJid}),
          send_notification(To,PresentNum);
        _  when Present == false andalso NotPresent =/= false andalso Status == exist->
          change_present_state(To,From);
        _ ->
          mod_groupchat_vcard:make_chat_notification_message(Server,ChatJid,To),
          ok
      end
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
          mod_groupchat_inspector:block_parse_chat(Server,User,ChatJid);
        <<"true">> ->
          mod_groupchat_inspector:unblock_parse_chat(Server,User,ChatJid)
      end
  end,
  IsAnon = mod_groupchat_inspector:is_anonim(Server,ChatJid),
  PeerToPeer = lists:keyfind(xabbergroup_peer,1,Decoded),
  case PeerToPeer of
    false ->
      ok;
    _ ->
      {xabbergroup_peer,_JID,_ID,PeerState} = PeerToPeer,
      ValidStates = [<<"true">>,<<"false">>],
      case lists:member(PeerState,ValidStates) of
        true when IsAnon == yes ->
          mod_groupchat_users:change_peer_to_peer_invitation_state(Server,User,ChatJid,PeerState);
        _ ->
          ?DEBUG("Not change state",[])
      end
  end,
  Result = ejabberd_hooks:run_fold(groupchat_presence_hook, Server, [], [Presence]),
  FromChat = jid:replace_resource(To,<<"Groupchat">>),
  case Result of
    not_ok ->
      ejabberd_router:route(FromChat,From,form_unsubscribed_presence());
    _ ->
%%      ejabberd_router:route(FromChat,jid:remove_resource(From),mod_groupchat_vcard:get_vcard()),
      ejabberd_router:route(FromChat,From,form_subscribed_presence()),
      ejabberd_router:route(FromChat,From,#presence{type = subscribe, id = randoms:get_string()}),
      ejabberd_router:route(FromChat,From,mod_groupchat_vcard:get_pubsub_meta())
  end;
answer_presence(#presence{to=To, from = From, lang = Lang, type = subscribed}) ->
  Server = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  FromChat = jid:replace_resource(To,<<"Groupchat">>),
  Result = ejabberd_hooks:run_fold(groupchat_presence_subscribed_hook, Server, [], [{Server,From,Chat,Lang}]),
  case Result of
    ok ->
      ejabberd_router:route(FromChat,From,form_subscribed_presence()),
      ejabberd_router:route(FromChat,From,mod_groupchat_vcard:get_pubsub_meta());
    not_ok ->
      ejabberd_router:route(FromChat,From,form_unsubscribed_presence());
    _ ->
      ok
  end;
answer_presence(#presence{lang = Lang,to = ChatJID, from = UserJID, type = unsubscribe}) ->
  Server = ChatJID#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(ChatJID)),
  User = jid:to_string(jid:remove_resource(UserJID)),
  UserCard = mod_groupchat_users:form_user_card(User,Chat),
  ChatJIDRes = jid:replace_resource(ChatJID,<<"Groupchat">>),
  Result = ejabberd_hooks:run_fold(groupchat_presence_unsubscribed_hook, Server, [], [{Server,User,Chat,UserCard,Lang}]),
  case Result of
    ok ->
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
  Exist = mod_groupchat_inspector_sql:check_user(User,Server,Chat),
  case Exist of
    exist ->
      UserCard = mod_groupchat_users:form_user_card(User,Chat),
      ChatJIDRes = jid:replace_resource(ChatJID,<<"Groupchat">>),
      Result = ejabberd_hooks:run_fold(groupchat_presence_unsubscribed_hook, Server, [], [{Server,User,Chat,UserCard,Lang}]),
      case Result of
        ok ->
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

get_present(Chat) ->
  ChatSessions = mod_groupchat_present_mnesia:select_sessions('_',Chat),
  AllUsersSession = [{X,Y}||{chat_session,_ID,_Z,X,Y} <- ChatSessions],
  UniqueOnline = lists:usort(AllUsersSession),
  Present = integer_to_binary(length(UniqueOnline)),
  Present.

change_present_state(To,From) ->
  Resource = From#jid.lresource,
  Server = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  Username = jid:to_string(jid:remove_resource(From)),
  PresentNum = get_present(Chat),
  mod_groupchat_present_mnesia:delete_session(Resource,Username,Chat),
  mod_groupchat_sql:update_last_seen(Server,Username,Chat),
  send_notification(To,PresentNum).

send_notification(To,PresentNum) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  FromChat = jid:replace_resource(To,<<"Groupchat">>),
  ActualPresentNum = get_present(Chat),
  case ActualPresentNum of
    PresentNum ->
      ok;
    _ ->
      Users = get_users_with_session(Chat),
      mod_groupchat_messages:send_message(form_presence(Chat),Users,FromChat)
  end.

get_users_with_session(Chat) ->
  SS = mod_groupchat_present_mnesia:select_sessions('_',Chat),
  Users = [{U,R}||{chat_session,_ID,R,U,_C} <- SS],
  lists:map(fun(UR) ->
    {U,R} = UR,
    BareJID = jid:from_string(U),
    JID = jid:replace_resource(BareJID,R),
    JIDs = jid:to_string(JID),
    {JIDs} end, Users
  ).

get_global_index(Server) ->
  gen_mod:get_module_opt(Server, ?MODULE,
    xabber_global_indexs).

send_message_to_index(ChatJID, Message) ->
  Server = ChatJID#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(ChatJID)),
  IsGlobalIndexed = mod_groupchat_chats:is_global_indexed(Server,Chat),
  case IsGlobalIndexed of
    yes ->
      GlobalIndexs = get_global_index(Server),
      lists:foreach(fun(Index) ->
        To = jid:from_string(Index),
        MessageDecoded = xmpp:decode(Message),
        M = xmpp:set_from_to(MessageDecoded,ChatJID,To),
        ejabberd_router:route(M) end, GlobalIndexs
      );
    _ ->
      ok
  end.

send_info_to_index(Server,ChatJID) ->
  Chat = jid:to_string(jid:remove_resource(ChatJID)),
  IsGlobalIndexed = mod_groupchat_chats:is_global_indexed(Server,Chat),
  case IsGlobalIndexed of
    yes ->
      GlobalIndexs =   get_global_index(Server),
      Chat = jid:to_string(jid:remove_resource(ChatJID)),
      lists:foreach(fun(Index) ->
        Info = info_about_chat(Chat),
        To = jid:from_string(Index),
        Groupchat_x = #xmlel{
          name = <<"x">>,
          attrs = [
            {<<"xmlns">>, ?NS_GROUPCHAT}
          ],
          children = Info
        },
        Presence = #presence{id = randoms:get_string(), type = available, from = ChatJID, to = To, sub_els = [Groupchat_x]},
        ejabberd_router:route(Presence) end, GlobalIndexs
      );
    _ ->
      ok
  end.


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


  form_updated_presence(UpdatedInfo) ->
  #xmlel{
    name = <<"presence">>,
    attrs = [
      {<<"type">>, <<"available">>},
      {<<"xmlns">>, <<"jabber:client">>}
    ],
    children = [#xmlel{
      name = <<"x">>,
      attrs = [
        {<<"xmlns">>, ?NS_GROUPCHAT}
      ],
      children = UpdatedInfo
    }
    ]
  }.

form_presence(ChatJid) ->
  Info = info_about_chat(ChatJid),
  InfoEl = Info,
  Groupchat_x = #xmlel{
    name = <<"x">>,
    attrs = [
      {<<"xmlns">>, ?NS_GROUPCHAT}
    ],
    children = InfoEl
  },
  Children = [Groupchat_x],
  #xmlel{
    name = <<"presence">>,
    attrs = [
      {<<"type">>, <<"available">>},
      {<<"xmlns">>, <<"jabber:client">>}
    ],
    children = Children
  }.

form_presence(ChatJid,User) ->
  Info = detailed_about_chat(ChatJid),
  {CollectState,P2PState} = mod_groupchat_inspector:get_collect_state(ChatJid,User),
  Hash = mod_groupchat_inspector:get_chat_avatar_id(ChatJid),
  VcardX = xmpp:encode(#vcard_xupdate{hash = Hash}),
  CollectEl = #xmlel{
    name = <<"collect">>,
    children = [{xmlcdata,CollectState}]
  },
  P2PEl = #xmlel{
    name = <<"peer-to-peer">>,
    children = [{xmlcdata,P2PState}]
  },
  InfoEl = Info++[CollectEl,P2PEl],
  Groupchat_x = #xmlel{
    name = <<"x">>,
    attrs = [
      {<<"xmlns">>, ?NS_GROUPCHAT}
    ],
    children = InfoEl
  },
  Children = [VcardX,Groupchat_x],
      #xmlel{
         name = <<"presence">>,
         attrs = [
                  {<<"type">>, <<"available">>},
                  {<<"xmlns">>, <<"jabber:client">>}
                 ],
         children = Children
        }.

info_about_chat(ChatJid) ->
  S = jid:from_string(ChatJid),
  Server = S#jid.lserver,
  {selected,[{Name,Anonymous,Search,Model,Desc,Message,ContactList,DomainList}]} =
    mod_groupchat_sql:get_information_of_chat(ChatJid,Server),
  mod_groupchat_inspector:chat_information(Name,ChatJid,Anonymous,Search,Model,Desc,Message,ContactList,DomainList).

detailed_about_chat(Chat) ->
  ChatJID = jid:from_string(Chat),
  LServer = ChatJID#jid.lserver,
  {selected,[{Name,Anonymous,Search,Model,Desc,Message,ContactList,DomainList,ParentChat}]} =
    mod_groupchat_chats:get_detailed_information_of_chat(Chat,LServer),
  mod_groupchat_inspector:detailed_chat_information(Name,Chat,Anonymous,Search,Model,Desc,Message,ContactList,DomainList,ParentChat).


form_presence_vcard_update(Hash) ->
  #xmlel{
     name = <<"presence">>,
     attrs = [
              {<<"type">>, <<"available">>},
              {<<"xmlns">>, <<"jabber:client">>}
              ],
     children = [#xmlel{
                    name = <<"x">>,
                    attrs = [{<<"xmlns">>, <<"vcard-temp:x:update">>}],
                    children = [#xmlel{name = <<"photo">>, children = [{xmlcdata,Hash}]}]
                       }
                ] 
        }.

form_subscribe_presence(Nick) ->
      #xmlel{
         name = <<"presence">>,
         attrs = [
                  {<<"type">>, <<"subscribe">>}
                 ],
         children = [#xmlel{
                        name = <<"nick">>,
                        attrs = [{<<"xmlns">>,<<"http://jabber.org/protocol/nick">>}],
                        children = [{xmlcdata,Nick}]
                       },
                     #xmlel{
                        name = <<"status">>,
                        children = []
                       }
                    ]
        }.

form_subscribed_presence() ->
      #xmlel{
         name = <<"presence">>,
         attrs = [
                  {<<"type">>, <<"subscribed">>}
                 ]
        }.

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