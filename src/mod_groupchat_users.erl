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
  get_users_list_with_version/1,
  form_user_card/2,
  form_user_updated/2,
  user_list_to_send/2,
  form_kicked/2,
  is_lonely_owner/2,
  delete_user/2,
  get_updated_users_rights/3,
  get_updated_user_rights/4,
  update_user/2,
  validate_data/2,
  validate_rights/2,
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

start(Host, _Opts) ->
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
         username=%(User)s and chatgroup=%(Chat)s")) of
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
  and groupchat_policy.issued_at > ">>,Date,<<"
  )
  LEFT JOIN groupchat_users_vcard ON groupchat_users_vcard.jid = groupchat_users.username)
  LEFT JOIN groupchat_users_info ON groupchat_users_info.username = groupchat_users.username and
   groupchat_users_info.chatgroup = groupchat_users.chatgroup)
  where groupchat_users.chatgroup = ">>,
      <<"'">>,Chat,<<"' and groupchat_users.username =">>,
      <<"'">>, User, <<"' and groupchat_users.user_updated_at =">>,
      <<"'">>, Date, <<"'">>,
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

update_user_status(Server,User,Chat) ->
  ejabberd_sql:sql_query(
    Server,
    [
      <<"update groupchat_users set user_updated_at = now() where chatgroup='">>,Chat,<<"' and username = '">>,User,<<"';">>
    ]).

insert_badge(Server,User,Chat,Badge) ->
  ejabberd_sql:sql_query(
    Server,
    [
      <<"update groupchat_users set badge = '">>,Badge,<<"' , user_updated_at = now() where chatgroup='">>,Chat,<<"' and username = '">>,User,<<"';">>
    ]).

insert_nickname(Server,User,Chat,Nick) ->
  ejabberd_sql:sql_query(
    Server,
    [
      <<"update groupchat_users set nickname = '">>,Nick,<<"' , user_updated_at = now() where chatgroup='">>,Chat,<<"' and username = '">>,User,<<"';">>
    ]).

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
    _  when FN =/= null andalso FN =/= <<>> andalso IsAnon == no ->
      {ok,FN};
    _  when GV =/= null andalso GV =/= <<>> andalso IsAnon == no ->
      {ok,GV};
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

get_users_list_with_version(Iq) ->
  #iq{to = To,from = From,sub_els = Sub, lang = Lang} = Iq,
  Els = lists:map(fun(El) -> xmpp:decode(El) end, Sub),
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  User = jid:to_string(jid:remove_resource(From)),
  Q = lists:keyfind(xabbergroupchat_query_members,1,Els),
  V = Q#xabbergroupchat_query_members.version,
  VInteger = binary_to_integer(V),
  DateNew = get_chat_version(Server,Chat),
  UnixTimeNew = convert_from_datetime_to_unix_time(DateNew),
  VersionNew = integer_to_binary(UnixTimeNew),
  case VInteger of
    _ when UnixTimeNew > VInteger ->
      Date = convert_from_unix_time_to_datetime(VInteger),
      {selected,_Tables,Items} = get_updated_users_rights(Server,Chat,Date);
    _ ->
      Items = []
  end,
  A = query_chat(parse_items(Items,[],User,Lang),VersionNew),
  ejabberd_router:route(xmpp:make_iq_result(Iq,A)).

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

validate_data(_Acc,{Server,Chat,Admin,E,_Lang}) ->
  Item = E#xabbergroupchat_query_members.item,
  UserId = Item#xabbergroupchat_item.id,
  User = case UserId of
           <<>> ->
             Admin;
           _ ->
             get_user_by_id(Server,Chat,UserId)
         end,
  Nick = Item#xabbergroupchat_item.nickname,
  Badge = Item#xabbergroupchat_item.badge,
  Permission = Item#xabbergroupchat_item.permission,
  Restriction = Item#xabbergroupchat_item.restriction,
  case Nick of
    undefined when Badge == undefined andalso Permission == [] andalso Restriction == [] ->
      {stop, not_ok};
    _  when User == Admin andalso (Permission =/= [] orelse Restriction =/= []) ->
      {stop, not_ok};
    _ ->
      ok
  end.

validate_rights(_Acc,{Server,Chat,Admin,E,_Lang}) ->
  Item = E#xabbergroupchat_query_members.item,
  UserId = Item#xabbergroupchat_item.id,
  User = case UserId of
           <<>> ->
             Admin;
           _ ->
             get_user_by_id(Server,Chat,UserId)
         end,
  Nick = Item#xabbergroupchat_item.nickname,
  Badge = Item#xabbergroupchat_item.badge,
  SetBadge = mod_groupchat_restrictions:is_permitted(<<"change-badges">>,Admin,Chat),
  SetNick = mod_groupchat_restrictions:is_permitted(<<"change-nicknames">>,Admin,Chat),
  Change = mod_groupchat_restrictions:is_permitted(<<"restrict-participants">>,Admin,Chat),
  Permission = Item#xabbergroupchat_item.permission,
  Restriction = Item#xabbergroupchat_item.restriction,
  RightValidation = mod_groupchat_restrictions:validate_users(Server,Chat,Admin,User),
  case Nick of
    _ when (Badge =/= undefined andalso SetBadge == no) orelse (Nick =/= undefined
      andalso (SetNick == no andalso User =/= Admin))
      orelse (Change == no andalso (Permission =/= [] orelse Restriction =/= []))
      orelse (RightValidation == not_ok andalso (Permission =/= [] orelse Restriction =/= [])) ->
      {stop,not_ok};
    _ ->
      ok
  end.

update_user(_Acc,{Server,Chat,Admin,E,_Lang}) ->
  Item = E#xabbergroupchat_query_members.item,
  UserId = Item#xabbergroupchat_item.id,
  User = case UserId of
           <<>> ->
             Admin;
           _ ->
             get_user_by_id(Server,Chat,UserId)
         end,
  UserCard = form_user_card(User,Chat),
  Nick = Item#xabbergroupchat_item.nickname,
  Badge = Item#xabbergroupchat_item.badge,
  Permission = Item#xabbergroupchat_item.permission,
  Restriction = Item#xabbergroupchat_item.restriction,
  SetBadge = mod_groupchat_restrictions:is_permitted(<<"change-badges">>,Admin,Chat),
  SetNick = mod_groupchat_restrictions:is_permitted(<<"change-nicknames">>,Admin,Chat),
  mod_groupchat_restrictions:change_restriction(Server,Restriction,User,Chat,Admin),
  mod_groupchat_restrictions:change_permission(Server,Permission,User,Chat,Admin),
  case Nick of
    _ when Badge =/= undefined andalso SetBadge == yes andalso Nick =/= undefined andalso SetNick == yes ->
      insert_badge(Server,User,Chat,Badge),
      insert_nickname(Server,User,Chat,Nick);
    _ when Badge =/= undefined andalso SetBadge == yes andalso Nick =/= undefined andalso User == Admin ->
      insert_badge(Server,User,Chat,Badge),
      insert_nickname(Server,User,Chat,Nick);
    undefined when Badge =/= undefined andalso SetBadge == yes->
      insert_badge(Server,User,Chat,Badge);
    _ when Nick =/= undefined andalso SetNick == yes->
      insert_nickname(Server,User,Chat,Nick);
    _ when Nick =/= undefined andalso User == Admin->
      insert_nickname(Server,User,Chat,Nick);
    undefined when Badge =/= undefined andalso SetBadge == yes->
      insert_badge(Server,User,Chat,<<"">>);
    _ ->
      ok
  end,
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
%%             insert_nickname(Server,Username,Chat,Username),
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
    _  when FN =/= null andalso FN =/= <<>>->
      {ok,FN};
    _  when GV =/= null andalso GV =/= <<>>->
      {ok,GV};
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