%%%-------------------------------------------------------------------
%%% File    : mod_groups_inspector.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Old module - will be removed soon
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

-module(mod_groups_inspector).
-author('andrey.gagarin@redsolution.com').
-behavior(gen_mod).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).
-export([start/2, stop/1, depends/2, mod_options/1]).
-export([
  add_user/5,
  add_user/6,
  create_chat/12,
  invite_right/2,
  user_exist/2,
  send_invite/2,
  get_invited_users/2,
  get_invited_users/3,
  revoke/3,
  revoke/4,
  chat_information/9,
  block_parse_chat/3,
  unblock_parse_chat/3,
  update_chat/5,
  kick_user/3,
  update_chat_avatar_id/3,
  get_chat_avatar_id/1,
  get_collect_state/2,
  search/7,
  add_user_in_chat/2
]).

start(Host, _Opts) ->
  ejabberd_hooks:add(groupchat_invite_hook, Host, ?MODULE, invite_right, 15),
  ejabberd_hooks:add(groupchat_invite_hook, Host, ?MODULE, user_exist, 20),
  ejabberd_hooks:add(groupchat_invite_hook, Host, ?MODULE, add_user_in_chat, 22),
  ejabberd_hooks:add(groupchat_invite_hook, Host, ?MODULE, send_invite, 30).

stop(Host) ->
  ejabberd_hooks:delete(groupchat_invite_hook, Host, ?MODULE, invite_right, 15),
  ejabberd_hooks:delete(groupchat_invite_hook, Host, ?MODULE, user_exist, 20),
  ejabberd_hooks:delete(groupchat_invite_hook, Host, ?MODULE, add_user_in_chat, 22),
  ejabberd_hooks:delete(groupchat_invite_hook, Host, ?MODULE, send_invite, 30).

depends(_Host, _Opts) -> [].

mod_options(_Opts) -> [].

update_chat(Server,To,Chat,User,Xa) ->
  {selected,[{_Name,_Anonymous,_Search,_Model,_Desc,ChatMessage,_ContactList,_DomainList_,Status}]} =
    mod_groups_chats:get_information_of_chat(Chat,Server),
  case Status of
    <<"inactive">> ->
      {error, xmpp:err_not_allowed(<<"You need to active group">>,<<"en">>)};
    _ ->
      Pinned = case Xa#xabbergroupchat_update.pinned of
                 #xabbergroupchat_pinned_message{cdata = Cdata} ->
                   Cdata;
                 _ ->
                   undefined
               end,
      NewMessage = set_message(ChatMessage,Pinned),
      mod_groups_chats:update_pinned(Server,Chat,NewMessage),
      UpdatePresence = mod_groups_presence:form_presence(Chat),
      IsPinnedChanged = {pinned_changed, mod_groups_chats:is_value_changed(ChatMessage,NewMessage)},
      Properties = [IsPinnedChanged],
      ejabberd_hooks:run(groupchat_properties_changed,Server,[Server, Chat, User, Properties, Status]),
      AllUsers = mod_groups_users:user_list_to_send(Server,Chat),
      FromChat = jid:replace_resource(To,<<"Group">>),
      mod_groups_presence:send_presence(UpdatePresence,AllUsers,FromChat)
  end.

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

item_chat(ChatJidQ,NameQ,AnonymousQ,ModelQ,DescQ,ContactListQ,DomainListQ,Count) ->
  #xmlel{name = <<"item">>, children =
  [
    #xmlel{name = <<"jid">>, children = [{xmlcdata,ChatJidQ}]},
    #xmlel{name = <<"name">>, children = [{xmlcdata,NameQ}]},
    #xmlel{name = <<"anonymous">>, children = [{xmlcdata,AnonymousQ}]},
    #xmlel{name = <<"model">>, children = [{xmlcdata,ModelQ}]},
    #xmlel{name = <<"description">>, children = [{xmlcdata,DescQ}]},
    form_xmlel(ContactListQ,<<"contacts">>,<<"contact">>),
    form_xmlel(DomainListQ,<<"domains">>,<<"domain">>),
    #xmlel{name = <<"member-count">>, children = [{xmlcdata,Count}]}
  ]}.

%%%%
%%  End of search for group chats
%%%%

revoke(Server,User,Chat) ->
  remove_invite(Server,User,Chat).
revoke(Server, User, Chat, Admin) ->
  case mod_groups_restrictions:is_permitted(<<"change-group">>,Admin,Chat) of
    true ->
      remove_invite(Server,User,Chat);
    _ ->
      remove_invite(Server,User,Chat, Admin)
  end.


-spec get_invited_users(binary(),binary()) -> xabbergroupchat_invite_query().
get_invited_users(Server,Chat) ->
  List = sql_get_invited(Server,Chat),
  make_invite_query(List).

-spec get_invited_users(binary(),binary(),binary()) -> xabbergroupchat_invite_query().
get_invited_users(Server, Chat, User) ->
  List = sql_get_invited(Server, Chat, User),
  make_invite_query(List).

-spec make_invite_query(list()) -> xabbergroupchat_invite_query().
make_invite_query([]) ->
  #xabbergroupchat_invite_query{};
make_invite_query(List) ->
  UserList = lists:map(fun({User})->
    #xabbergroup_invite_user{jid = User}
                       end, List),
  #xabbergroupchat_invite_query{user = UserList}.

sql_get_invited(Server,Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_users
    where chatgroup = %(Chat)s
    and subscription = 'wait'")) of
    {selected,Users} ->
      Users;
    _->
      []
  end.

sql_get_invited(Server,Chat, User) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_users
    where chatgroup = %(Chat)s
    and subscription = 'wait' and invited_by = %(User)s")) of
    {selected,Users} ->
      Users;
    _->
      []
  end.

invite_right(_Acc, {Admin,Chat,_Server,
  #xabbergroupchat_invite{jid = _Jid, reason = _Reason, send = _Send}}) ->
  case mod_groups_restrictions:is_restricted(<<"send-invitations">>,Admin,Chat) of
    true ->
      {stop,forbidden};
    _ ->
      ok
  end.

user_exist(_Acc, {_Admin,Chat,Server,
  #xabbergroupchat_invite{invite_jid =  User, reason = _Reason, send = _Send}}) ->
  Status = mod_groups_users:check_user_if_exist(Server,User,Chat),
  case Status of
    <<"both">> ->
      {stop,exist};
    <<"wait">> ->
      {stop,exist};
    _ ->
      ok
  end.

add_user_in_chat(_Acc, {Admin,Chat,Server,
  #xabbergroupchat_invite{invite_jid =  User, reason = _Reason, send = _Send}}) ->
  Role = <<"member">>,
  Subscription = <<"wait">>,
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set subscription = %(Subscription)s, invited_by = %(Admin)s where chatgroup=%(Chat)s
              and username=%(User)s and subscription='none'")) of
    {updated,N} when N > 0 ->
      ok;
    _ ->
      add_user(Server,User,Role,Chat,Subscription, Admin)
  end.

send_invite(_Acc, {Admin,Chat,_Server,
  #xabbergroupchat_invite{invite_jid =  User, reason = Reason, send = Send}}) ->
  case Send of
    _ when Send == <<"1">> orelse Send == <<"true">> ->
      Message = message_invite(User,Chat,Admin,Reason),
      ejabberd_router:route(Message),
      {stop,ok};
    _ ->
      {stop,ok}
  end.


message_invite(User,Chat,Admin,Reason) ->
  U = #xabbergroup_invite_user{jid = Admin},
  ChatJID = jid:from_string(Chat),
  LServer = ChatJID#jid.lserver,
  {ok, Anonymous, _} = mod_groups_chats:get_type_and_parent(LServer,Chat),
  Text = <<"Add ",Chat/binary," to the contacts to join a group chat">>,
    #message{type = chat,to = jid:from_string(User), from = jid:from_string(Chat), id = randoms:get_string(),
      sub_els = [#xabbergroupchat_invite{user = U, reason = Reason, jid = ChatJID},
        #xabbergroupchat_x{sub_els = [#xabbergroupchat_privacy{cdata = Anonymous}]}],
      body = [#text{lang = <<>>,data = Text}], meta = #{}}.

create_chat(Creator,Host,Server,Name,Anon,LocalJid,Searchable,Description,
    ModelRare,ChatMessage,Contacts,Domains) ->
  LocalpartBad = set_value(create_jid(),LocalJid),
  Localpart = list_to_binary(string:to_lower(binary_to_list(LocalpartBad))),
  IsExist = mod_xabber_entity:is_exist_anywhere(Localpart, Server),
  if
    IsExist ->
      exist;
    true ->
      Anonymous = set_value(<<"public">>,Anon),
      Search = set_value(<<"local">>,Searchable),
      Desc = set_value(<<>>,Description),
      Model = set_value(<<"open">>,ModelRare),
      Message = set_value(<<"0">>,ChatMessage),
      ChatJid = jid:to_string(jid:make(Localpart,Server,<<>>)),
      ContactList = set_contacts(<<>>,Contacts),
      DomainList = set_domains(<<>>,Domains),
      CreatorJid = jid:to_string(jid:make(Creator,Host,<<>>)),
      mod_groups_chats:create_groupchat(Server,Localpart,CreatorJid,Name,ChatJid,
        Anonymous,Search,Model,Desc,Message,ContactList,DomainList,<<"0">>),
      add_user(Server,CreatorJid,<<"owner">>,ChatJid,<<"wait">>,<<>>),
      mod_admin_extra:set_nickname(Localpart,Host,Name),
      Expires = <<"0">>,
      IssuedBy = <<"server">>,
      Permissions = get_permissions(Server),
      lists:foreach(fun(N)->
        {Rule} = N,
        mod_groups_restrictions:insert_rule(Server,ChatJid,
          CreatorJid,Rule,Expires,IssuedBy)
                    end, Permissions),
      {ok,created(Name,ChatJid,Anonymous,Search,Model,Desc,Message,ContactList,DomainList)}
  end.

set_contacts(Default,Contacts) ->
  case Contacts of
    undefined ->
      Default;
    _ ->
      make_string(Contacts#xabbergroup_contacts.contact)
  end.

set_domains(Default,Domains) ->
  case Domains of
    undefined ->
      Default;
    _ ->
      make_string(Domains#xabbergroup_domains.domain)
  end.

make_string(List) ->
  list_to_binary(lists:map(fun(N)-> [N|[<<",">>]] end, List)).

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
      Value
  end.

%% internal functions
remove_invite(Server,User,Chat) ->
  R = ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_users where
         username=%(User)s and chatgroup=%(Chat)s and subscription='wait'")),
  remove_invite_result(R, User, Chat).
remove_invite(Server, User, Chat, InvitedBy) ->
  R = ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_users where
         username=%(User)s and chatgroup=%(Chat)s and subscription='wait' and invited_by=%(InvitedBy)s")),
  remove_invite_result(R, User, Chat).

remove_invite_result(Result, User, Chat) ->
  case Result of
    {updated,1} ->
      From = jid:from_string(Chat),
      Unsubscribe = mod_groups_presence:form_unsubscribe_presence(),
      Unavailable = mod_groups_presence:form_presence_unavailable(),
      mod_groups_presence:send_presence(Unsubscribe,[{User}],From),
      mod_groups_presence:send_presence(Unavailable,[{User}],From),
      ok;
    _ ->
      {error, not_found}
  end.

kick_user(Server,User,Chat) ->
  From = jid:from_string(Chat),
  FromChat = jid:replace_resource(From,<<"Group">>),
case ejabberd_sql:sql_query(
  Server,
  ?SQL("update groupchat_users set subscription = 'none',user_updated_at = (now() at time zone 'utc')  where
         username=%(User)s and chatgroup=%(Chat)s and subscription != 'none'")) of
  {updated,1} ->
    Txt = <<"You are blocked">>,
    UserJID = jid:from_string(User),
    UserCard = #xabbergroupchat_user_card{jid = UserJID},
    X = #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE,sub_els = [UserCard], type = <<"block">>},
    Msg = #message{type = chat, from = FromChat, to = UserJID, id = randoms:get_string(), body = [#text{lang = <<>>,data = Txt}], sub_els = [X], meta = #{}},
    Unsubscribe = mod_groups_presence:form_unsubscribe_presence(),
    Unavailable = mod_groups_presence:form_presence_unavailable(),
    ejabberd_router:route(Msg),
    mod_groups_present_mnesia:delete_all_user_sessions(User,Chat),
    mod_groups_presence:send_presence(Unsubscribe,[{User}],FromChat),
    mod_groups_presence:send_presence(Unavailable,[{User}],FromChat);
  _ ->
    nothing
end.

add_user(Server, Member, Role, Group, Subs) ->
  add_user(Server, Member, Role, Group, Subs,<<>>).

add_user(Server, Member, Role, Group, Subs, InvitedBy) ->
  case mod_groups_users:check_user_if_exist(Server, Member, Group) of
    not_exist  ->
      mod_groups_users:add_user(Server, Member, Role,
        Group, Subs,InvitedBy);
    _ ->
      ok
  end.


created(Name,ChatJid,Anonymous,Search,Model,Desc,Message,ContactList,DomainList) ->
  #xmlel{name = <<"query">>, attrs = [{<<"xmlns">>,?NS_GROUPCHAT_CREATE}],
  children = chat_information(Name,ChatJid,Anonymous,Search,Model,Desc,Message,ContactList,DomainList)
  }.


chat_information(Name,ChatJid,Anonymous,Search,Model,Desc,M,ContactList,DomainList) ->
  J = jid:from_string(ChatJid),
  Server = J#jid.lserver,
  Localpart = J#jid.luser,
  Members = mod_groups_chats:count_users(Server,ChatJid),
  ChatSessions = mod_groups_present_mnesia:select_sessions('_',ChatJid),
  AllUsersSession = [{X,Y}||{chat_session,_Id,_Z,X,Y} <- ChatSessions],
  UniqueOnline = lists:usort(AllUsersSession),
  Present = integer_to_binary(length(UniqueOnline)),
  Message = case M of
              null ->
                <<>>;
              0 ->
                <<>>;
              _ when is_integer(M), M > 0 ->
                integer_to_binary(M);
              _ when is_binary(M) ->
                M
            end,
  [
    #xmlel{name = <<"jid">>, children = [{xmlcdata,ChatJid}]},
    #xmlel{name = <<"localpart">>, children = [{xmlcdata,Localpart}]},
    #xmlel{name = <<"name">>, children = [{xmlcdata,Name}]},
    #xmlel{name = <<"privacy">>, children = [{xmlcdata,Anonymous}]},
    #xmlel{name = <<"index">>, children = [{xmlcdata,Search}]},
    #xmlel{name = <<"membership">>, children = [{xmlcdata,Model}]},
    #xmlel{name = <<"description">>, children = [{xmlcdata,Desc}]},
    #xmlel{name = <<"pinned-message">>, children = [{xmlcdata,Message}]},
    form_xmlel(ContactList,<<"contacts">>,<<"contact">>),
    form_xmlel(DomainList,<<"domains">>,<<"domain">>),
    #xmlel{name = <<"members">>, children = [{xmlcdata,Members}]},
    #xmlel{name = <<"present">>, children = [{xmlcdata,Present}]}
  ].

form_xmlel(Elements,Name,NameEl) ->
  case Elements of
    <<>> ->
      #xmlel{name = Name};
    _ ->
      Splited = binary:split(Elements,<<",">>,[global]),
      Empty = [X||X <- Splited, X == <<>>],
      NotEmpty = Splited -- Empty,
      Children = lists:map(fun(N)-> #xmlel{name = NameEl, children = [{xmlcdata,N}]} end, NotEmpty),
      #xmlel{name = Name, children = Children}
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

block_parse_chat(Server,User,Chat) ->
  case ?SQL_UPSERT(Server, "groupchat_users",
    [
      "parse_avatar='no'",
      "!chatgroup=%(Chat)s",
      "!username=%(User)s"
    ]) of
    ok ->
      ok;
    _Err ->
      {error, db_failure}
  end.

unblock_parse_chat(Server,User,Chat) ->
  case ?SQL_UPSERT(Server, "groupchat_users",
    [
      "parse_avatar='yes'",
      "!chatgroup=%(Chat)s",
      "!username=%(User)s"
    ]) of
    ok ->
      ok;
    _Err ->
      {error, db_failure}
  end.

create_jid() -> 
  list_to_binary(
  [randoms:get_alphanum_string(2),randoms:get_string(),randoms:get_alphanum_string(3)]).

update_chat_avatar_id(Server,Chat,Hash) ->
  case ?SQL_UPSERT(Server, "groupchats",
    [
      "avatar_id=%(Hash)s",
      "!jid=%(Chat)s"
    ]) of
    ok ->
      ok;
    _Err ->
      {error, db_failure}
  end.

get_chat_avatar_id(Chat) ->
  Jid = jid:from_string(Chat),
  Server = Jid#jid.lserver,
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(avatar_id)s from groupchats where jid=%(Chat)s")) of
    {selected,[]} ->
      <<>>;
    {selected,[{}]} ->
      <<>>;
    {selected,[{Hash}]} ->
      Hash;
    _ ->
      <<>>
  end.

get_collect_state(Chat,User) ->
  Jid = jid:from_string(Chat),
  Server = Jid#jid.lserver,
  {selected,[State]} = ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(parse_avatar)s,@(p2p_state)s from groupchat_users where chatgroup=%(Chat)s and username=%(User)s")),
  State.
