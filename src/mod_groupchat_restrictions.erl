%%%-------------------------------------------------------------------
%%% File    : mod_groupchat_restrictions.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Manage restrictions and permissions in group chats
%%% Created : 02 Jul 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_groupchat_restrictions).
-author('andrey.gagarin@redsolution.com').
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).
%% API

-export([
  get_rules/4,
  get_user_rules/3,
  show_policy/2,
  insert_rule/6,
  upsert_rule/6,
  is_permitted/3,
  is_restricted/3,
  show_permissions/2,
  is_owner/3,
  validate_users/4,
  delete_rule/4,
  translated/1,
  get_all_restrictions/1,
  get_all_rights/1,
  set_rule/6,
  get_rights/3,
  get_owners/2]).

is_restricted(Action,User,Chat)->
  ChatJid = jid:from_string(Chat),
  case get_rules(ChatJid#jid.lserver,User,Chat,Action) of
    {selected,Restrictions} when length(Restrictions) > 0 ->
      true;
    _ ->
      false
  end.

is_permitted(Action,User,Chat)->
  ChatJid = jid:from_string(Chat),
  check_if_permitted(ChatJid#jid.lserver,User,Chat,Action).

% Uncomment it to block ability create new owners
%set_rule(_Server,<<"owner">>,_Expires,_User,_Chat,_Admin) ->
set_rule(_Server,_Rule,_Expires,Admin,_Chat,Admin) ->
  not_ok;
set_rule(Server,Rule,Expires,User,Chat,Admin) ->
  case is_permitted(<<"set-restrictions">>,Admin,Chat) of
    true ->
      case validate_users(Server,Chat,Admin,User) of
        ok ->
          mod_groupchat_users:update_user_status(Server,User,Chat),
          upsert_rule(Server,Chat,User,Rule,Expires,Admin),
          ok;
        _ ->
          not_ok
      end;
    false ->
      not_ok;
    _ ->
      not_ok
  end.

validate_users(Server,Chat,User1,User2) ->
  {selected,Permissions} = users_permissions(Server,Chat,User1,User2),
  User1Permissions = [X || {User,X} <- Permissions, User == User1],
  User2Permissions = [X || {User,X} <- Permissions, User == User2],
  User1Identity = indetify_user(User1Permissions),
  User2Identity = indetify_user(User2Permissions),
  case {User1Identity,User2Identity} of
    {owner,member} -> ok;
    {admin,member} -> ok;
    {owner,admin} -> ok;
    _ -> not_ok
  end.

indetify_user(UserPermissions) ->
  IsOwner = lists:member(<<"owner">>,UserPermissions),
  Restrict = lists:member(<<"set-restrictions">>,UserPermissions),
  Block = lists:member(<<"set-restrictions">>,UserPermissions),
  Admin = lists:member(<<"change-group">>,UserPermissions),
  Badge = lists:member(<<"change-users">>,UserPermissions),
  Nick = lists:member(<<"change-users">>,UserPermissions),
  Delete = lists:member(<<"delete-messages">>,UserPermissions),
  case length(UserPermissions) of
    0 ->
      member;
    _ when IsOwner == true ->
      owner;
    _ when Restrict == true orelse Block == true orelse Admin == true orelse Badge == true orelse
      Nick == true orelse Delete == true ->
      admin;
    _ ->
      member
  end.

%% SQL Functions
users_permissions(Server,Chat,User1,User2) ->
  TS = now_to_timestamp(now()),
  ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s,@(right_name)s from groupchat_policy where username=%(User1)s
    or username=%(User2)s and chatgroup=%(Chat)s and (valid_until = 0 or valid_until > %(TS)d) order by username")).

is_owner(Server,Chat,Username) ->
  TS = now_to_timestamp(now()),
 case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_policy where right_name='owner'
    and username=%(Username)s and chatgroup=%(Chat)s and (valid_until = 0 or valid_until > %(TS)d)")) of
   {selected,[]} ->
     no;
   _ ->
     yes
 end.

get_owners(LServer, Chat) ->
  TS = now_to_timestamp(now()),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(username)s,@(id)s from groupchat_users where username in
     (select username from groupchat_policy where
      chatgroup=%(Chat)s and right_name = 'owner' and (valid_until = 0 or valid_until > %(TS)d))
     and chatgroup = %(Chat)s and subscription = 'both'") ) of
    {selected, List} -> List;
    _ ->
      []
  end.

get_rules(Server,User,Chat,Action) ->
  TS = now_to_timestamp(now()),
  ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(valid_until)s from groupchat_policy where chatgroup=%(Chat)s and username=%(User)s
    and right_name=%(Action)s and (valid_until = 0 or valid_until > %(TS)d)")).

check_if_permitted(Server,User,Chat,Action) ->
  TS = now_to_timestamp(now()),
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(right_name)s from groupchat_policy where chatgroup=%(Chat)s and username=%(User)s
    and (valid_until = 0 or valid_until > %(TS)d)")) of
    {selected, RightsRaw} when length(RightsRaw) > 0 ->
      Rights = lists:map(fun(R) -> {R0} = R, R0 end, RightsRaw),
      check_permission_level(Action, Rights);
    _ ->
      false
  end.

check_permission_level(Right, Rights) ->
  RightsAndLevels = rights_and_levels(),
  RequiredLevel = proplists:get_value(Right, RightsAndLevels),
  PermissionLevel = get_permission_level(Rights),
  case RequiredLevel of
    _ when is_integer(RequiredLevel) andalso
      is_integer(PermissionLevel) andalso PermissionLevel >= RequiredLevel ->
      true;
    _ ->
      false
  end.

get_permission_level(Rights) ->
  RightsAndLevels = rights_and_levels(),
  RightsLevels = lists:map(
    fun(Right) ->
      proplists:get_value(Right, RightsAndLevels, 0) end, Rights
  ),
  Level = hd(lists:reverse(lists:sort(RightsLevels))),
  Level.

rights_and_levels() ->
  [
    {<<"owner">>,6},
    {<<"change-group">>,5},
    {<<"set-permissions">>,4},
    {<<"set-restrictions">>,3},
    {<<"change-users">>,2},
    {<<"delete-messages">>,1}
  ].

get_rights(Server,User,Chat) ->
  TS = now_to_timestamp(now()),
  ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(right_name)s from groupchat_policy where chatgroup=%(Chat)s and username=%(User)s
    and (valid_until = 0 or valid_until > %(TS)d)")).

get_user_rules(Server,User,Chat) ->
  ejabberd_sql:sql_query(
    Server,
    [
      <<"select groupchat_users.username,groupchat_users.badge,groupchat_users.id,
  groupchat_users.chatgroup,groupchat_policy.right_name, groupchat_rights.description,
  groupchat_rights.type, groupchat_users.subscription,
  groupchat_users_vcard.givenfamily,groupchat_users_vcard.fn,
  groupchat_users_vcard.nickname,groupchat_users.nickname,
  groupchat_policy.valid_until,
  COALESCE(to_char(groupchat_policy.issued_at, 'YYYY-MM-DD HH24:MI:SS')),
  groupchat_policy.issued_by,groupchat_users_vcard.image,groupchat_users.avatar_id,
  COALESCE(to_char(groupchat_users.last_seen, 'YYYY-MM-DD HH24:MI:SS'))
  from ((((groupchat_users LEFT JOIN  groupchat_policy on
  groupchat_policy.username = groupchat_users.username and
  groupchat_policy.chatgroup = groupchat_users.chatgroup)
  LEFT JOIN groupchat_rights on
  groupchat_rights.name = groupchat_policy.right_name and
  (groupchat_policy.valid_until = 0 or groupchat_policy.valid_until > %(TS)d))
  LEFT JOIN groupchat_users_vcard ON groupchat_users_vcard.jid = groupchat_users.username)
  LEFT JOIN groupchat_users_info ON groupchat_users_info.username = groupchat_users.username and
   groupchat_users_info.chatgroup = groupchat_users.chatgroup)
  where groupchat_users.subscription = 'both' and groupchat_users.chatgroup = ">>,
      <<"'">>,Chat,<<"' and groupchat_users.username =">>,
      <<"'">>, User, <<"'">>,
      <<"ORDER BY groupchat_users.username
      ">>
    ])
.

show_permissions(Server,Chat) ->
  ejabberd_sql:sql_query(
    Server,
    [<<"select groupchat_rights.name,
    groupchat_rights.description,
    groupchat_rights.type,
    groupchat_default_restrictions.action_time
    from groupchat_rights
    LEFT JOIN groupchat_default_restrictions on
    groupchat_default_restrictions.right_name = groupchat_rights.name
    and groupchat_default_restrictions.chatgroup = '">>,
     Chat
    ,<<"' and groupchat_default_restrictions.action_time != '0 years' and groupchat_default_restrictions.action_time != 'now'
     order by groupchat_rights.name = 'owner' asc, groupchat_rights.name desc">>]
  ).
   % ?SQL("select @(name)s,@(type)s from groupchat_rights order by name = 'owner' asc, name desc")).

show_policy(Server,Chat) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s,@(right_name)s,@(type)s from groupchat_policy where chatgroup=%(Chat)s")).

upsert_rule(Server,Chat,Username,Rule,Expires,_IssuedBy) when Expires == <<"">> ->
  delete_rule(Server,Chat,Username,Rule);
upsert_rule(Server,Chat,Username,Rule,Expires,IssuedBy) ->
  case ?SQL_UPSERT(Server, "groupchat_policy",
    ["!username=%(Username)s",
      "!chatgroup=%(Chat)s",
      "right_name=%(Rule)s",
      "valid_until=%(Expires)d",
      "issued_by=%(IssuedBy)s",
      "issued_at = CURRENT_TIMESTAMP"
      ]) of
    ok ->
      ok;
    Err ->
      ?ERROR_MSG("Error to save rule ~p",[Err]),
      {error, db_failure}
  end.

insert_rule(Server,Chat,Username,Rule,Expires,IssuedBy) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL_INSERT(
      "groupchat_policy",
      ["username=%(Username)s",
        "chatgroup=%(Chat)s",
        "right_name=%(Rule)s",
        "valid_until=%(Expires)d",
        "issued_by=%(IssuedBy)s",
        "issued_at=now()"
      ])).


delete_rule(Server,Chat,User,Rule) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_policy where
         username=%(User)s and chatgroup=%(Chat)s and right_name=%(Rule)s")).

translated(Lang) ->
  % Restrictions
  RT = translate:translate(Lang,<<"Read messages">>),
  WT = translate:translate(Lang,<<"Send messages">>),
  SIT = translate:translate(Lang,<<"Send images">>),
  SAT = translate:translate(Lang,<<"Send audio">>),
  SIN = translate:translate(Lang,<<"Send invitations">>),
  % Permissions
  OT = translate:translate(Lang,<<"Owner">>),
  AT = translate:translate(Lang,<<"Administrator">>),
  CRT = translate:translate(Lang,<<"Restrict participants">>),
  BPT = translate:translate(Lang,<<"Block participants">>),
  CBT = translate:translate(Lang,<<"Change badges">>),
  CNT = translate:translate(Lang,<<"Change nicknames">>),
  DMT = translate:translate(Lang,<<"Delete messages">>),
  [WT,RT,OT,AT,CRT,SIT,SAT,SIN,BPT,CBT,CNT,DMT].

get_all_rights(LServer) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(name)s,@(type)s,@(description)s from groupchat_rights")) of
    {selected,[]} ->
      [];
    {selected, Query} ->
      Query;
    _ ->
      []
  end.

get_all_restrictions(LServer) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(name)s,@(type)s,@(description)s from groupchat_rights where type='restriction'")) of
    {selected,[]} ->
      [];
    {selected, Query} ->
      Query;
    _ ->
      []
  end.

now_to_timestamp({MSec, Sec, _USec}) ->
  (MSec * 1000000 + Sec).