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
-export([start/2, stop/1, depends/2, mod_options/1, mod_opt_type/1]).
-export([delete_chat/2, is_anonim/2, is_global_indexed/2, get_all/1, get_all_info/3, get_count_chats/1, get_depended_chats/2, get_detailed_information_of_chat/2]).
-export([check_creator/4, check_user/4, check_chat/4,create_peer_to_peer/4, send_invite/4, check_if_peer_to_peer_exist/4, groupchat_exist/2]).
-export([check_user_rights/4, decode/2, check_user_permission/5, validate_fs/5, change_chat/5,check_params/5, check_localpart/5, check_unsupported_stanzas/5,create_chat/5,
  get_chat_active/2,
  get_information_of_chat/2,
  count_users/2,
  get_all_information_chat/2,
  status_options/1
  ]).
start(Host, _Opts) ->
  ejabberd_hooks:add(create_groupchat, Host, ?MODULE, check_localpart, 10),
  ejabberd_hooks:add(create_groupchat, Host, ?MODULE, check_unsupported_stanzas, 15),
  ejabberd_hooks:add(create_groupchat, Host, ?MODULE, check_params, 25),
  ejabberd_hooks:add(create_groupchat, Host, ?MODULE, create_chat, 35),
  ejabberd_hooks:add(groupchat_info, Host, ?MODULE, check_user_rights, 10),
  ejabberd_hooks:add(groupchat_info_change, Host, ?MODULE, check_user_permission, 10),
  ejabberd_hooks:add(groupchat_info_change, Host, ?MODULE, validate_fs, 15),
  ejabberd_hooks:add(groupchat_info_change, Host, ?MODULE, change_chat, 20),
  ejabberd_hooks:add(groupchat_peer_to_peer, Host, ?MODULE, check_creator, 10),
  ejabberd_hooks:add(groupchat_peer_to_peer, Host, ?MODULE, check_chat, 15),
  ejabberd_hooks:add(groupchat_peer_to_peer, Host, ?MODULE, check_user, 20),
  ejabberd_hooks:add(groupchat_peer_to_peer, Host, ?MODULE, check_if_peer_to_peer_exist, 25),
  ejabberd_hooks:add(groupchat_peer_to_peer, Host, ?MODULE, create_peer_to_peer, 30),
  ejabberd_hooks:add(groupchat_peer_to_peer, Host, ?MODULE, send_invite, 40),
  ejabberd_hooks:add(groupchat_presence_unsubscribed_hook, Host, ?MODULE, delete_chat, 35).

stop(Host) ->
  ejabberd_hooks:delete(create_groupchat, Host, ?MODULE, check_localpart, 10),
  ejabberd_hooks:delete(create_groupchat, Host, ?MODULE, check_unsupported_stanzas, 15),
  ejabberd_hooks:delete(create_groupchat, Host, ?MODULE, check_params, 25),
  ejabberd_hooks:delete(create_groupchat, Host, ?MODULE, create_chat, 35),
  ejabberd_hooks:delete(groupchat_info, Host, ?MODULE, check_user_rights, 10),
  ejabberd_hooks:delete(groupchat_info_change, Host, ?MODULE, check_user_permission, 10),
  ejabberd_hooks:delete(groupchat_info_change, Host, ?MODULE, validate_fs, 15),
  ejabberd_hooks:delete(groupchat_info_change, Host, ?MODULE, change_chat, 20),
  ejabberd_hooks:delete(groupchat_peer_to_peer, Host, ?MODULE, check_creator, 10),
  ejabberd_hooks:delete(groupchat_peer_to_peer, Host, ?MODULE, check_chat, 15),
  ejabberd_hooks:delete(groupchat_peer_to_peer, Host, ?MODULE, check_user, 20),
  ejabberd_hooks:delete(groupchat_peer_to_peer, Host, ?MODULE, check_if_peer_to_peer_exist, 25),
  ejabberd_hooks:delete(groupchat_peer_to_peer, Host, ?MODULE, create_peer_to_peer, 30),
  ejabberd_hooks:delete(groupchat_peer_to_peer, Host, ?MODULE, send_invite, 40),
  ejabberd_hooks:delete(groupchat_presence_unsubscribed_hook, Host, ?MODULE, delete_chat, 35).

depends(_Host, _Opts) ->  [].

mod_opt_type(annihilation) ->
  fun (B) when is_boolean(B) -> B end.

mod_options(_Host) -> [{annihilation, true}].

check_localpart(_Acc,Server,_CreatorLUser,_CreatorLServer,SubEls) ->
  LocalPart = get_value(xabbergroupchat_localpart,SubEls),
  case LocalPart of
    undefined ->
      ok;
    _ ->
      case groupchat_exist(LocalPart,Server) of
        false ->
          ok;
        true ->
          {stop,exist}
      end
  end.

check_unsupported_stanzas(_Acc,_Server,_CreatorLUser,_CreatorLServer,SubEls) ->
  case lists:keyfind(xmlel,1,SubEls) of
    false ->
      ok;
    _ ->
      {stop,bad_request}
  end.

check_params(_Acc,_Server,_CreatorLUser,_CreatorLServer,SubEls) ->
  Privacy = set_value(<<"public">>,get_value(xabbergroupchat_privacy,SubEls)),
  Membership = set_value(<<"open">>,get_value(xabbergroupchat_membership,SubEls)),
  Index = set_value(<<"local">>,get_value(xabbergroupchat_index,SubEls)),
  IsPrivacyValid = validate_privacy(Privacy),
  IsMembershipValid = validate_membership(Membership),
  IsIndexValid = validate_index(Index),
  Length = str:len(list_to_binary(string:to_lower(binary_to_list(set_value(create_jid(),get_value(xabbergroupchat_localpart,SubEls)))))),
  case IsPrivacyValid of
    true when IsMembershipValid =/= false andalso IsIndexValid =/= false andalso Length > 0 ->
      ok;
    _ ->
      {stop, bad_request}
  end.

create_chat(_Acc, Server,CreatorLUser,CreatorLServer,SubEls) ->
  LocalPart = list_to_binary(string:to_lower(binary_to_list(set_value(create_jid(),get_value(xabbergroupchat_localpart,SubEls))))),
  Name = set_value(LocalPart,get_value(xabbergroupchat_name,SubEls)),
  Desc = set_value(<<>>,get_value(xabbergroupchat_description,SubEls)),
  Privacy = set_value(<<"public">>,get_value(xabbergroupchat_privacy,SubEls)),
  Membership = set_value(<<"open">>,get_value(xabbergroupchat_membership,SubEls)),
  Index = set_value(<<"local">>,get_value(xabbergroupchat_index,SubEls)),
  Contacts = make_string(set_value([],get_value(xabbergroup_contacts,SubEls))),
  Domains = make_string(set_value([],get_value(xabbergroup_domains,SubEls))),
  Chat = jid:to_string(jid:make(LocalPart,Server)),
  Creator = jid:to_string(jid:make(CreatorLUser,CreatorLServer)),
  case ejabberd_sql:sql_query(
    Server,
    ?SQL_INSERT(
      "groupchats",
      ["name=%(Name)s",
        "server_host=%(Server)s",
        "anonymous=%(Privacy)s",
        "localpart=%(LocalPart)s",
        "jid=%(Chat)s",
        "searchable=%(Index)s",
        "model=%(Membership)s",
        "description=%(Desc)s",
        "contacts=%(Contacts)s",
        "domains=%(Domains)s",
        "owner=%(Creator)s"])) of
    {updated,_N} ->
      mod_groupchat_inspector:add_user(Server,Creator,<<"owner">>,Chat,<<"wait">>),
      Expires = <<"1000 years">>,
      IssuedBy = <<"server">>,
      Permissions = get_permissions(Server),
      lists:foreach(fun(N)->
        {Rule} = N,
        mod_groupchat_restrictions:insert_rule(Server,Chat,Creator,Rule,Expires,IssuedBy) end,
        Permissions
      ),
    {stop,{ok,create_result_query(LocalPart,Name,Desc,Privacy,Membership,Index,Contacts,Domains),Chat,Creator}};
    _ ->
      {stop,exist}
  end.

check_user_rights(_Acc,User,Chat,Server) ->
  case mod_groupchat_restrictions:is_permitted(<<"administrator">>,User,Chat) of
    yes ->
      {stop, {ok,form_chat_information(Chat,Server,form)}};
    _ ->
      {stop, {ok,form_fixed_chat_information(Chat,Server)}}
  end.


%% groupchat_info_change hook
check_user_permission(_Acc,User,Chat,_Server,_FS) ->
  case mod_groupchat_restrictions:is_permitted(<<"administrator">>,User,Chat) of
    yes ->
      ok;
    _ ->
      {stop, not_allowed}
  end.

validate_fs(_Acc,_User,_Chat, LServer,FS) ->
  Decoded = decode(LServer,FS),
  case lists:member(false, Decoded) of
    true ->
      {stop, not_ok};
    _ when Decoded == [] ->
      {stop, not_ok};
    _ ->
      Decoded
  end.

change_chat(Acc,_User,Chat,Server,_FS) ->
  {selected,[{Name,_Anonymous,Search,Model,Desc,ChatMessage,ContactList,DomainList,Status}]} =
    get_information_of_chat(Chat,Server),
  NewName = set_value(Name,get_value(name,Acc)),
  NewDesc = set_value(Desc,get_value(description,Acc)),
  NewMessage = set_message(ChatMessage,get_value(message,Acc)),
  NewStatus = set_value(Status,get_value(status,Acc)),
  NewMembership = set_value(Model,get_value(membership,Acc)),
  NewIndex = set_value(Search,get_value(index,Acc)),
  NewContacts = set_value(ContactList,get_value(contacts,Acc)),
  NewDomains = set_value(DomainList,get_value(domains,Acc)),
  update_groupchat(Server,Chat,NewName,NewDesc,NewMessage,NewStatus,NewMembership,NewIndex,NewContacts,NewDomains),
  {stop, {ok,form_chat_information(Chat,Server,result),NewStatus}}.

%%

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
  DeleteChat = gen_mod:get_module_opt(LServer, ?MODULE, annihilation),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(username)s from groupchat_users where chatgroup = %(Chat)s and subscription = 'both'")) of
    {selected,[]} when DeleteChat == true->
      delete(Chat);
    {selected,[{}]} when DeleteChat == true ->
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

get_all_information_chat(Chat,Server) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(name)s,@(anonymous)s,@(searchable)s,@(model)s,@(description)s,@(message)d,@(contacts)s,@(domains)s,
    @(parent_chat)s,@(status)s
    from groupchats where jid=%(Chat)s and %(Server)H")).

created(Name,ChatJid,Anonymous,Search,Model,Desc,Message,ContactList,DomainList) ->
  #xmlel{name = <<"created">>, attrs = [{<<"xmlns">>,?NS_GROUPCHAT}],
    children = mod_groupchat_inspector:chat_information(Name,ChatJid,Anonymous,Search,Model,Desc,Message,ContactList,DomainList)
  }.


form_fixed_chat_information(Chat,LServer) ->
  Fields = get_fixed_chat_fields(Chat,LServer),
  #xdata{type = form, title = <<"Groupchat change">>, instructions = [<<"Fill out this form to change the group chat">>], fields = Fields}.

get_fixed_chat_fields(Chat,LServer) ->
  {selected,[{Name,Anonymous,Search,Model,Desc,Message,ContactList,DomainList,_ParentChat,Status}]} =
    get_all_information_chat(Chat,LServer),
  [
    #xdata_field{var = <<"FORM_TYPE">>, type = hidden, values = [?NS_GROUPCHAT]},
    #xdata_field{var = <<"name">>, type = 'fixed', values = [Name], label = <<"Name">>},
    #xdata_field{var = <<"privacy">>, type = fixed, values = [Anonymous], label = <<"Privacy">>},
    #xdata_field{var = <<"index">>, type = fixed, values = [Search], label = <<"Index">>},
    #xdata_field{var = <<"membership">>, type = fixed, values = [Model], label = <<"Membership">>},
    #xdata_field{var = <<"description">>, type = 'fixed', values = [Desc], label = <<"Description">>},
    #xdata_field{var = <<"pinned-message">>, type = 'fixed', values = [integer_to_binary(Message)], label = <<"Pinned message">>},
    #xdata_field{var = <<"contacts">>, type = 'fixed', values = [ContactList], label = <<"Contacts">>},
    #xdata_field{var = <<"domains">>, type = 'fixed', values = [DomainList], label = <<"Domains">>},
    #xdata_field{var = <<"status">>, type = 'fixed', values = [Status], label = <<"Status">>}
  ].

form_chat_information(Chat,LServer,Type) ->
  Fields = get_chat_fields(Chat,LServer),
  #xdata{type = Type, title = <<"Groupchat change">>, instructions = [<<"Fill out this form to change the group chat">>], fields = Fields}.

get_chat_fields(Chat,LServer) ->
  {selected,[{Name,_Anonymous,Search,Model,Desc,_Message,ContactList,DomainList,_ParentChat,Status}]} =
    get_all_information_chat(Chat,LServer),
  [
    #xdata_field{var = <<"FORM_TYPE">>, type = hidden, values = [?NS_GROUPCHAT]},
    #xdata_field{var = <<"pinned-message">>, type = hidden, values = [<<"true">>], label = <<"Change pinned message">>},
    #xdata_field{var = <<"change-avatar">>, type = hidden, values = [<<"true">>], label = <<"Change avatar">>},
    #xdata_field{var = <<"name">>, type = 'text-single', values = [Name], label = <<"Name">>},
    #xdata_field{var = <<"index">>, type = 'list-single', values = [Search], label = <<"Index">>, options = index_options()},
    #xdata_field{var = <<"membership">>, type = 'list-single', values = [Model], label = <<"Membership">>, options = membership_options()},
    #xdata_field{var = <<"description">>, type = 'text-multi', values = [Desc], label = <<"Description">>},
    #xdata_field{var = <<"contacts">>, type = 'jid-multi', values = [form_list(ContactList)], label = <<"Contacts">>},
    #xdata_field{var = <<"domains">>, type = 'jid-multi', values = [form_list(DomainList)], label = <<"Domains">>},
    #xdata_field{var = <<"status">>, type = 'list-single', values = [Status], label = <<"Status">>, options = status_options(LServer)}
    ].

-spec decode(binary(),list()) -> list().
decode(LServer,FS) ->
  decode(LServer,[],filter_fixed_fields(FS)).

decode(LServer,Acc,[#xdata_field{var = Var, values = Values} | RestFS]) ->
  decode(LServer,[get_and_validate(LServer,Var,Values)| Acc], RestFS);
decode(_LServer,Acc, []) ->
  Acc.

filter_fixed_fields(FS) ->
  lists:filter(fun(F) ->
    #xdata_field{type = Type} = F,
    case Type of
      fixed ->
        false;
      hidden ->
        false;
      _ ->
        true
    end
  end, FS).

-spec get_and_validate(binary(),binary(),list()) -> binary().
get_and_validate(_LServer,<<"description">>,Desc) ->
  {description,list_to_binary(Desc)};
get_and_validate(_LServer,<<"name">>,Name) ->
  {name,list_to_binary(Name)};
get_and_validate(_LServer,<<"pinned-message">>,PinnedMessage) ->
  {message,list_to_binary(PinnedMessage)};
get_and_validate(LServer,<<"status">>,Status) ->
  validate_status(LServer,list_to_binary(Status));
get_and_validate(_LServer,<<"index">>,Index) ->
  validate_index(list_to_binary(Index));
get_and_validate(_LServer,<<"membership">>,Membership) ->
  validate_membership(list_to_binary(Membership));
get_and_validate(_LServer,<<"contacts">>,Contacts) ->
  validate_contacts(Contacts);
get_and_validate(_LServer,<<"domains">>,Domains) ->
  validate_domains(Domains);
get_and_validate(_LServer,_Var,_Values) ->
  false.

validate_status(LServer,Status) ->
  ValidStatus = make_valid_status(LServer),
  case lists:member(Status,ValidStatus) of
    true ->
      {status,Status}
  end.

make_valid_status(LServer) ->
  AllStatus = status_options(LServer),
  lists:map(fun(El) ->
    #xdata_option{value = [Val]} = El,
    Val end, AllStatus
  ).

validate_privacy(<<"public">>) ->
  true;
validate_privacy(<<"incognito">>) ->
  true;
validate_privacy(_Value) ->
  false.

validate_membership(<<"open">>) ->
  {membership,<<"open">>};
validate_membership(<<"member-only">>) ->
  {membership,<<"member-only">>};
validate_membership(_Value) ->
  false.

validate_index(<<"none">>) ->
  {index,<<"none">>};
validate_index(<<"local">>) ->
  {index,<<"local">>};
validate_index(<<"global">>) ->
  {index,<<"global">>};
validate_index(_Value) ->
  false.

validate_contacts([]) ->
  {contacts, <<>>};
validate_contacts([<<>>]) ->
  {contacts, <<>>};
validate_contacts(Contacts) ->
  Validation = lists:map(fun(Contact) ->
    try jid:decode(Contact) of
      #jid{} ->
        true
    catch
      _:_ ->
        ?ERROR_MSG("Mailformed jid in request ~p",[Contact]),
        false
    end
 end, Contacts),
  HasWrongJID = lists:member(false,Validation),
  case HasWrongJID of
    false ->
      {contacts,make_string(Contacts)};
    _ ->
      false
  end.

validate_domains([]) ->
  {domains,<<>>};
validate_domains([<<>>]) ->
  {domains,<<>>};
validate_domains(Domains) ->
  Validation = lists:map(fun(Domain) ->
  jid:is_nodename(Domain)
                         end, Domains),
  HasWrongJID = lists:member(false,Validation),
  case HasWrongJID of
    false ->
      {domains,make_string(Domains)};
    _ ->
      false
  end.

-spec get_value(atom(), list()) -> term().
get_value(Atom,FS) ->
  case lists:keyfind(Atom,1,FS) of
    {Atom,Value} ->
      Value;
    _ ->
      undefined
  end.

set_value(Default,Value) ->
  case Value of
    undefined ->
      Default;
    _ ->
      Value
  end.

set_message(Default,Value) ->
  case Value of
    undefined ->
      Default;
    <<>> ->
      0;
    _ ->
      binary_to_integer(Value)
  end.

get_information_of_chat(Chat,Server) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(name)s,@(anonymous)s,@(searchable)s,@(model)s,@(description)s,@(message)d,@(contacts)s,@(domains)s,@(status)s
    from groupchats where jid=%(Chat)s and %(Server)H")).

update_groupchat(Server,Jid,Name,Desc,Message,Status,Membership,Index,Contacts,Domains) ->
  case ?SQL_UPSERT(Server, "groupchats",
    ["name=%(Name)s",
      "description=%(Desc)s",
      "message=%(Message)d",
      "status=%(Status)s",
      "model=%(Membership)s",
      "searchable=%(Index)s",
      "contacts=%(Contacts)s",
      "domains=%(Domains)s",
      "!jid=%(Jid)s"]) of
    ok ->
      ok;
    _Err ->
      {error, db_failure}
  end.

create_jid() ->
  list_to_binary(
    [randoms:get_alphanum_string(2),randoms:get_string(),randoms:get_alphanum_string(3)]).

get_permissions(Server) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(name)s from groupchat_rights where type = 'permission' ")) of
    {selected,[]} ->
      [];
    {selected,[{}]} ->
      [];
    {selected,Permissions} ->
      Permissions
  end.

get_chat_active(Server,Chat) ->
  case   ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(status)s
    from groupchats where jid=%(Chat)s and %(Server)H")) of
    {selected,[{Status}]} ->
      Status;
    _ ->
      false
  end.

count_users(LServer,Chat) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(count(username))d from groupchat_users where chatgroup = %(Chat)s ")) of
    {selected,[]} ->
      [];
    {selected,[{}]} ->
      [];
    {selected,[{Count}]} ->
      Count;
    Other ->
    Other
  end.

create_result_query(LocalPart,Name,Desc,Privacy,Membership,Index,Contacts,Domains) ->
  SubEls = [
    #xabbergroupchat_localpart{cdata = LocalPart},
    #xabbergroupchat_name{cdata = Name},
    #xabbergroupchat_description{cdata = Desc},
    #xabbergroupchat_privacy{cdata = Privacy},
    #xabbergroupchat_membership{cdata = Membership},
    #xabbergroupchat_index{cdata = Index},
    #xabbergroup_domains{domain = lists:usort(Domains)},
    #xabbergroup_contacts{contact = lists:usort(Contacts)}
  ],
  #xabbergroupchat{xmlns = ?NS_GROUPCHAT_CREATE,sub_els = SubEls}.

status_options(LServer) ->
  Predefined = [
    #xdata_option{label = <<"Ready for chat">>, value = [<<"chat">>]},
    #xdata_option{label = <<"Online">>, value = [<<"active">>]},
    #xdata_option{label = <<"Away">>, value = [<<"away">>]},
    #xdata_option{label = <<"Away for long time">>, value = [<<"xa">>]},
    #xdata_option{label = <<"Busy">>, value = [<<"dnd">>]},
    #xdata_option{label = <<"Inactive">>, value = [<<"inactive">>]}],
  Result = ejabberd_hooks:run_fold(chat_status_options, LServer, Predefined, []),
  Result.

membership_options() ->
  [#xdata_option{label = <<"Member-only">>, value = <<"member-only">>}, #xdata_option{label = <<"Open">>, value = <<"open">>}].

index_options() ->
  [#xdata_option{label = <<"None">>, value = [<<"none">>]},#xdata_option{label = <<"Local">>, value = [<<"local">>]},#xdata_option{label = <<"Global">>, value = [<<"global">>]}].

make_string(List) ->
  SortedList = lists:usort(List),
  list_to_binary(lists:map(fun(N)-> [N|[<<",">>]] end, SortedList)).

form_list(Elements) ->
  Splited = binary:split(Elements,<<",">>,[global]),
  Empty = [X||X <- Splited, X == <<>>],
  NotEmpty = Splited -- Empty,
  NotEmpty.