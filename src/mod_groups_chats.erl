%%%-------------------------------------------------------------------
%%% File    : mod_groups_chats.erl
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

-module(mod_groups_chats).
-author('andrey.gagarin@redsolution.com').
-behavior(gen_mod).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).
%% API
-export([start/2, stop/1, depends/2, mod_options/1]).

-export([maybe_delete_group/2, is_anonim/2, is_global_indexed/2, get_all_groups_info/1, get_all_info/3,
  get_count_chats/1, get_type_and_parent/2, update_user_counter/1]).

-export([check_creator/4, check_user/4, check_chat/4,
  create_peer_to_peer/4, send_invite/4, check_if_users_invited/4,
  check_if_peer_to_peer_exist/4, groupchat_exist/2, create_groupchat/13]).

-export([check_user_rights/4, decode/3, check_user_permission/5, validate_fs/5, handle_update_query/4,
  change_chat/5, check_create_query/5, create_chat/3, create_chat/5,
  get_chat_active/2, get_info/2, db_get_info/2, count_users/2,
  get_name_desc/2, define_human_status/3]).

-export([parse_status_query/2, filter_fixed_fields/1, define_human_status_and_show/3]).
% Status hooks
-export([check_user_rights_to_change_status/4, check_user_rights_to_change_status/5, check_status/5]).
% Delete chat hook
-export([delete_chat_hook/4]).
%% Search
-export([search/7]).

-define(DEFAULT_GROUP_STATUS, <<"discussion">>).

start(Host, _Opts) ->
  ejabberd_hooks:add(delete_groupchat, Host, ?MODULE, delete_chat_hook, 30),
  ejabberd_hooks:add(create_groupchat, Host, ?MODULE, check_create_query, 10),
  ejabberd_hooks:add(create_groupchat, Host, ?MODULE, create_chat, 50),
  ejabberd_hooks:add(groupchat_info, Host, ?MODULE, check_user_rights, 10),
  ejabberd_hooks:add(group_status_info, Host, ?MODULE, check_user_rights_to_change_status, 10),
  ejabberd_hooks:add(group_status_change, Host, ?MODULE, check_user_rights_to_change_status, 10),
  ejabberd_hooks:add(group_status_change, Host, ?MODULE, check_status, 20),
  ejabberd_hooks:add(groupchat_info_change, Host, ?MODULE, check_user_permission, 10),
  ejabberd_hooks:add(groupchat_info_change, Host, ?MODULE, validate_fs, 15),
  ejabberd_hooks:add(groupchat_info_change, Host, ?MODULE, change_chat, 20),
  ejabberd_hooks:add(groupchat_peer_to_peer, Host, ?MODULE, check_creator, 10),
  ejabberd_hooks:add(groupchat_peer_to_peer, Host, ?MODULE, check_chat, 15),
  ejabberd_hooks:add(groupchat_peer_to_peer, Host, ?MODULE, check_user, 20),
  ejabberd_hooks:add(groupchat_peer_to_peer, Host, ?MODULE, check_if_peer_to_peer_exist, 25),
  ejabberd_hooks:add(groupchat_peer_to_peer, Host, ?MODULE, check_if_users_invited, 27),
  ejabberd_hooks:add(groupchat_peer_to_peer, Host, ?MODULE, create_peer_to_peer, 30),
  ejabberd_hooks:add(groupchat_peer_to_peer, Host, ?MODULE, send_invite, 40),
  ejabberd_hooks:add(groupchat_presence_unsubscribed_hook, Host, ?MODULE, maybe_delete_group, 35).

stop(Host) ->
  ejabberd_hooks:delete(group_status_info, Host, ?MODULE, check_user_rights_to_change_status, 10),
  ejabberd_hooks:delete(group_status_change, Host, ?MODULE, check_user_rights_to_change_status, 10),
  ejabberd_hooks:delete(group_status_change, Host, ?MODULE, check_status, 20),
  ejabberd_hooks:delete(delete_groupchat, Host, ?MODULE, delete_chat_hook, 30),
  ejabberd_hooks:delete(create_groupchat, Host, ?MODULE, check_create_query, 10),
  ejabberd_hooks:delete(create_groupchat, Host, ?MODULE, create_chat, 50),
  ejabberd_hooks:delete(groupchat_info, Host, ?MODULE, check_user_rights, 10),
  ejabberd_hooks:delete(groupchat_info_change, Host, ?MODULE, check_user_permission, 10),
  ejabberd_hooks:delete(groupchat_info_change, Host, ?MODULE, validate_fs, 15),
  ejabberd_hooks:delete(groupchat_info_change, Host, ?MODULE, change_chat, 20),
  ejabberd_hooks:delete(groupchat_peer_to_peer, Host, ?MODULE, check_creator, 10),
  ejabberd_hooks:delete(groupchat_peer_to_peer, Host, ?MODULE, check_chat, 15),
  ejabberd_hooks:delete(groupchat_peer_to_peer, Host, ?MODULE, check_user, 20),
  ejabberd_hooks:delete(groupchat_peer_to_peer, Host, ?MODULE, check_if_peer_to_peer_exist, 25),
  ejabberd_hooks:delete(groupchat_peer_to_peer, Host, ?MODULE, check_if_users_invited, 27),
  ejabberd_hooks:delete(groupchat_peer_to_peer, Host, ?MODULE, create_peer_to_peer, 30),
  ejabberd_hooks:delete(groupchat_peer_to_peer, Host, ?MODULE, send_invite, 40),
  ejabberd_hooks:delete(groupchat_presence_unsubscribed_hook, Host, ?MODULE, maybe_delete_group, 35).

depends(_Host, _Opts) ->  [].

mod_options(_Host) -> [].

% delete chat hook
delete_chat_hook(_Acc, _LServer, _User, Chat) ->
  delete_group(Chat, false),
  {stop, ok}.

check_create_query(_Acc,Server,_CreatorLUser,_CreatorLServer,SubEls) ->
  LocalPart = case get_value(xabbergroupchat_localpart,SubEls) of
                B when is_binary(B) ->
                  case jid:nodeprep(str:strip(B)) of
                    error -> <<>>;
                    LP -> LP
                  end;
                A -> A
              end,
  case LocalPart of
    undefined ->
      ok;
    <<>> ->
      {stop, bad_request};
    _ ->
      case mod_xabber_entity:is_exist_anywhere(LocalPart,Server) of
        false ->
          check_params(SubEls);
        true ->
          {stop,exist}
      end
  end.

check_params(SubEls) ->
  Privacy = set_value(<<"public">>,get_value(xabbergroupchat_privacy,SubEls)),
  Membership = set_value(<<"open">>,get_value(xabbergroupchat_membership,SubEls)),
  Index = set_value(<<"local">>,get_value(xabbergroupchat_index,SubEls)),
  IsPrivacyValid = validate_privacy(Privacy),
  IsMembershipValid = validate_membership(Membership),
  IsIndexValid = validate_index(Index),
   if
     IsPrivacyValid
       andalso IsMembershipValid /= false
       andalso IsIndexValid /= false ->
       ok;
     true ->
       {stop, bad_request}
   end.

%% create chat hook
create_chat(_Acc, Server, CreatorLUser, CreatorLServer, SubEls)->
  Creator = jid:to_string(jid:make(CreatorLUser,CreatorLServer)),
  case create_chat(Server, Creator, SubEls) of
    exist -> {stop, exist};
    error -> {stop, error};
    R -> R
  end.

create_chat(Server, <<>>, SubEls) ->
  error;
create_chat(Server, Creator, SubEls) ->
  LocalPart = case get_value(xabbergroupchat_localpart,SubEls) of
                undefined -> create_localpart();
                V -> jid:nodeprep(str:strip(V))
              end,
  Name = set_value(LocalPart,get_value(xabbergroupchat_name,SubEls)),
  Desc = set_value(<<>>,get_value(xabbergroupchat_description,SubEls)),
  Privacy = set_value(<<"public">>,get_value(xabbergroupchat_privacy,SubEls)),
  Membership = set_value(<<"open">>,get_value(xabbergroupchat_membership,SubEls)),
  Index = set_value(<<"local">>,get_value(xabbergroupchat_index,SubEls)),
  ContactList = set_value([],get_value(xabbergroup_contacts,SubEls)),
  Contacts = make_string(ContactList),
  DomainList = set_value([],get_value(xabbergroup_domains,SubEls)),
  Domains = make_string(DomainList),
  Chat = jid:to_string(jid:make(LocalPart,Server)),
  Status = ?DEFAULT_GROUP_STATUS,
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
        "status=%(Status)s",
        "owner=%(Creator)s"])) of
    {updated,_N} ->
      Info = #{name => Name, description => Desc, privacy => Privacy,
        membership => Membership, index => Index, message => 0,
        contacts => Contacts, domains => Domains, parent => <<"0">>,
        user_count => <<"1">>, gstatus => Status},
      groups_sm:activate(Server, LocalPart, Info),
      mod_groups_users:add_user(Server,Creator,<<"owner">>,Chat,<<"both">>,Creator),
      Expires = <<"0">>,
      IssuedBy = <<"server">>,
      Permissions = get_permissions(Server),
      lists:foreach(fun(N)->
        {Rule} = N,
        mod_groups_restrictions:insert_rule(Server,Chat,Creator,Rule,Expires,IssuedBy) end,
        Permissions
      ),
      Result = create_result_query(LocalPart, Name, Desc, Privacy, Membership, Index,
        ContactList, DomainList),
      {ok, Result, Chat, Creator};
    _ ->
      exist
  end.

check_user_rights(_Acc,User,Chat,Server) ->
  case mod_groups_restrictions:is_permitted(<<"change-group">>,User,Chat) of
    true ->
      {stop, {ok,form_chat_information(Chat,Server,form)}};
    _ ->
      {stop, {error,xmpp:err_not_allowed(<<"You are not allowed to change group properties">>, <<"en">>)}}
  end.

handle_update_query(_, _, _, #xabbergroupchat_update{owner = NewOwner})
  when NewOwner /= undefined ->
  %% It was deprecated a long time ago.
  {error, xmpp:err_feature_not_implemented()};
handle_update_query(Server, Group, User, XElem) ->
  Pinned = case XElem#xabbergroupchat_update.pinned of
             #xabbergroupchat_pinned_message{cdata = Cdata} ->
               Cdata;
             _ ->
               undefined
           end,
  case Pinned of
    undefined ->
      {error, xmpp:err_bad_request()};
    _ ->
      change_pinned_msg(Server, Group, User, Pinned)
  end.

change_pinned_msg(Server, Group, User, MsgID) ->
  {_, _, _, _, _, Message, _, _, _, Status} = db_get_info(Group, Server),
  NewMessage = case MsgID of
                 <<>> -> 0;
                 _ -> binary_to_integer(MsgID)
               end,
  case {Status, NewMessage} of
    {<<"inactive">>, _} ->
      {error, xmpp:err_not_allowed(<<"You need to active group">>,
        <<"en">>)};
    {_, Message} ->
      ok;
    _ ->
      sql_update_pinned(Server, Group, NewMessage),
      groups_sm:update_group_session_info(Group,#{message => NewMessage}),
      Properties = [{pinned_changed, true}, {pinned_changed_notify, (NewMessage /= 0)}],
      ejabberd_hooks:run(groupchat_properties_changed,
        Server,[Server, Group, User, Properties, Status]),
      ok
  end.

%% groupchat_info_change hook
check_user_permission(_Acc,User,Chat,_Server,_FS) ->
  case mod_groups_restrictions:is_permitted(<<"change-group">>,User,Chat) of
    true ->
      ok;
    _ ->
      {stop, {error, xmpp:err_not_allowed()}}
  end.

validate_fs(_Acc,_User, Chat, LServer,FS) ->
  Decoded = decode(LServer,Chat,FS),
  case lists:member(false, Decoded) of
    true ->
      {stop, not_ok};
    _ when Decoded == [] ->
      {stop, not_ok};
    _ ->
      Decoded
  end.

change_chat(Acc,_User,Chat,Server,_FS) ->
  case get_chat_active(Server, Chat) of
    <<"inactive">> ->
      {stop, {error, xmpp:err_not_allowed(<<"You need to active group">>,<<"en">>)}};
    _ ->
      {Name, _Privacy, Search, Model, Desc, _Message,
        ContactList, DomainList, _Parent, Status} = db_get_info(Chat, Server),
      NewName = set_value(Name,get_value(name,Acc)),
      NewDesc = set_value(Desc,get_value(description,Acc)),
      NewMembership = set_value(Model,get_value(membership,Acc)),
      NewIndex = set_value(Search,get_value(index,Acc)),
      NewContacts = set_value(ContactList,get_value(contacts,Acc)),
      NewDomains = set_value(DomainList,get_value(domains,Acc)),
      IsNameChanged = {name_changed, Name /= NewName},
      IsDescChanged = {desc_changed, Desc /= NewDesc},
      IsIndexChanged = {index, NewIndex},
      IsOtherChanged = {properties_changed,
        lists:member(true,[
          Search /= NewIndex,
          Model /= NewMembership,
          DomainList /= NewDomains,
          ContactList /= NewContacts])},
      ChangeDiff = [IsNameChanged,IsDescChanged, IsIndexChanged, IsOtherChanged],
      NewInfo = #{name => NewName, description => NewDesc,
        membership => NewMembership, index => NewIndex,
        contacts => NewContacts, domains => NewDomains},
      sql_update_groupchat(Server, Chat, NewInfo),
      groups_sm:update_group_session_info(Chat, NewInfo),
      {stop, {ok,form_chat_information(Chat,Server,result),Status,ChangeDiff}}
  end.

check_creator(_Acc, LServer, Creator,  #xabbergroup_peer{jid = ChatJID}) ->
  ?DEBUG("start fold ~p ~p ~p", [LServer,Creator, ChatJID]),
  Chat = jid:to_string(ChatJID),
  case mod_groups_users:check_user(LServer, Creator, Chat) of
    not_exist ->
      ?DEBUG("User not exist ~p",[Creator]),
      {stop,not_exist};
    _ ->
      ?DEBUG("User exist ~p",[Creator]),
      ok
  end.

check_chat(_Acc, LServer, _Creator,  #xabbergroup_peer{jid = ChatJID}) ->
  Chat = jid:to_string(ChatJID),
  case get_type_and_parent(LServer,Chat) of
    {ok, <<"incognito">>, <<>>} -> ok;
    _ -> {stop, notallowed}
  end.

check_user(_Acc, LServer, Creator,  #xabbergroup_peer{jid = ChatJID, id = UserID}) ->
  Chat = jid:to_string(ChatJID),
  case mod_groups_users:get_user_by_id_and_allow_to_invite(LServer,Chat,UserID) of
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
  case get_p2p_chat(LServer,Chat,Creator,User) of
    notexist ->
      User;
    ExistedChat ->
      {exist,ExistedChat,User}
  end.

check_if_users_invited(Acc, LServer, Creator,  #xabbergroup_peer{jid = ChatJID}) ->
  case Acc of
    {exist,ExistedChat,User} ->
      Chat = jid:to_string(ChatJID),
      CreatorSubscription = mod_groups_users:check_user_if_exist(LServer,Creator,ExistedChat),
      UserSubscription = mod_groups_users:check_user_if_exist(LServer,User,ExistedChat),
      if
        UserSubscription == <<"none">>; UserSubscription == <<"wait">> ->
          send_invite_to_p2p(LServer,Creator,User,ExistedChat,Chat);
        true ->
          ok
      end,
      if
        CreatorSubscription == <<"none">>; CreatorSubscription == <<"wait">> ->
          {LocalPart, _, _} = jid:tolower(jid:from_string(ExistedChat)),
          Created = create_result_query(LocalPart,<<"Private chat">>,<<"Private chat">>,
            <<"incognito">>,<<"member-only">>,<<"none">>,[],[]),
          {stop,{ok,Created}};
        true ->
          {stop,{exist,ExistedChat}}
      end;
    _ ->
      Acc
  end.

create_peer_to_peer(User, LServer, Creator, #xabbergroup_peer{jid = ChatJID}) ->
  Localpart = create_localpart(),
  OldChat = jid:to_string(jid:remove_resource(ChatJID)),
  Chat = jid:to_string(jid:make(Localpart,LServer)),
  User1Nick = mod_groups_users:get_nick_in_chat(LServer,Creator,OldChat),
  User2Nick = mod_groups_users:get_nick_in_chat(LServer,User,OldChat),
  ChatName = <<User1Nick/binary," and ",User2Nick/binary, " chat">>,
  Desc = <<"Private chat">>,
  Privacy = <<"incognito">>,
  Membership = <<"member-only">>,
  Index = <<"none">>,
  create_groupchat(LServer, Localpart, Creator, ChatName, Chat,
    Privacy, Index, Membership, Desc, 0, <<"">>, <<"">>, OldChat),
  Info = #{name => ChatName, description => Desc, privacy => Privacy,
    membership => Membership, index => Index, message => 0,
    contacts => <<>>, domains => <<>>, parent => OldChat, user_count => <<"0">>,
    gstatus => ?DEFAULT_GROUP_STATUS},
  groups_sm:activate(LServer, Localpart, Info),
  Info1 = add_user_to_peer_to_peer_chat(LServer, User, Chat, OldChat),
  Info2 = add_user_to_peer_to_peer_chat(LServer, Creator, Chat, OldChat),
  Expires = <<"0">>,
  IssuedBy = <<"server">>,
  Rule = <<"send-invitations">>,
  mod_groups_restrictions:insert_rule(LServer,Chat,User,Rule,Expires,IssuedBy),
  mod_groups_restrictions:insert_rule(LServer,Chat,Creator,Rule,Expires,IssuedBy),
  mod_groups_vcard:create_p2p_avatar(LServer,Chat,element(3,Info1),element(3,Info2)),
  {User,Chat, ChatName, Desc, User1Nick, User2Nick, OldChat, ChatJID}.

send_invite({User,Chat, ChatName, Desc, User1Nick, User2Nick, OldChat, OldChatJID}, LServer, _Creator, _X) ->
  Anonymous = <<"incognito">>,
  Search = <<"none">>,
  Model = <<"member-only">>,
  OldChatName = get_chat_name(OldChat,LServer),
  BareOldChatJID = jid:remove_resource(OldChatJID),
  Privacy = #xabbergroupchat_privacy{cdata = Anonymous},
  Membership = #xabbergroupchat_membership{cdata = Model},
  Description = #xabbergroupchat_description{cdata = Desc},
  Index = #xabbergroupchat_index{cdata = Search},
  SubEls = [Privacy, Membership, Description, Index],
  ChatInfo = #xabbergroupchat_x{parent = BareOldChatJID, sub_els = SubEls},
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
    from = jid:replace_resource(ChatJID,<<"Group">>),
    to = jid:from_string(User),
    body = [#text{lang = <<>>,data = Text}],
    sub_els = [Invite,ChatInfo]},
  ejabberd_router:route(Message),
  SubEls1 = [#xabbergroupchat_localpart{cdata = ChatJID#jid.luser},
    #xabbergroupchat_name{cdata = ChatName}],
  Created = #xabbergroupchat{xmlns = ?NS_GROUPCHAT_CREATE,sub_els = SubEls ++ SubEls1},
  {ok, Created}.

send_invite_to_p2p(LServer,Creator,User,Chat,OldChat) ->
  User1Nick = mod_groups_users:get_nick_in_chat(LServer,Creator,OldChat),
  User2Nick = mod_groups_users:get_nick_in_chat(LServer,User,OldChat),
  ChatName = <<User1Nick/binary," and ",User2Nick/binary, " chat">>,
  Desc = <<"Private chat">>,
  OldChatJID = jid:from_string(OldChat),
  Anonymous = <<"incognito">>,
  Search = <<"none">>,
  Model = <<"member-only">>,
  OldChatName = get_chat_name(OldChat,LServer),
  BareOldChatJID = jid:remove_resource(OldChatJID),
  Name = #xabbergroupchat_name{cdata = ChatName},
  Privacy = #xabbergroupchat_privacy{cdata = Anonymous},
  Membership = #xabbergroupchat_membership{cdata = Model},
  Description = #xabbergroupchat_description{cdata = Desc},
  Index = #xabbergroupchat_index{cdata = Search},
  ChatInfo = #xabbergroupchat_x{parent = BareOldChatJID, sub_els = [Name, Privacy, Membership, Description, Index]},
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
    from = jid:replace_resource(ChatJID,<<"Group">>),
    to = jid:from_string(User),
    body = [#text{lang = <<>>,data = Text}],
    sub_els = [Invite,ChatInfo]},
  ejabberd_router:route(Message).

maybe_delete_group(_Acc,{LServer, _User, Group, _UserCard, _Lang})->
  Result =
    case get_type_and_parent(LServer, Group) of
      {ok, _, Parent} when Parent /= <<>> ->
        delete_group(Group, true);
      _ ->
        case mod_groups:get_option(LServer, remove_empty) of
          true ->
            case sql_get_user_count(LServer, Group) of
              <<"0">> ->
                delete_group(Group, false);
              _ -> pass
            end;
          _ ->
            pass
        end
    end,
  case Result of
    pass ->
      case mod_groups_restrictions:get_owners(LServer, Group) of
        [] -> delete_group(Group, false);
        _ -> ok
      end;
    _ -> ok
  end,
  ok.

is_anonim(LServer,Chat) ->
  case get_type_and_parent(LServer, Chat) of
    {ok, <<"incognito">>, _} -> true;
    _ -> false
  end.

get_type_and_parent(LServer,Chat) ->
  case get_info(Chat, LServer) of
    {_, Privacy, _, _, _, _, _, _, <<"0">>, _} ->
      {ok, Privacy, <<>>};
    {_, Privacy, _, _, _, _, _, _, Parent, _} ->
      {ok, Privacy, Parent};
    _ ->
      {error, notexist}
  end.

is_global_indexed(LServer,Chat) ->
  try element(3,get_info(Chat, LServer)) of
    <<"global">> -> true;
    _ -> false
  catch
    _:_ -> false
  end.

get_all_groups_info(LServer) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(localpart)s, @(name)s, @(anonymous)s, @(searchable)s, "
    " @(model)s, @(description)s, @(message)d, @(contacts)s, "
    " @(domains)s, @(parent_chat)s,@(status)s, "
    " @((select count(*) from groupchat_users where chatgroup = t.jid and subscription = 'both'))s"
    " from groupchats t where %(LServer)H")) of
    {selected, List} ->
      lists:map(fun(Item)->
        {LocalPart, Name, Privacy, Index, Membership, Desc, Message,
          Contacts, Domains, Parent, Status, Count} = Item,
        {{LocalPart, LServer, <<"Group">>},
          #{name => Name, description => Desc, privacy => Privacy,
            membership => Membership, index => Index,
            message => Message, contacts => Contacts,
            domains => Domains, parent => Parent,
            gstatus => Status, user_count => Count}
        }
                end, List);
    _ -> error
  end.
%%
get_all_info(LServer,Limit,Page) ->
  Offset = case Page of
             _  when Page > 0 ->
               Limit * (Page - 1)
           end,
  Query = case ejabberd_sql:use_new_schema() of
            true ->
              [<<"select localpart,owner,(select count(*)
              from groupchat_users where chatgroup = t.jid
              and subscription = 'both') as count, anonymous
              from groupchats t
              where t.parent_chat = '0' and server_host = '">>,LServer,<<"'
              order by localpart limit ">>,
                integer_to_binary(Limit),<<" offset ">>,integer_to_binary(Offset),<<";">>];
            _ ->
              [<<"select localpart,owner,(select count(*)
               from groupchat_users where chatgroup = t.jid
               and subscription = 'both') as count, anonymous
               from groupchats t
               where t.parent_chat = '0'
               order by localpart limit ">>,
                integer_to_binary(Limit),<<" offset ">>,integer_to_binary(Offset),<<";">>]
          end,
  ChatInfo = case ejabberd_sql:sql_query(
    LServer, Query
    ) of
    {selected,_Tab, Chats} ->
      Chats;
    _ -> []
  end,
  lists:map(
    fun([Name,Owner,Number,Privacy]) ->
      {Name,Owner,binary_to_integer(Number),Privacy}
    end, ChatInfo).

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

%%%%
%%  Search for group chats
%%%%
search(Server,Name,Anonymous,Model,Desc,UserJid,UserHost)->
  NameS = set_value(<<>>,Name),
  AnonymousS = set_value(<<>>,Anonymous),
  ModelS = set_value(<<>>,Model),
  DescS = set_value(<<>>,Desc),
  {selected,_Titles,Rows} =
    search_and_count_chats(Server,NameS,AnonymousS,ModelS,DescS,UserJid,UserHost),
  Children = lists:map(fun(N) ->
    [ChatJidQ,NameQ,AnonymousQ,ModelQ,DescQ,ContactListQ,DomainListQ,Count] = N,
    item_chat(ChatJidQ,NameQ,AnonymousQ,ModelQ,DescQ,ContactListQ,DomainListQ,Count) end,
    Rows
  ),
  query(Children).

search_and_count_chats(Server,Name,Anonymous,_Model,Desc,UserJid,UserHost) ->
  ejabberd_sql:sql_query(
    Server,
    [<<"select chatgroup,name,anonymous,model,description,contacts,domains,count(*)
    from groupchat_users inner join groupchats on jid=chatgroup
    where chatgroup IN ((select jid from groupchats
    where model='open' and (
    name like '%">>,Name,<<"%' and anonymous like '%">>,Anonymous,<<"%' and description like '%">>,Desc,<<"%'
    )
    EXCEPT select chatgroup from groupchat_block
    where blocked = '">>,UserJid,<<"' or blocked = '">>,UserHost,<<"')
   UNION (select jid from groupchats where model='member-only' and (
    name like '%">>,Name,<<"%' and anonymous like '%">>,Anonymous,<<"%' and description like '%">>,Desc,<<"%'
    )
   INTERSECT select chatgroup from groupchat_users where username = '">>,UserJid,<<"'))
   GROUP BY chatgroup,name,anonymous,model,description,contacts,domains ORDER BY chatgroup DESC">>
    ]).

query(Children) ->
  #xmlel{name = <<"query">>, attrs = [{"xmlns",?NS_GROUPCHAT}], children = Children}.

item_chat(ChatJidQ,NameQ,AnonymousQ,ModelQ,DescQ,_ContactListQ,_DomainListQ,Count) ->
  #xmlel{name = <<"item">>, children =
  [
    #xmlel{name = <<"jid">>, children = [{xmlcdata,ChatJidQ}]},
    #xmlel{name = <<"name">>, children = [{xmlcdata,NameQ}]},
    #xmlel{name = <<"anonymous">>, children = [{xmlcdata,AnonymousQ}]},
    #xmlel{name = <<"model">>, children = [{xmlcdata,ModelQ}]},
    #xmlel{name = <<"description">>, children = [{xmlcdata,DescQ}]},
    #xmlel{name = <<"member-count">>, children = [{xmlcdata,Count}]}
  ]}.
%%%%
%%  End of search for group chats
%%%%

% Internal functions

get_p2p_chat(LServer,ParentChat,User1,User2) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(jid)s from groupchats where parent_chat = %(ParentChat)s "
    " and (select count(*) from groupchat_users where "
    " username in (%(User1)s,%(User2)s) and chatgroup = jid) = 2 "
    " and %(LServer)H")) of
    {selected,[{Chat}]} ->
      Chat;
    _ ->
      notexist
  end.

add_user_to_peer_to_peer_chat(LServer, User, NewChat,OldChat) ->
%%  Info = {AvatarID,AvatarType,AvatarUrl,AvatarSize,Nickname,ParseAvatar,Badge}
  Info = mod_groups_users:get_user_info_for_peer_to_peer(LServer,User,OldChat),
  mod_groups_users:add_user_to_peer_to_peer_chat(LServer,User,NewChat, Info),
  Info.


delete_group(Chat, IsP2P) ->
  {LocalPart, LServer,_} = jid:tolower(jid:from_string(Chat)),
  case IsP2P of
    false ->
      lists:foreach(fun(G)->
        delete_group(G, true)
                    end,
        get_dependent_groups(LServer, Chat));
    _ -> ok
  end,
  groups_sm:deactivate(LServer,LocalPart),
  AllUserMeta = mod_groups_vcard:get_all_image_metadata(LServer,Chat),
  mod_groups_users:unsubscribe_all_for_delete(LServer, Chat),
  mod_groups_presence:delete_all_sessions(Chat),
  sql_delete_group(LServer, Chat),
%%  delete archive
  mod_mam:remove_user(LocalPart, LServer),
%%  delete user avatars
  mod_groups_vcard:maybe_delete_file(LServer,AllUserMeta),
%%  delete group avatar
  mod_groups_vcard:delete_group_avatar_file(Chat).

create_localpart() ->
  S = list_to_binary(
    [randoms:get_alphanum_string(2),randoms:get_string(),randoms:get_alphanum_string(3)]),
  case jid:nodeprep(S) of
    error -> create_localpart();
    LP -> LP
  end.


get_dependent_groups(LServer, Chat) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(jid)s from groupchats
    where parent_chat = %(Chat)s and %(LServer)H")) of
    {selected, Groups} -> [G || {G} <- Groups];
    _ ->
      []
  end.

groupchat_exist(LUser, LServer) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(localpart)s from groupchats
    where localpart = %(LUser)s and %(LServer)H")) of
    {selected, []} ->
      false;
    {selected, _} ->
      true;
    _ ->
      true
  end.

sql_delete_group(LServer, Chat) ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from groupchats where jid=%(Chat)s and %(LServer)H")
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

db_get_info(Group, Server) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(name)s, @(anonymous)s, @(searchable)s, "
    " @(model)s, @(description)s, @(message)d, @(contacts)s, "
    " @(domains)s, @(parent_chat)s,@(status)s "
    " from groupchats where jid=%(Group)s and %(Server)H")) of
    {selected,[Info]} -> Info;
    _ -> error
  end.

get_info(Group, _Server) ->
  {LUser, LServer, _} = jid:tolower(jid:from_string(Group)),
  case ejabberd_sm:get_user_info(LUser, LServer, <<"Group">>) of
    offline -> error;
    Info ->
      #{name := Name, description := Desc, privacy := Privacy,
        membership := Membership, index := Index,
        message := Message, contacts := Contacts,
        domains := Domains, parent := Parent,
        gstatus := Status} = maps:from_list(Info),
      {Name, Privacy, Index, Membership, Desc, Message, Contacts,
        Domains, Parent, Status}
  end.

form_chat_information(Chat,LServer,Type) ->
  Fields = get_chat_fields(Chat,LServer),
  #xdata{type = Type, title = <<"Group change">>, instructions = [<<"Fill out this form to change the group properties">>], fields = Fields}.

get_chat_fields(Chat,LServer) ->
  {Name, _Anonymous, Search, Model, Desc, _ChatMessage, ContactList,
    DomainList, _Parent, _Status} = get_info(Chat, LServer),
  [
    #xdata_field{var = <<"FORM_TYPE">>, type = hidden, values = [?NS_GROUPCHAT]},
    #xdata_field{var = <<"name">>, type = 'text-single', values = [Name], label = <<"Name">>},
    #xdata_field{var = <<"description">>, type = 'text-multi', values = [Desc], label = <<"Description">>},
    #xdata_field{var = <<"index">>, type = 'list-single', values = [Search], label = <<"Index">>, options = index_options()},
    #xdata_field{var = <<"membership">>, type = 'list-single', values = [Model], label = <<"Membership">>, options = membership_options()},
    #xdata_field{var = <<"contacts">>, type = 'jid-multi', values = [form_list(ContactList)], label = <<"Contacts">>},
    #xdata_field{var = <<"domains">>, type = 'jid-multi', values = [form_list(DomainList)], label = <<"Domains">>}
    ].

-spec decode(binary(),binary(),list()) -> list().
decode(LServer,Chat,FS) ->
  decoding(LServer,Chat,[],filter_fixed_fields(FS)).

decoding(LServer,Chat,Acc,[#xdata_field{var = Var, values = Values} | RestFS]) ->
  decoding(LServer,Chat,[get_and_validate(LServer,Chat,Var,Values)| Acc], RestFS);
decoding(_LServer,_Chat,Acc, []) ->
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

-spec get_and_validate(binary(),binary(),binary(),list()) -> binary().
get_and_validate(_LServer,_Chat,<<"description">>,Desc) ->
  {description,list_to_binary(Desc)};
get_and_validate(_LServer,_Chat,<<"name">>,Name) ->
  {name,list_to_binary(Name)};
get_and_validate(_LServer,_Chat,<<"index">>,Index) ->
  validate_index(list_to_binary(Index));
get_and_validate(_LServer,_Chat,<<"membership">>,Membership) ->
  validate_membership(list_to_binary(Membership));
get_and_validate(_LServer,_Chat,<<"contacts">>,Contacts) ->
  validate_contacts(Contacts);
get_and_validate(_LServer,_Chat,<<"domains">>,Domains) ->
  validate_domains(Domains);
get_and_validate(_LServer,_Chat,_Var,_Values) ->
  false.


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

sql_update_pinned(Server,Chat,Message) ->
  case ?SQL_UPSERT(Server, "groupchats",
    [ "message=%(Message)d",
      "!jid=%(Chat)s"]) of
    ok ->
      ok;
    _Err ->
      {error, db_failure}
  end.

sql_update_groupchat(Server, SJID, NewInfo) ->
  #{name := Name, description := Desc, membership := Membership,
    index := Index, contacts := Contacts,
    domains := Domains} = NewInfo,
  case ?SQL_UPSERT(Server, "groupchats",
    ["name=%(Name)s",
      "description=%(Desc)s",
      "model=%(Membership)s",
      "searchable=%(Index)s",
      "contacts=%(Contacts)s",
      "domains=%(Domains)s",
      "!jid=%(SJID)s"]) of
    ok ->
      ok;
    _Err ->
      {error, db_failure}
  end.

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

get_chat_active(_Server, Group) ->
  {LUser, LServer, _} = jid:tolower(jid:from_string(Group)),
  case ejabberd_sm:get_user_info(LUser, LServer, <<"Group">>) of
    offline -> false;
    Info ->
      proplists:get_value(gstatus, Info, false)
  end.

update_user_counter(Group) ->
  {_LUser, LServer, _} = jid:tolower(jid:from_string(Group)),
  Count = sql_get_user_count(LServer, Group),
  groups_sm:update_group_session_info(Group, #{user_count => Count}).

count_users(Server, Group) ->
  {LUser, LServer, _} = jid:tolower(jid:from_string(Group)),
  case ejabberd_sm:get_user_info(LUser, LServer, <<"Group">>) of
    offline -> <<"0">>;
    Info ->
      case proplists:get_value(user_count, Info, false) of
        false ->
          ?ERROR_MSG("User counter in memory is not available: ~p",
            [Group]),
          sql_get_user_count(Server, Group);
        V -> V
      end
  end.

sql_get_user_count(LServer,Chat) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(count(*))s from groupchat_users "
    " where chatgroup = %(Chat)s and subscription = 'both'")) of
    {selected,[{Num}]} -> Num;
    _ -> <<"0">>
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

get_name_desc(Server,Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(name)s,@(description)s,@(anonymous)s,@(searchable)s,@(model)s,@(parent_chat)s
    from groupchats where jid=%(Chat)s and %(Server)H")) of
    {selected,[]} ->
      {<<>>,<<>>,<<>>,<<>>,<<>>,undefined};
    {selected,[{Name,Desc,Privacy,Index,Membership,ParentChat}]} ->
      {Name,Desc,Privacy,Index,Membership,ParentChat};
    _ ->
      {<<>>,<<>>,<<>>,<<>>,<<>>,undefined}
  end.

check_user_rights_to_change_status(_Acc,User,Chat,Server) ->
  case mod_groups_restrictions:is_permitted(<<"change-group">>,User,Chat) of
    true ->
      {stop, {ok, status_form(Chat,Server,'text-single')}};
    _ ->
      {stop, {ok, status_form(Chat,Server,'fixed')}}
  end.

status_form(Chat,LServer,Type) ->
  Status = get_chat_active(LServer,Chat),
  make_form(LServer, Chat, Status, Type).

make_form(LServer, Chat, Status, Type) ->
  Fields = fill_fields(LServer, Chat, Status, Type),
  #xdata{type = form, title = <<"Group status change">>, instructions = [<<"Fill out this form to change the group status">>], fields = Fields}.

fill_fields(LServer, Chat, Status, Type) ->
  [
    #xdata_field{var = <<"FORM_TYPE">>, type = hidden, values = [?NS_GROUPCHAT_STATUS]},
    #xdata_field{type = 'fixed', var = <<"header1">>, values = [<<"Section 1 : Statuses">>]},
    #xdata_field{var = <<"status">>, desc = <<"Change status to change behaviour of group">>, type = Type, values = [Status], label = <<"Status">>, options = fill_status_options(LServer, Chat)},
    #xdata_field{type = 'fixed', var = <<"header2">>, values = [<<"Section 2 : Description of statuses">>]}
  ] ++ get_status_description(LServer,Chat).

get_status_description(LServer, Chat) ->
  Statuses = statuses_and_values(LServer, Chat),
  lists:map(fun(StatusAndValue) ->
    {Status, _HumanStatus, Value, Desc} = StatusAndValue,
    #xdata_field{
      var = Status,
      type = 'fixed',
      desc = Desc,
      values = [Value]} end, Statuses
  ).

fill_status_options(LServer, Chat) ->
  Statuses = statuses_and_values(LServer, Chat),
  lists:map(fun(StatusAndValue) ->
    {Status, HumanLabel, _Value, _Desc} = StatusAndValue,
    #xdata_option{
      label = HumanLabel,
      value = [Status]} end, Statuses
  ).

statuses_and_values(LServer, Chat) ->
  Predefined =
    [
      {<<"fiesta">>, <<"Fiesta">>,<<"chat">>, <<"Everything is allowed, no restrictions. Stickers, pictures, voice messages are allowed.">>},
      {<<"discussion">>, <<"Discussion">>,<<"active">>, <<"Regular chat. There is no limit on the number of messages. Limited voice messages">>},
      {<<"regulated">>, <<"Regulated">>,<<"away">>, <<"Regulated chat. Only text messages and images. Limit on the number of messages per minute.">>},
      {<<"limited">>, <<"Limited">>, <<"xa">>, <<"Limited discussion. Text messages only. Limit on the number of messages per minute.">>},
      {<<"restricted">>, <<"Restricted">>, <<"dnd">>, <<"Chat is allowed only for administrators">>},
      {<<"inactive">>, <<"Inactive">>, <<"inactive">>, <<"Chat is off">>}
    ],
  Result = ejabberd_hooks:run_fold(chat_status_description, LServer, Predefined, [Chat]),
  Result.


parse_status_query(FS, Lang) ->
  try	groups_status:decode(FS) of
    Form -> {ok, Form}
  catch _:{groups_status, Why} ->
    Txt = groups_status:format_error(Why),
    {error, xmpp:err_bad_request(Txt, Lang)}
  end.

%% Change status hook
check_user_rights_to_change_status(_Acc,User,Chat,_Server,_FS) ->
  case mod_groups_restrictions:is_permitted(<<"change-group">>,User,Chat) of
    true ->
      ok;
    _ ->
      {stop, {error, xmpp:err_not_allowed()}}
  end.

check_status(_Acc, _User,Chat,Server,FS) ->
  NewStatus = proplists:get_value(status,FS),
  case NewStatus of
    undefined ->
      {stop, {error, xmpp:err_bad_request(<<"Status undefined - please choose status from available values">>, <<"en">>)}};
    _ ->
      check_status_value(Server, Chat, NewStatus)
  end.

check_status_value(Server, Chat, Status) ->
  Statuses = statuses_and_values(Server,Chat),
  Search = lists:keyfind(Status,1,Statuses),
  case Search of
    {Status, _HumanStatus,_StatusValue,_Desc} ->
      update_status(Server, Chat, Status);
    _ ->
      {stop, {error, xmpp:err_bad_request(<<"Value ", Status/binary, " is not allowed by server policy. Please, choose status from available values">>, <<"en">>)}}
  end.

update_status(Server, Chat, Status) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchats set status = %(Status)s where jid=%(Chat)s and status != %(Status)s and %(Server)H")) of
    {updated,1} ->
      Form = make_form(Server, Chat, Status, 'text-single'),
      groups_sm:update_group_session_info(Chat, #{gstatus => Status}),
      {stop, {ok, Form, Status}};
    {updated,0} ->
      {stop, {error,xmpp:err_bad_request(<<"Value ", Status/binary, " is unchanged">>, <<"en">>)}};
    _ ->
      {stop, {error,xmpp:err_internal_server_error()}}
  end.

define_human_status(LServer, Chat, Status) ->
  Statuses = statuses_and_values(LServer, Chat),
  case lists:keyfind(Status,1,Statuses) of
    {Status, HumanStatus, _Show,_Desc} ->
      HumanStatus;
    _ ->
      Status
  end.

define_human_status_and_show(LServer, Chat, Status) ->
  Statuses = statuses_and_values(LServer, Chat),
  Length = string:length(Status),
  case lists:keyfind(Status,1,Statuses) of
    {Status, HumanStatus, Show,_Desc} ->
      {[#text{data = HumanStatus}], define_show(Show)};
    _ when Length > 0 ->
      {[#text{data = Status}], undefined};
    _ ->
      {[], undefined}
  end.

define_show(<<"dnd">>) ->
  'dnd';
define_show(<<"chat">>) ->
  'chat';
define_show(<<"xa">>) ->
  'xa';
define_show(<<"away">>) ->
  'away';
define_show(_Status) ->
  undefined.