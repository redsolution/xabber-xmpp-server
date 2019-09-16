%%%-------------------------------------------------------------------
%%% File    : mod_groupchat_chats.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose :  Work with group chats
%%% Created : 19 Oct 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_groupchat_chats).
-author('andrey.gagarin@redsolution.com').
-behavior(gen_mod).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).
%% API
-export([start/2, stop/1, depends/2, mod_options/1]).
-export([delete_chat/2, is_anonim/2, is_global_indexed/2, get_all/1, get_all_info/3, get_count_chats/1, get_depended_chats/2, get_detailed_information_of_chat/2]).
-export([check_creator/4, check_user/4, check_chat/4,create_peer_to_peer/4, send_invite/4, check_if_peer_to_peer_exist/4, groupchat_exist/2]).
start(Host, _Opts) ->
  ejabberd_hooks:add(groupchat_peer_to_peer, Host, ?MODULE, check_creator, 10),
  ejabberd_hooks:add(groupchat_peer_to_peer, Host, ?MODULE, check_chat, 15),
  ejabberd_hooks:add(groupchat_peer_to_peer, Host, ?MODULE, check_user, 20),
  ejabberd_hooks:add(groupchat_peer_to_peer, Host, ?MODULE, check_if_peer_to_peer_exist, 25),
  ejabberd_hooks:add(groupchat_peer_to_peer, Host, ?MODULE, create_peer_to_peer, 30),
  ejabberd_hooks:add(groupchat_peer_to_peer, Host, ?MODULE, send_invite, 40),
  ejabberd_hooks:add(groupchat_presence_unsubscribed_hook, Host, ?MODULE, delete_chat, 35).

stop(Host) ->
  ejabberd_hooks:delete(groupchat_peer_to_peer, Host, ?MODULE, check_creator, 10),
  ejabberd_hooks:delete(groupchat_peer_to_peer, Host, ?MODULE, check_chat, 15),
  ejabberd_hooks:delete(groupchat_peer_to_peer, Host, ?MODULE, check_user, 20),
  ejabberd_hooks:delete(groupchat_peer_to_peer, Host, ?MODULE, check_if_peer_to_peer_exist, 25),
  ejabberd_hooks:delete(groupchat_peer_to_peer, Host, ?MODULE, create_peer_to_peer, 30),
  ejabberd_hooks:delete(groupchat_peer_to_peer, Host, ?MODULE, send_invite, 40),
  ejabberd_hooks:delete(groupchat_presence_unsubscribed_hook, Host, ?MODULE, delete_chat, 35).

depends(_Host, _Opts) ->  [].

mod_options(_Opts) -> [].

check_creator(_Acc, LServer, Creator,  #xabbergroup_peer{jid = ChatJID}) ->
  ?DEBUG("start fold ~p ~p ~p", [LServer,Creator, ChatJID]),
  Chat = jid:to_string(ChatJID),
  case mod_groupchat_users:check_user(LServer, Creator, Chat) of
    not_exist ->
      ?DEBUG("User not exist ~p",[Creator]),
      {stop,not_exist};
    _ ->
      ?DEBUG("User exist ~p",[Creator]),
      ok
  end.

check_chat(_Acc, LServer, _Creator,  #xabbergroup_peer{jid = ChatJID}) ->
  Chat = jid:to_string(ChatJID),
  Independet = is_independent(LServer,Chat),
  case is_anonim(LServer,Chat) of
    no ->
      ?DEBUG("Chat no anon ~p",[Chat]),
      {stop,not_exist};
    _ when Independet == yes ->
      ok;
    _ ->
      {stop,dependet}
  end.

check_user(_Acc, LServer, Creator,  #xabbergroup_peer{jid = ChatJID, id = UserID}) ->
  Chat = jid:to_string(ChatJID),
  case mod_groupchat_users:get_user_by_id_and_allow_to_invite(LServer,Chat,UserID) of
    none ->
      ?DEBUG("User to invite not exist ~p",[UserID]),
      {stop,not_exist};
    Creator ->
      {stop, not_ok};
    User ->
      User
  end.

check_if_peer_to_peer_exist(User, LServer, Creator,  #xabbergroup_peer{jid = ChatJID}) ->
  Chat = jid:to_string(ChatJID),
  case check_if_not_p2p_exist(LServer,Chat,Creator,User) of
    {false,ExistedChat} ->
      {stop,{exist,ExistedChat}};
    _ ->
      User
  end.

create_peer_to_peer(User, LServer, Creator, #xabbergroup_peer{jid = ChatJID}) ->
  Localpart = list_to_binary(string:to_lower(binary_to_list(create_localpart()))),
  OldChat = jid:to_string(jid:remove_resource(ChatJID)),
  UserExist = ejabberd_auth:user_exists(Localpart,LServer),
  case mod_groupchat_inspector_sql:check_jid(Localpart,LServer) of
    {selected,[]} when UserExist == false ->
      Chat = jid:to_string(jid:make(Localpart,LServer)),
      User1Nick = mod_groupchat_users:get_nick_in_chat(LServer,Creator,OldChat),
      User2Nick = mod_groupchat_users:get_nick_in_chat(LServer,User,OldChat),
      ChatName = <<User1Nick/binary," and ",User2Nick/binary, " chat">>,
      Desc = <<"Private chat">>,
      create_groupchat(LServer,Localpart,Creator,ChatName,Chat,
        <<"incognito">>,<<"none">>,<<"member-only">>,Desc,<<"0">>,<<"">>,<<"">>,OldChat),
      mod_admin_extra:set_nickname(Localpart,LServer,ChatName),
      add_user_to_peer_to_peer_chat(LServer, User, Chat, OldChat),
      add_user_to_peer_to_peer_chat(LServer, Creator, Chat, OldChat),
      Expires = <<"1000 years">>,
      IssuedBy = <<"server">>,
      Rule = <<"send-invitations">>,
      mod_groupchat_restrictions:insert_rule(LServer,Chat,User,Rule,Expires,IssuedBy),
      mod_groupchat_restrictions:insert_rule(LServer,Chat,Creator,Rule,Expires,IssuedBy),
      {User,Chat, ChatName, Desc, User1Nick, User2Nick, OldChat, ChatJID};
    _ ->
      {stop, not_ok}
  end.

send_invite({User,Chat, ChatName, Desc, User1Nick, User2Nick, OldChat, OldChatJID}, LServer, _Creator, _X) ->
  Anonymous = <<"incognito">>,
  Search = <<"none">>,
  Model = <<"member-only">>,
  OldChatName = get_chat_name(OldChat,LServer),
  BareOldChatJID = jid:remove_resource(OldChatJID),
  ChatInfo = #xabbergroupchat_x{anonymous = Anonymous,model = Model, description = Desc, name = ChatName, searchable = Search, parent = BareOldChatJID},
  ChatJID = jid:from_string(Chat),
  Text = <<"You was invited to ",Chat/binary," Please add it to the contacts to join a group chat">>,
  Reason = <<User1Nick/binary,
  " from ",OldChatName/binary, " invited you to chat privately."
  " If you accept this invitation, you won't see each other's real XMPP IDs."
  " You will be known as ", User2Nick/binary
  >>,
  Invite = #xabbergroupchat_invite{reason = Reason, jid = ChatJID},
  Message = #message{
    type = chat,
    id = randoms:get_string(),
    from = jid:replace_resource(ChatJID,<<"Groupchat">>),
    to = jid:from_string(User),
    body = [#text{lang = <<>>,data = Text}],
    sub_els = [Invite,ChatInfo]},
  ejabberd_router:route(Message),
  Created = created(ChatName,Chat,Anonymous,Search,Model,Desc,<<"0">>,<<"">>,<<"">>),
  {stop,{ok,Created}}.

delete_chat(_Acc,{LServer,_User,Chat,_UserCard,_Lang})->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(username)s from groupchat_users where chatgroup = %(Chat)s and subscription = 'both'")) of
    {selected,[]} ->
      delete(Chat);
    {selected,[{}]} ->
      delete(Chat);
    _ ->
      ok
  end,
  {stop,ok}.

is_anonim(LServer,Chat) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(jid)s from groupchats
    where jid = %(Chat)s
    and anonymous = 'incognito' and %(LServer)H")) of
    {selected,[{null}]} ->
      no;
    {selected,[]} ->
      no;
    {selected,[{}]} ->
      no;
    _ ->
      yes
  end.

is_independent(LServer,Chat) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(jid)s from groupchats
    where jid = %(Chat)s
    and parent_chat = '0' and %(LServer)H")) of
    {selected,[{null}]} ->
      no;
    {selected,[]} ->
      no;
    {selected,[{}]} ->
      no;
    _ ->
      yes
  end.

is_global_indexed(LServer,Chat) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(jid)s from groupchats
    where jid = %(Chat)s
    and searchable = 'global' and %(LServer)H")) of
    {selected,[{null}]} ->
      no;
    {selected,[]} ->
      no;
    {selected,[{}]} ->
      no;
    _ ->
      yes
  end.

get_all(LServer) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(localpart)s from groupchats where %(LServer)H")) of
    {selected,[{null}]} ->
      [];
    {selected,[]} ->
      [];
    {selected,[{}]} ->
      [];
    {selected, Chats} ->
      Chats
  end.
%%
get_all_info(LServer,Limit,Page) ->
  Offset = case Page of
             _  when Page > 0 ->
               Limit * (Page - 1)
           end,
  ChatInfo = case ejabberd_sql:sql_query(
    LServer,
    [<<"select localpart,owner,(select count(*) from groupchat_users where chatgroup = t.jid) as count, (select count(*) from groupchats where parent_chat = t.jid) as private_chats from groupchats t where t.parent_chat = '0' order by localpart limit ">>,integer_to_binary(Limit),<<" offset ">>,integer_to_binary(Offset),<<";">>]) of
    {selected,_Tab, Chats} ->
      Chats;
    _ -> []
  end,
  lists:map(
    fun(Chat) ->
      [Name,Owner,Number,Private] = Chat,
      {binary_to_list(Name),binary_to_list(Owner),binary_to_integer(Number),binary_to_integer(Private)} end, ChatInfo
  ).

get_count_chats(LServer) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    @(count(*))d from groupchats where %(LServer)H")) of
    {selected,[{Count}]} ->
      Count;
    _ ->
      0
  end.

create_groupchat(Server,Localpart,CreatorJid,Name,ChatJid,Anon,Search,Model,Desc,Message,Contacts,Domains,ParentChat) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL_INSERT(
      "groupchats",
      ["name=%(Name)s",
        "anonymous=%(Anon)s",
        "localpart=%(Localpart)s",
        "jid=%(ChatJid)s",
        "searchable=%(Search)s",
        "model=%(Model)s",
        "description=%(Desc)s",
        "message=%(Message)d",
        "contacts=%(Contacts)s",
        "domains=%(Domains)s",
        "owner=%(CreatorJid)s",
        "parent_chat=%(ParentChat)s",
        "server_host=%(Server)s"
        ])).

% Internal functions

check_if_not_p2p_exist(LServer,ParentChat,User1,User2) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(username)s,@(chatgroup)s from groupchat_users
    left join groupchats on chatgroup = jid
    where
    groupchats.parent_chat = %(ParentChat)s
    and (username = %(User1)s or username = %(User2)s) and %(LServer)H")) of
    {selected,[{null}]} ->
      true;
    {selected,[]} ->
      true;
    {selected,[{}]} ->
      true;
    {selected,List} ->
      check_if_not_duplicated(List)
  end.

check_if_not_duplicated(List) ->
  List1 = [C || {_U,C} <- List],
  List2 = lists:usort(List1),
  Len1 = length(List1),
  Len2 = length(List2),
  case Len1 of
    Len2 ->
      true;
    _ ->
      [Chat] = List1 -- List2,
      {false, Chat}
  end.

add_user_to_peer_to_peer_chat(LServer, User, NewChat,OldChat) ->
  {AvatarID,AvatarType,AvatarUrl,AvatarSize,Nickname,ParseAvatar,Badge} =
    mod_groupchat_users:get_user_info_for_peer_to_peer(LServer,User,OldChat),
  mod_groupchat_users:add_user_to_peer_to_peer_chat(LServer,User,NewChat,AvatarID,AvatarType,AvatarUrl,AvatarSize,Nickname,ParseAvatar,Badge),
  Nickname.

delete(Chat) ->
  ChatJID = jid:from_string(Chat),
  {Localpart,LServer,_} = jid:tolower(ChatJID),
  AllUserMeta = mod_groupchat_vcard:get_all_image_metadata(LServer,Chat),
  mod_groupchat_vcard:check_old_meta(LServer,AllUserMeta),
  delete_groupchat(LServer, Chat),
  delete_depended_chats(Chat, LServer),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from archive where username=%(Localpart)s and %(LServer)H")).

create_localpart() ->
  list_to_binary(
    [randoms:get_alphanum_string(2),randoms:get_string(),randoms:get_alphanum_string(3)]).

delete_depended_chats(ParentChat, LServer) ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from groupchats where parent_chat=%(ParentChat)s and %(LServer)H")).

get_depended_chats(ParentChat, LServer) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(localpart)s from groupchats
    where parent_chat = %(ParentChat)s and %(LServer)H")) of
    {selected,[{null}]} ->
      [];
    {selected,[]} ->
      [];
    {selected,[{}]} ->
      [];
    {selected,List} ->
      List
  end.

groupchat_exist(LUser, LServer) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(localpart)s from groupchats
    where localpart = %(LUser)s and %(LServer)H")) of
    {selected,[{null}]} ->
      false;
    {selected,[]} ->
      false;
    {selected,[{}]} ->
      false;
    _ ->
      true
  end.

delete_groupchat(LServer, Chat) ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from groupchats where jid=%(Chat)s")
  ).

get_chat_name(Chat,Server) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(name)s
    from groupchats where jid=%(Chat)s and %(Server)H")) of
    {selected,[{Name}]} ->
      Name;
    _ ->
      <<>>
  end.

get_detailed_information_of_chat(Chat,Server) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(name)s,@(anonymous)s,@(searchable)s,@(model)s,@(description)s,@(message)d,@(contacts)s,@(domains)s,@(parent_chat)s
    from groupchats where jid=%(Chat)s and %(Server)H")).

created(Name,ChatJid,Anonymous,Search,Model,Desc,Message,ContactList,DomainList) ->
  #xmlel{name = <<"created">>, attrs = [{<<"xmlns">>,?NS_GROUPCHAT}],
    children = mod_groupchat_inspector:chat_information(Name,ChatJid,Anonymous,Search,Model,Desc,Message,ContactList,DomainList)
  }.