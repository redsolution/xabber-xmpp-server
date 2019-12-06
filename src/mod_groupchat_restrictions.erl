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
  change_permission/5,
  user_from_chat_with_rights/2,
  delete_rule/4,
  change_restriction/5,
  translated/1,
  get_all_restrictions/1,
  get_all_rights/1,
  set_rule/6
]).

change_permission(_Server,[],_User,_Chat,_Admin) ->
  ok;
change_permission(Server,Rules,User,Chat,Admin) ->
  [R|Rest] = Rules,
  Rule = R#xabbergroupchat_permission.name,
  Expires = set_time(R#xabbergroupchat_permission.expires),
  set_rule(Server,Rule,Expires,User,Chat,Admin),
  change_permission(Server,Rest,User,Chat,Admin).

change_restriction(_Server,[],_User,_Chat,_Admin) ->
  ok;
change_restriction(Server,Rules,User,Chat,Admin) ->
  [R|Rest] = Rules,
  Rule = R#xabbergroupchat_restriction.name,
  Expires = set_time(R#xabbergroupchat_restriction.expires),
  set_rule(Server,Rule,Expires,User,Chat,Admin),
  change_restriction(Server,Rest,User,Chat,Admin).


is_restricted(Action,User,Chat)->
  ChatJid = jid:from_string(Chat),
  case get_rules(ChatJid#jid.lserver,User,Chat,Action) of
    {selected,[]} ->
      no;
    {selected,_Restrictions}->
      yes
  end.

is_permitted(Action,User,Chat)->
  ChatJid = jid:from_string(Chat),
  case check_if_permitted(ChatJid#jid.lserver,User,Chat,Action) of
    {selected,[]} ->
      no;
    {selected,_Permissions}->
      yes
  end.

%% Internal functions
set_time(<<"never">>) ->
  <<"1000 years">>;
set_time(<<"now">>) ->
  <<"0 years">>;
set_time(Time) ->
  Time.

% Uncomment it to block ability create new owners
%set_rule(_Server,<<"owner">>,_Expires,_User,_Chat,_Admin) ->
set_rule(_Server,_Rule,_Expires,Admin,_Chat,Admin) ->
  not_ok;
set_rule(Server,Rule,Expires,User,Chat,Admin) ->
  case is_permitted(<<"restrict-participants">>,Admin,Chat) of
    yes ->
      case validate_users(Server,Chat,Admin,User) of
        ok ->
          mod_groupchat_users:update_user_status(Server,User,Chat),
          upsert_rule(Server,Chat,User,Rule,Expires,Admin),
          ok;
        _ ->
          not_ok
      end;
    no ->
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
  Restrict = lists:member(<<"restrict-participants">>,UserPermissions),
  Block = lists:member(<<"block-participants">>,UserPermissions),
  Admin = lists:member(<<"administrator">>,UserPermissions),
  Badge = lists:member(<<"change-badges">>,UserPermissions),
  Nick = lists:member(<<"change-nicknames">>,UserPermissions),
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
  ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s,@(right_name)s from groupchat_policy where username=%(User1)s
    or username=%(User2)s and chatgroup=%(Chat)s and valid_until > CURRENT_TIMESTAMP order by username")).

is_owner(Server,Chat,Username) ->
 case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_policy where right_name='owner'
    and username=%(Username)s and chatgroup=%(Chat)s and valid_until > CURRENT_TIMESTAMP")) of
   {selected,[]} ->
     no;
   _ ->
     yes
 end.

get_rules(Server,User,Chat,Action) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(valid_from)s,@(valid_until)s from groupchat_policy where chatgroup=%(Chat)s and username=%(User)s
    and right_name=%(Action)s and valid_until > CURRENT_TIMESTAMP and valid_from < CURRENT_TIMESTAMP")).

check_if_permitted(Server,User,Chat,Action) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(valid_from)s,@(valid_until)s from groupchat_policy where chatgroup=%(Chat)s and username=%(User)s
    and ( right_name=%(Action)s OR right_name='owner' ) and valid_until > CURRENT_TIMESTAMP and valid_from < CURRENT_TIMESTAMP")).

get_user_rules(Server,User,Chat) ->
  ejabberd_sql:sql_query(
    Server,
    [
      <<"select groupchat_users.username,groupchat_users.badge,groupchat_users.id,
  groupchat_users.chatgroup,groupchat_policy.right_name, groupchat_rights.description,
  groupchat_rights.type, groupchat_users.subscription,
  groupchat_users_vcard.givenfamily,groupchat_users_vcard.fn,
  groupchat_users_vcard.nickname,groupchat_users.nickname,
  COALESCE(to_char(groupchat_policy.valid_until, 'YYYY-MM-DD HH24:MI:SS')),
  COALESCE(to_char(groupchat_policy.issued_at, 'YYYY-MM-DD HH24:MI:SS')),
  groupchat_policy.issued_by,groupchat_users_vcard.image,groupchat_users.avatar_id,
  COALESCE(to_char(groupchat_users.last_seen, 'YYYY-MM-DD HH24:MI:SS'))
  from ((((groupchat_users LEFT JOIN  groupchat_policy on
  groupchat_policy.username = groupchat_users.username and
  groupchat_policy.chatgroup = groupchat_users.chatgroup)
  LEFT JOIN groupchat_rights on
  groupchat_rights.name = groupchat_policy.right_name and groupchat_policy.valid_until > CURRENT_TIMESTAMP)
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

upsert_rule(Server,Chat,Username,Rule,Expires,IssuedBy) ->
  ejabberd_sql:sql_query(
    Server,
    [<<"INSERT INTO groupchat_policy (username,right_name,valid_from,valid_until,issued_by,issued_at,chatgroup) values(">>
      ,<<"'">>,Username,<<"','">>,Rule,<<"',CURRENT_TIMESTAMP, (CURRENT_TIMESTAMP + INTERVAL ">>,
      <<"'">>, Expires,<<"'">>, <<"),">>
      ,<<"'">>,IssuedBy,<<"'">>,
      <<",CURRENT_TIMESTAMP,">>,<<"'">>, Chat,<<"'">>, <<") ON CONFLICT (username,chatgroup,right_name) DO UPDATE set
      valid_from = CURRENT_TIMESTAMP, valid_until = (CURRENT_TIMESTAMP + INTERVAL" >>, <<"'">>,
      Expires, <<"'">>, <<"), issued_by = ">>, <<"'">>, IssuedBy, <<"'">>, <<", issued_at = CURRENT_TIMESTAMP">>
    ]).

insert_rule(Server,Chat,Username,Rule,Expires,IssuedBy) ->
  ejabberd_sql:sql_query(
    Server,
    [<<"INSERT INTO groupchat_policy (username,right_name,valid_from,valid_until,issued_by,issued_at,chatgroup) values(">>
    ,<<"'">>,Username,<<"','">>,Rule,<<"',CURRENT_TIMESTAMP, (CURRENT_TIMESTAMP + INTERVAL ">>,
      <<"'">>, Expires,<<"'">>, <<"),">>
      ,<<"'">>,IssuedBy,<<"'">>,
      <<",CURRENT_TIMESTAMP,">>,<<"'">>, Chat,<<"'">>, <<")">>
    ]).
user_from_chat_with_rights(Chat,Server) ->
  ejabberd_sql:sql_query(
    Server,
    [
      <<"select groupchat_users.username,groupchat_users.badge,groupchat_users.id,
  groupchat_users.chatgroup,groupchat_policy.right_name,groupchat_rights.description,
  groupchat_rights.type, groupchat_users.subscription,
  groupchat_users_vcard.givenfamily,groupchat_users_vcard.fn,
  groupchat_users_vcard.nickname,groupchat_users.nickname,
  COALESCE(to_char(groupchat_policy.valid_until, 'YYYY-MM-DD HH24:MI:SS')),
  COALESCE(to_char(groupchat_policy.issued_at, 'YYYY-MM-DD HH24:MI:SS')),
  groupchat_policy.issued_by,groupchat_users_vcard.image,groupchat_users.avatar_id,
  COALESCE(to_char(groupchat_users.last_seen, 'YYYY-MM-DD HH24:MI:SS'))
  from ((((groupchat_users LEFT JOIN  groupchat_policy on
  groupchat_policy.username = groupchat_users.username and
  groupchat_policy.chatgroup = groupchat_users.chatgroup)
  LEFT JOIN groupchat_rights on
  groupchat_rights.name = groupchat_policy.right_name and groupchat_policy.valid_until > CURRENT_TIMESTAMP)
  LEFT JOIN groupchat_users_vcard ON groupchat_users_vcard.jid = groupchat_users.username)
  LEFT JOIN groupchat_users_info ON groupchat_users_info.username = groupchat_users.username and
   groupchat_users_info.chatgroup = groupchat_users.chatgroup)
  where groupchat_users.subscription = 'both' and groupchat_users.chatgroup = ">>,
       <<"'">>,Chat,<<"'">>,
       <<"ORDER BY groupchat_users.username DESC
      ">>
    ])
.


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