%%%-------------------------------------------------------------------
%%% File    : mod_groupchat_users.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Manage users in groupchats
%%% Created : 17 Oct 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_groupchat_users).
-author('andrey.gagarin@redsolution.com').
-behavior(gen_mod).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).

%% API
-export([start/2, stop/1, depends/2, mod_options/1]).
-export([
  check_user_if_exist/3,
  get_user_from_chat/3,
  get_users_from_chat/5,
%%  get_users_list_with_version/1,
  form_user_card/2,
  form_user_updated/2,
  user_list_to_send/2,
  form_kicked/2,
  is_lonely_owner/2,
  delete_user/2,
  get_updated_users_rights/3,
  get_updated_user_rights/4,
%%  update_user/2,
%%  validate_data/2,
%%  validate_rights/2,
  convert_from_unix_time_to_datetime/1,
  convert_from_datetime_to_unix_time/1,
  get_users_from_chat/1,
  current_chat_version/2,
  subscribe_user/2,
  get_user_by_id/3, get_user_info_for_peer_to_peer/3, add_user_to_peer_to_peer_chat/10,
  update_user_status/3, user_no_read/2, get_users_page/3, get_nick_in_chat/3, get_user_by_id_and_allow_to_invite/3,
  pre_approval/2, get_vcard/2,check_user/3,choose_name/1, add_user_vcard/2, add_wait_for_vcard/2, change_peer_to_peer_invitation_state/4
]).

-export([is_exist/2,is_owner/2]).

%% Change user settings hook export
-export([check_if_exist/6, get_user_rights/6, validate_request/6, change_user_rights/6, user_rights/3, check_if_request_user_exist/6, user_rights_and_time/3]).

% request_own_rights hook export
-export([check_if_user_exist/5, send_user_rights/5]).

% Change user nick and badge
-export([validate_data/8, validate_rights/8, update_user/8]).

% Delete chat
-export([check_if_user_owner/4, unsubscribe_all_participants/4]).

start(Host, _Opts) ->
  ejabberd_hooks:add(delete_groupchat, Host, ?MODULE, check_if_user_owner, 10),
  ejabberd_hooks:add(delete_groupchat, Host, ?MODULE, unsubscribe_all_participants, 20),
  ejabberd_hooks:add(request_own_rights, Host, ?MODULE, check_if_user_exist, 10),
  ejabberd_hooks:add(request_own_rights, Host, ?MODULE, send_user_rights, 20),
  ejabberd_hooks:add(request_change_user_settings, Host, ?MODULE, check_if_exist, 10),
  ejabberd_hooks:add(request_change_user_settings, Host, ?MODULE, check_if_request_user_exist, 15),
  ejabberd_hooks:add(request_change_user_settings, Host, ?MODULE, get_user_rights, 20),
  ejabberd_hooks:add(change_user_settings, Host, ?MODULE, check_if_exist, 10),
  ejabberd_hooks:add(change_user_settings, Host, ?MODULE, check_if_request_user_exist, 15),
  ejabberd_hooks:add(change_user_settings, Host, ?MODULE, validate_request, 20),
  ejabberd_hooks:add(change_user_settings, Host, ?MODULE, change_user_rights, 30),
  ejabberd_hooks:add(groupchat_presence_hook, Host, ?MODULE, subscribe_user, 60),
  ejabberd_hooks:add(groupchat_update_user_hook, Host, ?MODULE, validate_data, 10),
  ejabberd_hooks:add(groupchat_update_user_hook, Host, ?MODULE, validate_rights, 15),
  ejabberd_hooks:add(groupchat_update_user_hook, Host, ?MODULE, update_user, 20),
  ejabberd_hooks:add(groupchat_presence_subscribed_hook, Host, ?MODULE, get_vcard, 25),
  ejabberd_hooks:add(groupchat_presence_subscribed_hook, Host, ?MODULE, pre_approval, 30),
  ejabberd_hooks:add(groupchat_presence_subscribed_hook, Host, ?MODULE, is_owner, 35),
  ejabberd_hooks:add(groupchat_presence_unsubscribed_hook, Host, ?MODULE, is_lonely_owner, 15),
  ejabberd_hooks:add(groupchat_invite_hook, Host, ?MODULE, add_user_vcard, 25),
  ejabberd_hooks:add(groupchat_presence_unsubscribed_hook, Host, ?MODULE, delete_user, 20).

stop(Host) ->
  ejabberd_hooks:delete(delete_groupchat, Host, ?MODULE, check_if_user_owner, 10),
  ejabberd_hooks:delete(delete_groupchat, Host, ?MODULE, unsubscribe_all_participants, 20),
  ejabberd_hooks:delete(request_own_rights, Host, ?MODULE, check_if_user_exist, 10),
  ejabberd_hooks:delete(request_own_rights, Host, ?MODULE, send_user_rights, 20),
  ejabberd_hooks:delete(change_user_settings, Host, ?MODULE, check_if_exist, 10),
  ejabberd_hooks:delete(change_user_settings, Host, ?MODULE, check_if_request_user_exist, 15),
  ejabberd_hooks:delete(change_user_settings, Host, ?MODULE, validate_request, 20),
  ejabberd_hooks:delete(change_user_settings, Host, ?MODULE, change_user_rights, 30),
  ejabberd_hooks:delete(request_change_user_settings, Host, ?MODULE, check_if_exist, 10),
  ejabberd_hooks:delete(request_change_user_settings, Host, ?MODULE, check_if_request_user_exist, 15),
  ejabberd_hooks:delete(request_change_user_settings, Host, ?MODULE, get_user_rights, 20),
  ejabberd_hooks:delete(groupchat_update_user_hook, Host, ?MODULE, validate_data, 10),
  ejabberd_hooks:delete(groupchat_update_user_hook, Host, ?MODULE, validate_rights, 15),
  ejabberd_hooks:delete(groupchat_update_user_hook, Host, ?MODULE, update_user, 20),
  ejabberd_hooks:delete(groupchat_presence_subscribed_hook, Host, ?MODULE, get_vcard, 25),
  ejabberd_hooks:delete(groupchat_presence_subscribed_hook, Host, ?MODULE, pre_approval, 30),
  ejabberd_hooks:delete(groupchat_presence_subscribed_hook, Host, ?MODULE, is_owner, 35),
  ejabberd_hooks:delete(groupchat_invite_hook, Host, ?MODULE, add_user_vcard, 25),
  ejabberd_hooks:delete(groupchat_presence_unsubscribed_hook, Host, ?MODULE, is_lonely_owner, 15),
  ejabberd_hooks:delete(groupchat_presence_unsubscribed_hook, Host, ?MODULE, delete_user, 20),
  ejabberd_hooks:delete(groupchat_presence_hook, Host, ?MODULE, subscribe_user, 60).

depends(_Host, _Opts) ->  [].

mod_options(_Opts) -> [].

% delete groupchat hook
check_if_user_owner(_Acc, LServer, User, Chat) ->
  case mod_groupchat_restrictions:is_owner(LServer,Chat,User) of
    yes ->
      ok;
    _ ->
      {stop,{error, xmpp:err_not_allowed()}}
  end.

unsubscribe_all_participants(_Acc, LServer, _User, Chat) ->
  Users = get_all_user(LServer,Chat),
  From = jid:from_string(Chat),
  lists:foreach(fun(U) ->
    {Participant} = U,
    To = jid:from_string(Participant),
    ejabberd_router:route(#presence{type = unsubscribe, id = randoms:get_string(), from = From, to = To}),
    ejabberd_router:route(#presence{type = unsubscribed, id = randoms:get_string(), from = From, to = To})
                end,
    Users
  ).

% request_own_rights hook
check_if_user_exist(Acc, LServer, User, Chat,_Lang) ->
  case check_user_if_exist(LServer,User,Chat) of
    not_exist ->
      ?INFO_MSG("Request own rights user ~p chat ~p NOT EXIST",[User,Chat]),
      {stop,{error, xmpp:err_item_not_found()}};
    _ ->
      Acc
  end.

send_user_rights(_Acc, LServer, User, Chat, Lang) ->
  RightsAndTime = user_rights_and_time(LServer,Chat,User),
  ?INFO_MSG("Request own rights user ~p chat ~p",[User,Chat]),
  Fields = [
    #xdata_field{var = <<"FORM_TYPE">>, type = hidden, values = [?NS_GROUPCHAT_RIGHTS]},
    #xdata_field{var = <<"user-id">>, type = hidden, values = [<<"">>]}| make_fields_owner_no_options(LServer,RightsAndTime,Lang,'fixed')
  ],
  {stop,{ok,#xabbergroupchat{
    xmlns = ?NS_GROUPCHAT_RIGHTS,
    sub_els = [
      #xdata{type = form,
        title = <<"Groupchat user's rights">>,
        instructions = [],
        fields = Fields}
    ]}}}.

check_if_exist(Acc, LServer, User, Chat, _ID, _Lang) ->
  case check_user_if_exist(LServer,User,Chat) of
    not_exist ->
      {stop,not_ok};
    _ ->
      Acc
  end.

check_if_request_user_exist(Acc, LServer, _User, Chat, ID, _Lang) ->
  case check_user_if_exist_by_id(LServer,ID,Chat) of
    not_exist ->
      {stop,not_exist};
    _ ->
      Acc
  end.

get_user_rights(_Acc, LServer, User, Chat, ID, Lang) ->
  RequestUser = get_user_by_id(LServer,Chat,ID),
  case mod_groupchat_restrictions:validate_users(LServer,Chat,User,RequestUser) of
    ok ->
      {stop,{ok,create_right_form(LServer,User,Chat,RequestUser,ID, Lang)}};
    _ ->
      {stop,{ok,create_empty_form(ID)}}
  end.

validate_request(Acc, LServer, _User, Chat, ID, _Lang) ->
  RequestUser = get_user_by_id(LServer,Chat,ID),
  case decode(LServer,Acc) of
    {ok,FS} ->
      CurrentValues = current_values(LServer,RequestUser,Chat),
      FS1 = FS -- CurrentValues,
      validate(FS1);
    _ ->
      {stop,bad_request}
  end.

change_user_rights(Acc, LServer, User, Chat, ID, Lang) ->
  RequestUser = get_user_by_id(LServer,Chat,ID),
  case mod_groupchat_restrictions:validate_users(LServer,Chat,User,RequestUser) of
    ok ->
      OldCard = form_user_card(RequestUser,Chat),
      change_rights(LServer,Chat,User,RequestUser,Acc),
      Permission = [{Name,Type,Values} || {Name,Type,Values} <- Acc, Type == <<"permission">>],
      Restriction = [{Name,Type,Values} || {Name,Type,Values} <- Acc, Type == <<"restriction">>],
      {OldCard,RequestUser,Permission,Restriction,create_right_form_no_options(LServer,User,Chat,RequestUser,ID, Lang)};
    _ ->
      {stop,not_ok}
  end.

choose_name(UserCard) ->
  IsAnon = is_anon_card(UserCard),
  choose_name(UserCard,IsAnon).

choose_name(UserCard,yes) ->
  case UserCard#xabbergroupchat_user_card.nickname of
    undefined ->
      UserCard#xabbergroupchat_user_card.id;
    _ ->
      UserCard#xabbergroupchat_user_card.nickname
  end;
choose_name(UserCard,no) ->
  case UserCard#xabbergroupchat_user_card.nickname of
    undefined ->
      jid:to_string(UserCard#xabbergroupchat_user_card.jid);
    _ ->
      UserCard#xabbergroupchat_user_card.nickname
  end.


current_chat_version(Server,Chat)->
  DateNew = get_chat_version(Server,Chat),
  integer_to_binary(convert_from_datetime_to_unix_time(DateNew)).

get_vcard(_Acc,{Server,To,Chat,_Lang}) ->
  User = jid:to_string(jid:remove_resource(To)),
  Status = check_user_if_exist(Server,User,Chat),
  From = jid:from_string(Chat),
  Nick = get_nick_in_chat(Server,User,Chat),
  IsAnon = mod_groupchat_inspector:is_anonim(Server,Chat),
  case IsAnon of
    no when Status == not_exist ->
      add_user_pre_approval(Server,User,<<"member">>,Chat,<<"wait">>),
      add_wait_for_vcard(Server,User),
      ejabberd_router:route(To,jid:remove_resource(From),mod_groupchat_vcard:get_vcard()),
      ejabberd_router:route(jid:replace_resource(To,<<"Groupchat">>),jid:remove_resource(From),mod_groupchat_vcard:get_pubsub_meta()),
      {stop,ok};
    no ->
      mod_groupchat_sql:set_update_status(Server,User,<<"true">>),
      ejabberd_router:route(To,jid:remove_resource(From),mod_groupchat_vcard:get_vcard()),
      ejabberd_router:route(jid:replace_resource(To,<<"Groupchat">>),jid:remove_resource(From),mod_groupchat_vcard:get_pubsub_meta()),
      ok;
    yes when Nick == <<>> ->
      RandomNick = nick_generator:random_nick(),
      mod_groupchat_vcard:update_parse_avatar_option(Server,User,Chat,<<"no">>),
      mod_groupchat_inspector:insert_nickname(Server,User,Chat,RandomNick),
      ok;
    yes when Nick =/= <<>> ->
      mod_groupchat_vcard:update_parse_avatar_option(Server,User,Chat,<<"no">>),
      ok;
    _ ->
      {stop,not_ok}
  end.

add_user_vcard(_Acc, {_Admin,Chat,Server,
  #xabbergroupchat_invite{invite_jid = User, reason = _Reason, send = _Send}}) ->
  IsAnon = mod_groupchat_inspector:is_anonim(Server,Chat),
  case IsAnon of
    no ->
      add_wait_for_vcard(Server,User),
      From = jid:from_string(Chat),
      To = jid:from_string(User),
      ejabberd_router:route(From,To,mod_groupchat_vcard:get_vcard()),
      ejabberd_router:route(jid:replace_resource(From,<<"Groupchat">>),jid:remove_resource(To),mod_groupchat_vcard:get_pubsub_meta()),
      ok;
    _ ->
      ok
  end.

subscribe_user(_Acc, Presence) ->
  #presence{to = To, from = From} = Presence,
  Chat = jid:to_string(jid:remove_resource(To)),
  User = jid:to_string(jid:remove_resource(From)),
  Server = To#jid.lserver,
  Role = <<"member">>,
  Subscription = <<"wait">>,
  Status = check_user_if_exist(Server,User,Chat),
  case Status of
    not_exist ->
      add_user(Server,User,Role,Chat,Subscription);
    <<"none">> ->
      change_subscription(Server,Chat,User,Subscription),
      {stop,ok};
    <<"wait">> ->
      {stop,ok};
    <<"both">> ->
      {stop,exist}
  end.

pre_approval(_Acc,{Server,To,Chat,_Lang}) ->
  User = jid:to_string(jid:remove_resource(To)),
  Role = <<"member">>,
  Subscription = <<"both">>,
  Status = check_user_if_exist(Server,User,Chat),
  case Status of
    not_exist ->
      add_user_pre_approval(Server,User,Role,Chat,Subscription);
    <<"none">> ->
      change_subscription(Server,Chat,User,Subscription);
    <<"wait">> ->
      change_subscription(Server,Chat,User,Subscription);
    <<"both">> ->
      {stop,both}
  end.

is_lonely_owner(_Acc,{Server,User,Chat,_UserCard,_Lang}) ->
  Alone = is_user_alone(Server,Chat),
  OwnerAlone = is_owner_alone(Server,Chat),
  case mod_groupchat_restrictions:is_owner(Server,Chat,User) of
    no ->
      ok;
    yes when Alone == yes orelse OwnerAlone == no ->
      ok;
    yes ->
      {stop,alone}
  end.

delete_user(_Acc,{Server,User,Chat,_UserCard,_Lang}) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set subscription = 'none',user_updated_at = now() where
         username=%(User)s and chatgroup=%(Chat)s and subscription != 'none'")) of
    {updated,1} ->
      ok;
    _ ->
      {stop,no_user}
  end.

is_exist(_Acc,{Server,To,Chat,_Lang}) ->
  User = jid:to_string(jid:remove_resource(To)),
  Subscription = check_user(Server,User,Chat),
  case Subscription of
    not_exist ->
      {stop, not_ok};
    <<"both">> ->
      {stop, both};
    _ ->
      change_subscription(Server,Chat,User,<<"both">>),
      ok
  end.

is_owner(_Acc,{Server,To,Chat,_Lang}) ->
  User = jid:to_string(jid:remove_resource(To)),
  case mod_groupchat_restrictions:is_owner(Server,Chat,User) of
    yes ->
      {stop,owner};
    _ ->
      mod_groupchat_default_restrictions:set_restrictions(Server,User,Chat),
      ok
  end.

is_anon_card(UserCard) ->
  case UserCard#xabbergroupchat_user_card.jid of
    undefined -> yes;
    _ -> no
  end.

form_user_card(User,Chat) ->
  {Role,UserJID,Badge,UserId,Nick,AvatarEl,IsAnon} = get_user_info(User,Chat),
  case IsAnon of
    no ->
      #xabbergroupchat_user_card{role = Role, jid = UserJID, badge = Badge, id = UserId, nickname = Nick, avatar = AvatarEl};
    _ ->
      #xabbergroupchat_user_card{role = Role, badge = Badge, id = UserId, nickname = Nick, avatar = AvatarEl}
  end.

form_user_updated(User,Chat) ->
  UserCard = form_user_card(User,Chat),
  #xabbergroupchat_user_updated{user = UserCard}.

form_kicked(Users,Chat) ->
  UserCards = lists:map(
    fun(User) ->
      form_user_card(User,Chat) end, Users
  ),
  #xabbergroupchat_kicked{users = UserCards}.

% SQL functions
add_user(Server,Member,Role,Groupchat,Subscription) ->
  case mod_groupchat_sql:search_for_chat(Server,Member) of
    {selected,[]} ->
      add_user_to_db(Server,Member,Role,Groupchat,Subscription),
      {stop,ok};
    {selected,[_Name]} ->
      {stop,not_ok}
  end.

add_user_pre_approval(Server,Member,Role,Groupchat,Subscription) ->
  case mod_groupchat_sql:search_for_chat(Server,Member) of
    {selected,[]} ->
      add_user_to_db(Server,Member,Role,Groupchat,Subscription),
      ok;
    {selected,[_Name]} ->
      {stop,not_ok}
  end.

add_user_to_db(Server,User,Role,Chatgroup,Subscription) ->
  R = randoms:get_alphanum_string(16),
  R_s = binary_to_list(R),
  R_sl = string:to_lower(R_s),
  Id = list_to_binary(R_sl),
  ejabberd_sql:sql_query(
    Server,
    ?SQL_INSERT(
      "groupchat_users",
      ["username=%(User)s",
        "role=%(Role)s",
        "chatgroup=%(Chatgroup)s",
        "id=%(Id)s",
        "subscription=%(Subscription)s"
      ])).

user_list_to_send(Server, Groupchat) ->
 case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_users where chatgroup=%(Groupchat)s and subscription='both'")) of
   {selected,[]} ->
     [];
   {selected,[<<>>]} ->
     [];
   {selected,Users} ->
     Users
 end.

is_user_alone(Server,Chat) ->
  {selected,Users} = ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_users where chatgroup=%(Chat)s and subscription = 'both' ")),
  case length(Users) of
    _ when length(Users) > 1 ->
      no;
    _ when length(Users) == 1 ->
      yes
  end.

is_owner_alone(Server,Chat) ->
  {selected,Users} = ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_policy where chatgroup=%(Chat)s and right_name = 'owner'")),
  case length(Users) of
    _ when length(Users) > 1 ->
      no;
    _ when length(Users) == 1 ->
      yes;
    _ when length(Users) == 0 ->
      p2p
  end.

change_subscription(Server,Chat,Username,State) ->
  case ?SQL_UPSERT(Server, "groupchat_users",
    ["!username=%(Username)s",
      "!chatgroup=%(Chat)s",
      "user_updated_at = now()",
      "subscription=%(State)s"]) of
    ok ->
      ok;
    _Err ->
      {error, db_failure}
  end.

get_user_rules(Server,User,Chat) ->
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
  where groupchat_users.chatgroup = ">>,
<<"'">>,Chat,<<"' and groupchat_users.username =">>,
<<"'">>, User, <<"'">>,
<<"ORDER BY groupchat_users.username
      ">>
])
.
get_updated_users_rights(Server,Chat,Date) ->
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
  groupchat_rights.name = groupchat_policy.right_name and groupchat_policy.valid_until > CURRENT_TIMESTAMP
  )
  LEFT JOIN groupchat_users_vcard ON groupchat_users_vcard.jid = groupchat_users.username)
  LEFT JOIN groupchat_users_info ON groupchat_users_info.username = groupchat_users.username and
   groupchat_users_info.chatgroup = groupchat_users.chatgroup)
  where (groupchat_users.subscription = 'both'
  or groupchat_users.subscription = 'none') and groupchat_users.chatgroup = ">>,
      <<"'">>,Chat,<<"' and (groupchat_users.user_updated_at > ">>,
      <<"'">>, Date, <<"' or groupchat_users.last_seen > ">>,
      <<"'">>, Date, <<"')">>,
      <<" ORDER BY groupchat_users.username
      ">>
    ]).

get_updated_user_rights(Server,User,Chat,Date) ->
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
  groupchat_rights.name = groupchat_policy.right_name and groupchat_policy.valid_until > CURRENT_TIMESTAMP
  and groupchat_policy.issued_at > ">>,ejabberd_sql:escape(Date),<<"
  )
  LEFT JOIN groupchat_users_vcard ON groupchat_users_vcard.jid = groupchat_users.username)
  LEFT JOIN groupchat_users_info ON groupchat_users_info.username = groupchat_users.username and
   groupchat_users_info.chatgroup = groupchat_users.chatgroup)
  where groupchat_users.chatgroup = ">>,
      <<"'">>,ejabberd_sql:escape(Chat),<<"' and groupchat_users.username =">>,
      <<"'">>, ejabberd_sql:escape(User), <<"' and groupchat_users.user_updated_at =">>,
      <<"'">>, ejabberd_sql:escape(Date), <<"'">>,
      <<"ORDER BY groupchat_users.username
      ">>
    ]).

get_chat_version(Server,Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    [
      <<"select max(greatest(user_updated_at,last_seen)) from groupchat_users where chatgroup='">>,Chat,<<"';">>
    ]) of
    {selected,_,[[Max]]} ->
      Max;
    _ ->
      error
  end.

check_user(Server,User,Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(subscription)s
         from groupchat_users where chatgroup=%(Chat)s
              and username=%(User)s and (subscription = 'both' or subscription = 'wait')")) of
    {selected,[]} ->
      not_exist;
    {selected,[{Subscription}]} ->
      Subscription
  end.

check_user_if_exist(Server,User,Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(subscription)s
         from groupchat_users where chatgroup=%(Chat)s
              and username=%(User)s")) of
    {selected,[]} ->
      not_exist;
    {selected,[{Subscription}]} ->
      Subscription
  end.

check_user_if_exist_by_id(Server,ID,Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(subscription)s
         from groupchat_users where chatgroup=%(Chat)s
              and id=%(ID)s")) of
    {selected,[]} ->
      not_exist;
    {selected,[{Subscription}]} ->
      Subscription
  end.

update_user_status(Server,User,Chat) ->
  ejabberd_sql:sql_query(
    Server,
    [
      <<"update groupchat_users set user_updated_at = now() where chatgroup='">>,ejabberd_sql:escape(Chat),<<"' and username = '">>,ejabberd_sql:escape(User),<<"';">>
    ]).

insert_badge(_L,_U,_C,undefined) ->
  ok;
insert_badge(LServer,User,Chat,Badge) ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update groupchat_users set badge = %(Badge)s where chatgroup=%(Chat)s and username=%(User)s")).

insert_nickname(_L,_U,_C,undefined) ->
  ok;
insert_nickname(LServer,User,Chat,Nick) ->
  case is_duplicated_nick(LServer,Chat,Nick,User) of
    true -> add_random_badge(LServer,User,Chat);
    _ -> ok
  end,
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update groupchat_users set nickname = %(Nick)s where chatgroup=%(Chat)s and username=%(User)s")).

add_random_badge(LServer,User,Chat) ->
  Badge = rand:uniform(1000),
  insert_badge(LServer,User,Chat,integer_to_binary(Badge)).

is_duplicated_nick(LServer,Chat,Nick,User) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(nickname)s from groupchat_users where chatgroup=%(Chat)s and nickname=%(Nick)s and username!=%(User)s")) of
    {selected,[]} ->
      false;
    _ ->
      true
  end.

get_user_by_id(Server,Chat,Id) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_users where chatgroup=%(Chat)s and id=%(Id)s")) of
    {selected,[{User}]} ->
      User;
    _ ->
      none
  end.

get_user_by_id_and_allow_to_invite(Server,Chat,Id) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_users where chatgroup=%(Chat)s and id=%(Id)s and p2p_state ='true' ")) of
    {selected,[{User}]} ->
      User;
    _ ->
      none
  end.

is_anonim(Server,Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(jid)s from groupchats
    where jid = %(Chat)s
    and anonymous = 'incognito'")) of
    {selected,[{null}]} ->
      no;
    {selected,[]} ->
      no;
    {selected,[{}]} ->
      no;
    _ ->
      yes
  end.

% Internal functions

convert_from_unix_time_to_datetime(UnixTime) ->
  UnixEpoch = 62167219200,  %calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}) Time from 0 to 1970
  {{Y,M,D},{H,Min,Sec}} = calendar:gregorian_seconds_to_datetime(UnixEpoch + UnixTime),
  Year = integer_to_binary(Y),
  Month = integer_to_binary(M),
  Day = integer_to_binary(D),
  Hours = integer_to_binary(H),
  Minutes = integer_to_binary(Min),
  Seconds = integer_to_binary(Sec),
  <<Year/binary,"-",Month/binary,"-",Day/binary," ",Hours/binary,":",Minutes/binary,":",Seconds/binary>>.

convert_from_datetime_to_unix_time(DateTime) ->
  UnixEpoch = 62167219200,
  [DateBinary,TimeBinary] = binary:split(DateTime,<<" ">>,[global]),
  [Y,M,D]= binary:split(DateBinary,<<"-">>,[global]),
  [H,Min,SecRaw] = binary:split(TimeBinary,<<":">>,[global]),
  SplitSec = binary:split(SecRaw,<<".">>,[global]),
  Sec = case length(SplitSec) of
          1 ->
            [SSeconds] = SplitSec,
            SSeconds;
          _ ->
            [SSeconds|_Mill] = SplitSec,
            SSeconds
        end,
  Year = binary_to_integer(Y),
  Month = binary_to_integer(M),
  Day = binary_to_integer(D),
  Hours = binary_to_integer(H),
  Minutes = binary_to_integer(Min),
  Seconds = binary_to_integer(Sec),
  GS = calendar:datetime_to_gregorian_seconds({{Year,Month,Day},{Hours,Minutes,Seconds}}),
  GS - UnixEpoch.


get_user_info(User,Chat) ->
  ChatJID = jid:from_string(Chat),
  Server = ChatJID#jid.lserver,
  IsAnon = mod_groupchat_chats:is_anonim(Server,Chat),
  {selected,_Tables,Items} = get_user_rules(Server,User,Chat),
  [Item|_] = Items,
  [Username,Badge,UserId,Chat,_Rule,_RuleDesc,_Type,_Subscription,GV,FN,NickVcard,NickChat,_ValidFrom,_IssuedAt,_IssuedBy,_VcardImage,_Avatar,_LastSeen] = Item,
  UserRights = [{_R,_RD,T,_VF,_ISA,_ISB}||[UserS,_Badge,_UID,_C,_R,_RD,T,_S,_GV,_FN,_NV,_NC,_VF,_ISA,_ISB,_VI,_AV,_LS] <-Items, UserS == Username, T == <<"permission">> orelse T == <<"restriction">>],
  Nick = case nick(GV,FN,NickVcard,NickChat,IsAnon) of
           empty when IsAnon == no->
             Username;
           empty when IsAnon == yes ->
             RandomNick = nick_generator:random_nick(),
             insert_nickname(Server,Username,Chat,RandomNick),
             RandomNick;
           {ok,Value} ->
             Value;
           _ ->
             <<>>
         end,
  Role = calculate_role(UserRights),
  UserJID = jid:from_string(User),
  AvatarEl = xmpp:decode(mod_groupchat_vcard:get_photo_meta(Server,Username,Chat)),
  BadgeF = case Badge of
             null ->
               <<>>;
             Another ->
               Another
           end,
  {Role,UserJID,BadgeF,UserId,Nick,AvatarEl,IsAnon}.

nick(GV,FN,NickVcard,NickChat,IsAnon) ->
  case NickChat of
    _ when (GV == null orelse GV == <<>>)
      andalso (FN == null orelse FN == <<>>)
      andalso (NickVcard == null orelse NickVcard == <<>>)
      andalso (NickChat == null orelse NickChat == <<>>)->
      empty;
    _  when NickChat =/= null andalso NickChat =/= <<>>->
      {ok,NickChat};
    _  when NickVcard =/= null andalso NickVcard =/= <<>> andalso IsAnon == no ->
      {ok,NickVcard};
    _  when GV =/= null andalso GV =/= <<>> andalso IsAnon == no ->
      {ok,GV};
    _  when FN =/= null andalso FN =/= <<>> andalso IsAnon == no ->
      {ok,FN};
    _ ->
      empty
  end.

calculate_role(UserPerm) ->
  IsOwner = [R||{R,_RD,_T,_VF,_IssiedAt,_IssiedBy} <-UserPerm, R == <<"owner">>],
  case length(IsOwner) of
    0 ->
      IsAdmin = [T||{_R,_RD,T,_VF,_VU,_S} <-UserPerm, T == <<"permission">>],
      case length(IsAdmin) of
        0 ->
          <<"member">>;
        _ ->
          <<"admin">>
      end;
    _ ->
      <<"owner">>
  end.

get_users_from_chat(Iq) ->
  #iq{to = To,from = From, lang = Lang} = Iq,
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  User = jid:to_string(jid:remove_resource(From)),
  {selected,_Tables,Items} = mod_groupchat_restrictions:user_from_chat_with_rights(Chat,To#jid.lserver),
  DateNew = get_chat_version(Server,Chat),
  VersionNew = integer_to_binary(convert_from_datetime_to_unix_time(DateNew)),
  A = query_chat(parse_items(Items,[],User,Lang),VersionNew),
  ejabberd_router:route(xmpp:make_iq_result(Iq,A)).

query_chat(Items,Version) ->
  {xmlel,<<"query">>,[{<<"xmlns">>,<<"http://xabber.com/protocol/groupchat#members">>},{<<"version">>,Version}],
    Items}.

validate_data(_Acc, _LServer,_Chat,_Admin,_ID,undefined, undefined,_Lang) ->
  {stop, {error, xmpp:err_bad_request()}};
validate_data(_Acc, LServer,Chat,Admin,ID,_Nickname,_Badge,_Lang) ->
  User = case ID of
           <<>> ->
             Admin;
           _ ->
             get_user_by_id(LServer,Chat,ID)
         end,
  check_user(User).

check_user(none) ->
  {stop, {error,xmpp:err_item_not_found()}};
check_user(User) when is_binary(User) ->
  User.

validate_rights(Admin,_LServer,_Chat,Admin,_ID,_Nickname,undefined,_Lang) ->
  Admin;
validate_rights(User, _LServer,Chat,Admin,_ID,Nickname,undefined,_Lang) when Nickname =/= undefined ->
  SetNick = mod_groupchat_restrictions:is_permitted(<<"change-nicknames">>,Admin,Chat),
  case SetNick of
    yes ->
      User;
    _ ->
      {stop, {error, xmpp:err_not_allowed()}}
  end;
validate_rights(User, _LServer,Chat,Admin,_ID,undefined,Badge,_Lang) when Badge =/= undefined ->
  SetBadge = mod_groupchat_restrictions:is_permitted(<<"change-badges">>,Admin,Chat),
  case SetBadge of
    yes ->
      User;
    _ ->
      {stop, {error, xmpp:err_not_allowed()}}
  end;
validate_rights(User, _LServer,Chat,Admin,_ID,Nickname,Badge,_Lang) when Badge =/= undefined andalso Nickname =/= undefined ->
  SetBadge = mod_groupchat_restrictions:is_permitted(<<"change-badges">>,Admin,Chat),
  SetNick = mod_groupchat_restrictions:is_permitted(<<"change-nicknames">>,Admin,Chat),
  case SetBadge of
    yes when SetNick == yes ->
      User;
    _ ->
      {stop, {error, xmpp:err_not_allowed()}}
  end.

update_user(User, LServer,Chat, _Admin,_ID,Nickname,Badge,_Lang) ->
  UserCard = form_user_card(User,Chat),
  insert_badge(LServer,User,Chat,Badge),
  insert_nickname(LServer,User,Chat,Nickname),
  {User,UserCard}.

parse_items([],Acc,_User,_Lang) ->
  Acc;
parse_items(Items,Acc,UserRequester,Lang) ->
  [Item|_RestItems] = Items,
  [Username,Badge,UserId,Chat,_Rule,_RuleDesc,_Type, Subscription,GV,FN,NickVcard,NickChat,_ValidFrom,_IssuedAt,_IssuedBy,_VcardImage,_Avatar,LastSeen] = Item,
  UserPerm = [[User,_Badge,_UID,_C,_R,_RD,_T,_S,_GV,_FN,_NV,_NC,_VF,_ISA,_ISB,_VI,_AV,_LS]||[User,_Badge,_UID,_C,_R,_RD,_T,_S,_GV,_FN,_NV,_NC,_VF,_ISA,_ISB,_VI,_AV,_LS] <-Items, User == Username],
  UserRights = [{_R,_RuD,T,_VF,_ISA,_ISB}||[User,_Badge,_UID,_C,_R,_RuD,T,_S,_GV,_FN,_NV,_NC,_VF,_ISA,_ISB,_VI,_AV,_LS] <-Items, User == Username, T == <<"permission">> orelse T == <<"restriction">>],
  ChatJid = jid:from_string(Chat),
  Server = ChatJid#jid.lserver,
  Nick = case nick(GV,FN,NickVcard,NickChat) of
           empty ->
             Username;
           {ok,Value} ->
             Value;
           _ ->
             <<>>
         end,
  Rest = Items -- UserPerm,
  Role = calculate_role(UserRights),
  NickNameEl = {xmlel,<<"nickname">>,[],[{xmlcdata, Nick}]},
  JidEl = {xmlel,<<"jid">>,[],[{xmlcdata, Username}]},
  UserIdEl = {xmlel,<<"id">>,[],[{xmlcdata, UserId}]},
  RoleEl = {xmlel,<<"role">>,[],[{xmlcdata, Role}]},
  SubEl = {xmlel,<<"subscription">>,[],[{xmlcdata, Subscription}]},
  AvatarEl = mod_groupchat_vcard:get_photo_meta(Server,Username,Chat),
  BadgeEl = badge(Badge),
  S = mod_groupchat_present_mnesia:select_sessions(Username,Chat),
  L = length(S),
  LastSeenEl = case L of
                 0 ->
                   {xmlel,<<"present">>,[],[{xmlcdata, LastSeen}]};
                 _ ->
                   {xmlel,<<"present">>,[],[{xmlcdata, <<"now">>}]}
               end,
  IsAnon = is_anonim(Server,Chat),
  case UserRights of
    [] when IsAnon == no ->
      Children = [UserIdEl, SubEl,LastSeenEl,JidEl,RoleEl,BadgeEl,NickNameEl,AvatarEl],
      parse_items(Rest,[{xmlel,<<"item">>,[],Children}|Acc],UserRequester,Lang);
    _ when IsAnon == no->
      Children = [UserIdEl|[SubEl|[LastSeenEl|[JidEl|[RoleEl|[BadgeEl|[NickNameEl|[AvatarEl|parse_list(UserRights,Lang)]]]]]]]],
      parse_items(Rest,[{xmlel,<<"item">>,[],Children}|Acc],UserRequester,Lang);
    [] when IsAnon == yes andalso Username == UserRequester ->
      Children = [UserIdEl, SubEl,LastSeenEl,JidEl,RoleEl,BadgeEl,NickNameEl,AvatarEl],
      parse_items(Rest,[{xmlel,<<"item">>,[],Children}|Acc],UserRequester,Lang);
    _ when IsAnon == yes andalso Username == UserRequester ->
      Children = [UserIdEl|[SubEl|[LastSeenEl|[JidEl|[RoleEl|[BadgeEl|[NickNameEl|[AvatarEl|parse_list(UserRights,Lang)]]]]]]]],
      parse_items(Rest,[{xmlel,<<"item">>,[],Children}|Acc],UserRequester,Lang);
    [] when IsAnon == yes ->
      Children = [UserIdEl, SubEl,LastSeenEl,RoleEl,BadgeEl,NickNameEl,AvatarEl],
      parse_items(Rest,[{xmlel,<<"item">>,[],Children}|Acc],UserRequester,Lang);
    _ when IsAnon == yes->
      Children = [UserIdEl|[SubEl|[LastSeenEl|[RoleEl|[BadgeEl|[NickNameEl|[AvatarEl|parse_list(UserRights,Lang)]]]]]]],
      parse_items(Rest,[{xmlel,<<"item">>,[],Children}|Acc],UserRequester,Lang)
  end.

badge(Badge) ->
  case Badge of
    null ->
      {xmlel,<<"badge">>,[],[{xmlcdata,<<>>}]};
    _ ->
      {xmlel,<<"badge">>,[],[{xmlcdata,Badge}]}
  end.

parse_list(List,Lang) ->
  lists:map(fun(N) -> parser(N,Lang) end, List).

parser(Right,Lang) ->
  {Rule,RuleDesc,Type,ValidUntil,IssuedAt,IssuedBy} = Right,
  {xmlel,Type,[
    {<<"name">>,Rule},
    {<<"translation">>,translate:translate(Lang,RuleDesc)},
    {<<"expires">>,ValidUntil},
    {<<"issued-by">>,IssuedBy},
    {<<"issued-at">>,IssuedAt}
  ],[]}.

nick(GV,FN,NickVcard,NickChat) ->
  case NickChat of
    _ when (GV == null orelse GV == <<>>)
      andalso (FN == null orelse FN == <<>>)
      andalso (NickVcard == null orelse NickVcard == <<>>)
      andalso (NickChat == null orelse NickChat == <<>>)->
      empty;
    _  when NickChat =/= null andalso NickChat =/= <<>>->
      {ok,NickChat};
    _  when NickVcard =/= null andalso NickVcard =/= <<>>->
      {ok,NickVcard};
    _  when GV =/= null andalso GV =/= <<>>->
      {ok,GV};
    _  when FN =/= null andalso FN =/= <<>>->
      {ok,FN};
    _ ->
      {bad_request}
  end.

user_no_read(Server,Chat) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_policy where chatgroup=%(Chat)s and right_name='read-messages'
    and valid_until > CURRENT_TIMESTAMP")).

get_nick_in_chat(Server,User,Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(nickname)s from groupchat_users
    where chatgroup=%(Chat)s and username=%(User)s")) of
    {selected,[]} ->
      <<>>;
    {selected,[{Nick}]} ->
      Nick
  end.

add_wait_for_vcard(Server,Jid) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(jid)s from groupchat_users_vcard
    where jid=%(Jid)s")) of
    {selected,[]} ->
      ejabberd_sql:sql_query(
        Server,
        ?SQL_INSERT(
          "groupchat_users_vcard",
          ["jid=%(Jid)s",
            "fullupdate='true'"]));
    {selected,[{_Nick}]} ->
      ok
  end.

get_users_page(LServer,Limit,Page) ->
  Offset = case Page of
             _  when Page > 0 ->
               Limit * (Page - 1)
           end,
  ChatInfo = case ejabberd_sql:sql_query(
    LServer,
    [<<"(select username from users) EXCEPT (select localpart from groupchats) order by username limit ">>,integer_to_binary(Limit),<<" offset ">>,integer_to_binary(Offset),<<";">>]) of
               {selected,_Tab, Chats} ->
                 Chats;
               _ -> []
             end,
  lists:map(
    fun(Chat) ->
      [Name] = Chat,
      binary_to_list(Name) end, ChatInfo
  ).

get_user_info_for_peer_to_peer(LServer,User,Chat) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(avatar_id)s,@(avatar_type)s,@(avatar_url)s,@(avatar_size)d,@(nickname)s,@(parse_avatar)s,
    @(badge)s
         from groupchat_users where chatgroup=%(Chat)s
              and username=%(User)s")) of
    {selected,[]} ->
      not_exist;
    {selected,[Info]} ->
      Info
  end.

add_user_to_peer_to_peer_chat(LServer,User,Chat,AvatarID,AvatarType,AvatarUrl,AvatarSize,Nickname,ParseAvatar,Badge) ->
  Role = <<"member">>,
  Subscription = <<"wait">>,
  R = randoms:get_alphanum_string(16),
  R_s = binary_to_list(R),
  R_sl = string:to_lower(R_s),
  Id = list_to_binary(R_sl),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL_INSERT(
      "groupchat_users",
      ["username=%(User)s",
        "role=%(Role)s",
        "chatgroup=%(Chat)s",
        "id=%(Id)s",
        "subscription=%(Subscription)s",
        "avatar_id=%(AvatarID)s",
        "avatar_type=%(AvatarType)s",
        "avatar_url=%(AvatarUrl)s",
        "avatar_size=%(AvatarSize)d",
        "nickname=%(Nickname)s",
        "parse_avatar=%(ParseAvatar)s",
        "badge=%(Badge)s"
      ])).

change_peer_to_peer_invitation_state(LServer,User,Chat,State) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("update groupchat_users set p2p_state = %(State)s where
         username=%(User)s and chatgroup=%(Chat)s")) of
    {updated,1} ->
      ok;
    _ ->
      {stop,no_user}
  end.

%% user rights change functions
user_rights(LServer,Chat,User) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(right_name)s from groupchat_policy where username=%(User)s
    and chatgroup=%(Chat)s and valid_until > now()")) of
    {selected,Rights} ->
      Rights;
    _ ->
      []
  end.

user_rights_and_time(LServer,Chat,User) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(groupchat_policy.right_name)s,@(groupchat_rights.type)s,
    @(COALESCE(to_char(groupchat_policy.valid_until, 'YYYY-MM-DD HH24:MI:SS')))s
    from groupchat_policy left join groupchat_rights on groupchat_rights.name = groupchat_policy.right_name where username=%(User)s
    and chatgroup=%(Chat)s and valid_until > now()")) of
    {selected,Rights} ->
      Rights;
    _ ->
      []
  end.

create_right_form(LServer,User,Chat,RequestUser,ID, Lang) ->
  UserRights = user_rights(LServer,Chat,User),
  IsOwner = lists:member({<<"owner">>},UserRights),
  CanRestrictUsers = lists:member({<<"restrict-participants">>},UserRights),
  case IsOwner of
    true ->
      RightsAndTime = user_rights_and_time(LServer,Chat,RequestUser),
      Fields = [
        #xdata_field{var = <<"FORM_TYPE">>, type = hidden, values = [?NS_GROUPCHAT_RIGHTS]},
        #xdata_field{var = <<"user-id">>, type = hidden, values = [ID]}| make_fields_owner(LServer,RightsAndTime,Lang)
      ],
      #xabbergroupchat{
        xmlns = ?NS_GROUPCHAT_RIGHTS,
        sub_els = [
          #xdata{type = form,
            title = <<"Groupchat user's rights change">>,
            instructions = [<<"Fill out this form to change the rights of user">>],
            fields = Fields}
        ]};
    _ when CanRestrictUsers == true ->
      RightsAndTime = user_rights_and_time(LServer,Chat,RequestUser),
      Fields = [
        #xdata_field{var = <<"FORM_TYPE">>, type = hidden, values = [?NS_GROUPCHAT_RIGHTS]},
        #xdata_field{var = <<"user-id">>, type = hidden, values = [ID]}| make_fields_admin(LServer,RightsAndTime,Lang)
      ],
      #xabbergroupchat{
        xmlns = ?NS_GROUPCHAT_RIGHTS,
        sub_els = [
          #xdata{type = form,
            title = <<"Groupchat user's rights change">>,
            instructions = [<<"Fill out this form to change the rights of user">>],
            fields = Fields}
        ]};
    _ ->
      create_empty_form(ID)
  end.

create_right_form_no_options(LServer,User,Chat,RequestUser,ID, Lang) ->
  UserRights = user_rights(LServer,Chat,User),
  IsOwner = lists:member({<<"owner">>},UserRights),
  CanRestrictUsers = lists:member({<<"restrict-participants">>},UserRights),
  case IsOwner of
    true ->
      RightsAndTime = user_rights_and_time(LServer,Chat,RequestUser),
      Fields = [
        #xdata_field{var = <<"FORM_TYPE">>, type = hidden, values = [?NS_GROUPCHAT_RIGHTS]},
        #xdata_field{var = <<"user-id">>, type = hidden, values = [ID]}| make_fields_owner_no_options(LServer,RightsAndTime,Lang,'list-single')
      ],
      #xabbergroupchat{
        xmlns = ?NS_GROUPCHAT_RIGHTS,
        sub_els = [
          #xdata{type = result,
            title = <<"Groupchat user's rights change">>,
            instructions = [<<"Fill out this form to change the rights of user">>],
            fields = Fields}
        ]};
    _ when CanRestrictUsers == true ->
      RightsAndTime = user_rights_and_time(LServer,Chat,RequestUser),
      Fields = [
        #xdata_field{var = <<"FORM_TYPE">>, type = hidden, values = [?NS_GROUPCHAT_RIGHTS]},
        #xdata_field{var = <<"user-id">>, type = hidden, values = [ID]}| make_fields_admin_no_options(LServer,RightsAndTime,Lang)
      ],
      #xabbergroupchat{
        xmlns = ?NS_GROUPCHAT_RIGHTS,
        sub_els = [
          #xdata{type = result,
            title = <<"Groupchat user's rights change">>,
            instructions = [<<"Fill out this form to change the rights of user">>],
            fields = Fields}
        ]};
    _ ->
      create_empty_form(ID)
  end.

create_empty_form(ID) ->
  Fields = [
    #xdata_field{var = <<"FORM_TYPE">>, type = hidden, values = [?NS_GROUPCHAT_RIGHTS]},
    #xdata_field{var = <<"user-id">>, type = hidden, values = [ID]}
    ],
  #xabbergroupchat{
    xmlns = ?NS_GROUPCHAT_RIGHTS,
    sub_els = [
      #xdata{type = form,
        title = <<"Groupchat user s rights change">>,
        instructions = [<<"Fill out this form to change the rights of user">>],
        fields = Fields}
    ]}.

make_fields_owner(LServer,RightsAndTime,Lang) ->
  AllRights = mod_groupchat_restrictions:get_all_rights(LServer),
  ExistingRights = [{UR,ExTime}|| {UR,_UT,ExTime} <- RightsAndTime],
  Permissions = [{R,D}||{R,T,D} <- AllRights, T == <<"permission">>],
  Restrictions = [{R,D}||{R,T,D} <- AllRights, T == <<"restriction">>],
  PermissionsFields = lists:map(fun(Right) ->
    {Name,Desc} = Right,
    Values = get_time(Name,ExistingRights),
    #xdata_field{var = Name, label = translate:translate(Lang,Desc), type = 'list-single',
      values = Values,
      options = get_options(Values)
    }
            end, Permissions
  ),
  RestrictionsFields = lists:map(fun(Right) ->
    {Name,Desc} = Right,
    Values = get_time(Name,ExistingRights),
    #xdata_field{var = Name, label = translate:translate(Lang,Desc), type = 'list-single',
      values = Values,
      options = get_options(Values)
    }
                                end, Restrictions
  ),
  PermissionSection = [#xdata_field{var= <<"permission">>, type = 'fixed', values = [<<"Permissions:">>]}],
  RestrictionSection = [#xdata_field{var= <<"restriction">>, type = 'fixed', values = [<<"Restrictions:">>]}],
  PermissionSection ++ PermissionsFields ++ RestrictionSection ++ RestrictionsFields.

make_fields_owner_no_options(LServer,RightsAndTime,Lang,Type) ->
  AllRights = mod_groupchat_restrictions:get_all_rights(LServer),
  ExistingRights = [{UR,ExTime}|| {UR,_UT,ExTime} <- RightsAndTime],
  Permissions = [{R,D}||{R,T,D} <- AllRights, T == <<"permission">>],
  Restrictions = [{R,D}||{R,T,D} <- AllRights, T == <<"restriction">>],
  PermissionsFields = lists:map(fun(Right) ->
    {Name,Desc} = Right,
    Values = get_time(Name,ExistingRights),
    #xdata_field{var = Name, label = translate:translate(Lang,Desc), type = Type,
      values = Values
    }
                                end, Permissions
  ),
  RestrictionsFields = lists:map(fun(Right) ->
    {Name,Desc} = Right,
    Values = get_time(Name,ExistingRights),
    #xdata_field{var = Name, label = translate:translate(Lang,Desc), type = Type,
      values = Values
    }
                                 end, Restrictions
  ),
  PermissionSection = [#xdata_field{var= <<"permission">>, type = 'fixed', values = [<<"Permissions:">>]}],
  RestrictionSection = [#xdata_field{var= <<"restriction">>, type = 'fixed', values = [<<"Restrictions:">>]}],
  PermissionSection ++ PermissionsFields ++ RestrictionSection ++ RestrictionsFields.

make_fields_admin(LServer,RightsAndTime,Lang) ->
  AllRights = mod_groupchat_restrictions:get_all_rights(LServer),
  ExistingRights = [{UR,ExTime}|| {UR,_UT,ExTime} <- RightsAndTime],
  Restrictions = [{R,D}||{R,T,D} <- AllRights, T == <<"restriction">>],
  RestrictionsFields = lists:map(fun(Right) ->
    {Name,Desc} = Right,
    Values = get_time(Name,ExistingRights),
    #xdata_field{var = Name, label = translate:translate(Lang,Desc), type = 'list-single',
      values = Values,
      options = get_options(Values)
    }
                                 end, Restrictions
  ),
  RestrictionSection = [#xdata_field{var= <<"restriction">>, type = 'fixed', values = [<<"Restrictions:">>]}],
  RestrictionSection ++ RestrictionsFields.

make_fields_admin_no_options(LServer,RightsAndTime,Lang) ->
  AllRights = mod_groupchat_restrictions:get_all_rights(LServer),
  ExistingRights = [{UR,ExTime}|| {UR,_UT,ExTime} <- RightsAndTime],
  Restrictions = [{R,D}||{R,T,D} <- AllRights, T == <<"restriction">>],
  RestrictionsFields = lists:map(fun(Right) ->
    {Name,Desc} = Right,
    Values = get_time(Name,ExistingRights),
    #xdata_field{var = Name, label = translate:translate(Lang,Desc), type = 'list-single',
      values = Values
    }
                                 end, Restrictions
  ),
  RestrictionSection = [#xdata_field{var= <<"restriction">>, type = 'fixed', values = [<<"Restrictions:">>]}],
  RestrictionSection ++ RestrictionsFields.

get_time(Right,RightsList) ->
  case lists:keyfind(Right,1,RightsList) of
    {Right,Time} ->
      [convert_time(Time)];
    _ ->
      []
  end.
get_options([]) ->
  form_options();
get_options([<<"0">>]) ->
  form_options();
get_options([Value]) ->
  [#xdata_option{label = <<"current">>, value = [Value]}| form_options()].

form_options() ->
  [
    #xdata_option{label = <<"5 minutes">>, value = [<<"5 minutes">>]},
    #xdata_option{label = <<"10 minutes">>, value = [<<"10 minutes">>]},
    #xdata_option{label = <<"15 minutes">>, value = [<<"15 minutes">>]},
    #xdata_option{label = <<"30 minutes">>, value = [<<"30 minutes">>]},
    #xdata_option{label = <<"1 hour">>, value = [<<"1 hour">>]},
    #xdata_option{label = <<"1 week">>, value = [<<"1 week">>]},
    #xdata_option{label = <<"1 month">>, value = [<<"1 month">>]},
    #xdata_option{label = <<"Forever">>, value = [<<"0">>]}
  ].

convert_time(Time) ->
  TimeNow = calendar:datetime_to_gregorian_seconds(calendar:universal_time()) - 62167219200,
  UnixTime = convert_from_datetime_to_unix_time(Time),
  Diff = UnixTime - TimeNow,
  case Diff of
    _ when Diff < 3153600000 ->
      integer_to_binary(UnixTime);
    _ ->
      <<"0">>
  end.

-spec decode(binary(),list()) -> list().
decode(LServer, FS) ->
  Decoded = decode(LServer, [],filter_fixed_fields(FS)),
  case lists:member(false,Decoded) of
    true ->
      not_ok;
    _ ->
      {ok,Decoded}
  end.

-spec decode(binary(),list(),list()) -> list().
decode(LServer, Acc,[#xdata_field{var = Var, values = Values} | RestFS]) ->
  decode(LServer,[get_and_validate(LServer,Var,Values)| Acc], RestFS);
decode(_LServer, Acc, []) ->
  Acc.

-spec filter_fixed_fields(list()) -> list().
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
get_and_validate(LServer,RightName,Value) ->
  AllRights = mod_groupchat_restrictions:get_all_rights(LServer),
  case lists:keyfind(RightName,1,AllRights) of
    {RightName,Type,_Desc} ->
      {RightName,Type,Value};
    _ ->
      false
  end.

is_valid_value([],_ValidValues) ->
  true;
is_valid_value([Value],ValidValues) ->
  lists:member(Value,ValidValues);
is_valid_value(_Other,_ValidValues) ->
  false.

valid_values() ->
  [<<"0">>,<<"5 minutes">>,<<"10 minutes">>,<<"15 minutes">>,<<"30 minutes">>,<<"1 hour">>,<<"1 week">>,<<"1 month">>].

validate([]) ->
  {stop,bad_request};
validate(FS) ->
  ValidValues = valid_values(),
  Validation = lists:map(fun(El) ->
    {_Rightname,_Type,Values} = El,
    is_valid_value(Values,ValidValues)
            end, FS),
  IsFailed = lists:member(false, Validation),
  case IsFailed of
    false ->
      FS;
    _ ->
      {stop, bad_request}
  end.

change_rights(LServer,Chat,Admin,RequestUser,Rights) ->
  lists:foreach(fun(Right) ->
    {Rule,_Type,ExpireOption} = Right,
    Expires = set_expires(ExpireOption),
    mod_groupchat_restrictions:set_rule(LServer,Rule,Expires,RequestUser,Chat,Admin)
                end, Rights).

set_expires([]) ->
  <<"0 years">>;
set_expires([<<"0">>]) ->
  <<"1000 years">>;
set_expires(ExpireOption) ->
  list_to_binary(ExpireOption).

current_values(LServer,User,Chat) ->
  AllRights = mod_groupchat_restrictions:get_all_rights(LServer),
  RightsAndTime = user_rights_and_time(LServer,Chat,User),
  lists:map(fun(El) ->
    {Name,Type,_Desc} = El,
    case lists:keyfind(Name,1,RightsAndTime) of
      {Name,Type,ExTime} ->
        {Name,Type,[integer_to_binary(convert_from_datetime_to_unix_time(ExTime))]};
      _ ->
        {Name,Type,[]}
    end
            end, AllRights).

% New methods for user list

get_user_from_chat(LServer,Chat,User) ->
  Request = ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
  @(groupchat_users.username)s,
  @(groupchat_users.id)s,
  @(groupchat_users.badge)s,
  @(groupchat_users.nickname)s,
  @(groupchat_users_vcard.givenfamily)s,
  @(groupchat_users_vcard.fn)s,
  @(groupchat_users_vcard.nickname)s,
  @(COALESCE(to_char(groupchat_users.last_seen, 'YYYY-MM-DD HH24:MI:SS')))s
  from groupchat_users left join groupchat_users_vcard on groupchat_users_vcard.jid = groupchat_users.username where groupchat_users.chatgroup = %(Chat)s and groupchat_users.username = %(User)s
   and subscription = 'both'")),
  SubEls = case Request of
             {selected,[]} ->
               [];
             {selected,[UserInfo]} ->
               IsAnon = mod_groupchat_chats:is_anonim(LServer,Chat),
               {Username,Id,Badge,NickChat,GF,FullName,NickVcard,LastSeen} = UserInfo,
               Nick = case nick(GF,FullName,NickVcard,NickChat,IsAnon) of
                        empty when IsAnon == no->
                          Username;
                        empty when IsAnon == yes ->
                          RandomNick = nick_generator:random_nick(),
                          insert_nickname(LServer,Username,Chat,RandomNick),
                          RandomNick;
                        {ok,Value} ->
                          Value;
                        _ ->
                          <<>>
                      end,
               Role = calculate_role(LServer,Username,Chat),
               AvatarEl = xmpp:decode(mod_groupchat_vcard:get_photo_meta(LServer,Username,Chat)),
               BadgeF = case Badge of
                          null ->
                            <<>>;
                          Another ->
                            Another
                        end,
               S = mod_groupchat_present_mnesia:select_sessions(Username,Chat),
               L = length(S),
               Present = case L of
                           0 ->
                             LastSeen;
                           _ ->
                             undefined
                         end,
               [#xabbergroupchat_user_card{id = Id, jid = jid:from_string(Username), nickname = Nick, role = Role, avatar = AvatarEl, badge = BadgeF, present = Present}];
             _ ->
               []
           end,
  DateNew = get_chat_version(LServer,Chat),
  VersionNew = convert_from_datetime_to_unix_time(DateNew),
  #xabbergroupchat{xmlns = ?NS_GROUPCHAT_MEMBERS, sub_els = SubEls, version = VersionNew}.

get_users_from_chat(LServer,Chat,RequesterUser,RSM,Version) ->
  {QueryChats, QueryCount} = make_sql_query(Chat,RSM,Version),
  {selected, _, Res} = ejabberd_sql:sql_query(LServer, QueryChats),
  {selected, _, [[CountBinary]]} = ejabberd_sql:sql_query(LServer, QueryCount),
  Users = make_query(LServer,Res,RequesterUser,Chat),
  Count = binary_to_integer(CountBinary),
  ?INFO_MSG("Users in query ~p~nCount ~p~n",[Users,Count]),
  SubEls = case Users of
             [_|_] when RSM /= undefined ->
               #xabbergroupchat_user_card{id = First} = hd(Users),
               #xabbergroupchat_user_card{id = Last} = lists:last(Users),
               [#rsm_set{first = #rsm_first{data = First},
                 last = Last,
                 count = Count}|Users];
             [] when RSM /= undefined ->
               [#rsm_set{count = Count}|Users];
             _ ->
               Users
           end,
  DateNew = get_chat_version(LServer,Chat),
  VersionNew = convert_from_datetime_to_unix_time(DateNew),
  #xabbergroupchat{xmlns = ?NS_GROUPCHAT_MEMBERS, sub_els = SubEls, version = VersionNew}.

make_sql_query(SChat,RSM,Version) ->
  {Max, Direction, Item} = get_max_direction_item(RSM),
  Chat = ejabberd_sql:escape(SChat),
  LimitClause = if is_integer(Max), Max >= 0 ->
    [<<" limit ">>, integer_to_binary(Max)];
                  true ->
                    []
                end,
  Users = [<<"select
  groupchat_users.username,
  groupchat_users.id,
  groupchat_users.badge,
  groupchat_users.nickname,
  groupchat_users_vcard.givenfamily,
  groupchat_users_vcard.fn,
  groupchat_users_vcard.nickname,
  COALESCE(to_char(groupchat_users.last_seen, 'YYYY-MM-DD HH24:MI:SS'))
  from groupchat_users left join groupchat_users_vcard on groupchat_users_vcard.jid = groupchat_users.username where chatgroup = '">>,Chat,<<"'
   and subscription = 'both' ">>],
  PageClause = case Item of
                 B when is_binary(B) ->
                   case Direction of
                     before ->
                       [<<" AND groupchat_users.nickname > '">>, Item,<<"' ">>];
                     'after' ->
                       [<<" AND groupchat_users.nickname < '">>, Item,<<"' ">>];
                     _ ->
                       []
                   end;
                 _ ->
                   []
               end,
  VersionClause = case Version of
                    I when is_integer(I) ->
                      Date = convert_from_unix_time_to_datetime(Version),
                      [<<" and (groupchat_users.user_updated_at > ">>,
                        <<"'">>, Date, <<"' or groupchat_users.last_seen > ">>,
                        <<"'">>, Date, <<"')">>];
                    _ ->
                      []
                  end,
  Query = [Users,VersionClause,PageClause],
  QueryPage =
    case Direction of
      before ->
        % ID can be empty because of
        % XEP-0059: Result Set Management
        % 2.5 Requesting the Last Page in a Result Set
        [<<"SELECT * FROM (">>, Query,
          <<" GROUP BY
  groupchat_users.username,
  groupchat_users.id,
  groupchat_users.badge,
  groupchat_users.nickname,
  groupchat_users_vcard.givenfamily,
  groupchat_users_vcard.fn,
  groupchat_users_vcard.nickname,
  COALESCE(to_char(groupchat_users.last_seen, 'YYYY-MM-DD HH24:MI:SS'))
  ORDER BY groupchat_users.id ASC ">>,
          LimitClause, <<") AS c ORDER BY groupchat_users.id DESC;">>];
      _ ->
        [Query, <<" GROUP BY
  groupchat_users.username, groupchat_users.id, groupchat_users.badge, groupchat_users.nickname, groupchat_users_vcard.givenfamily, groupchat_users_vcard.fn, groupchat_users_vcard.nickname,COALESCE(to_char(groupchat_users.last_seen, 'YYYY-MM-DD HH24:MI:SS'))
        ORDER BY groupchat_users.id DESC ">>,
          LimitClause, <<";">>]
    end,

      {QueryPage,[<<"SELECT COUNT(*) FROM (">>,Users,
        <<" GROUP BY groupchat_users.username, groupchat_users.id, groupchat_users.badge, groupchat_users.nickname, groupchat_users_vcard.givenfamily, groupchat_users_vcard.fn, groupchat_users_vcard.nickname, COALESCE(to_char(groupchat_users.last_seen, 'YYYY-MM-DD HH24:MI:SS'))) as subquery;">>]}.

get_max_direction_item(RSM) ->
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

make_query(LServer,RawData,RequesterUser,Chat) ->
  IsAnon = mod_groupchat_chats:is_anonim(LServer,Chat),
  RequesterUserRole = calculate_role(LServer,RequesterUser,Chat),
  lists:map(
    fun(UserInfo) ->
      [Username,Id,Badge,NickChat,GF,FullName,NickVcard,LastSeen] = UserInfo,
      Nick = case nick(GF,FullName,NickVcard,NickChat,IsAnon) of
               empty when IsAnon == no->
                 Username;
               empty when IsAnon == yes ->
                 RandomNick = nick_generator:random_nick(),
                 insert_nickname(LServer,Username,Chat,RandomNick),
                 RandomNick;
               {ok,Value} ->
                 Value;
               _ ->
                 <<>>
             end,
      Role = calculate_role(LServer,Username,Chat),
      AvatarEl = xmpp:decode(mod_groupchat_vcard:get_photo_meta(LServer,Username,Chat)),
      BadgeF = case Badge of
                 null ->
                   <<>>;
                 Another ->
                   Another
               end,
      S = mod_groupchat_present_mnesia:select_sessions(Username,Chat),
      L = length(S),
      Present = case L of
                     0 ->
                       LastSeen;
                     _ ->
                       undefined
                   end,
      case IsAnon of
        no ->
          #xabbergroupchat_user_card{id = Id, jid = jid:from_string(Username), nickname = Nick, role = Role, avatar = AvatarEl, badge = BadgeF, present = Present};
        _ when RequesterUser == Username ->
          #xabbergroupchat_user_card{id = Id, jid = jid:from_string(Username), nickname = Nick, role = Role, avatar = AvatarEl, badge = BadgeF, present = Present};
        _ when RequesterUserRole == <<"owner">> ->
          #xabbergroupchat_user_card{id = Id, jid = jid:from_string(Username), nickname = Nick, role = Role, avatar = AvatarEl, badge = BadgeF, present = Present};
        _ ->
          #xabbergroupchat_user_card{id = Id, nickname = Nick, role = Role, avatar = AvatarEl, badge = BadgeF, present = Present}
      end
       end, RawData
  ).

calculate_role(LServer,Username,Chat) ->
  Rights =  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(right_name)s,@(type)s from groupchat_policy left join groupchat_rights on groupchat_rights.name = right_name where username=%(Username)s
     and chatgroup=%(Chat)s and valid_until > CURRENT_TIMESTAMP")) of
              {selected, Res} ->
                Res;
              _ ->
                []
            end,
  IsOwner = [R||{R,_T} <- Rights, R == <<"owner">>],
  case length(IsOwner) of
    0 ->
      IsAdmin = [T||{_R,T} <- Rights, T == <<"permission">>],
      case length(IsAdmin) of
        0 ->
          <<"member">>;
        _ ->
          <<"admin">>
      end;
    _ ->
      <<"owner">>
  end.

get_all_user(LServer,Chat) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(username)s from groupchat_users where chatgroup=%(Chat)s")) of
    {selected,Users} ->
      Users;
    _ ->
      []
  end.