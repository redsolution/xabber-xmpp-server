%%%-------------------------------------------------------------------
%%% File    : mod_channels_users.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Manage users in channels
%%% Created : 16 November 2020 by Andrey Gagarin <andrey.gagarin@redsolution.com>
%%%
%%%
%%% xabberserver, Copyright (C) 2007-2020   Redsolution OÜ
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

-module(mod_channels_users).
-author("andrey.gagarin@redsolution.ru").
-behavior(gen_mod).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).

-export([start/2, stop/1, depends/2, mod_options/1]).
-export([add_user/4, user_list_to_send/2, form_user_card/2, check_user_if_exist/3, get_count/2]).
% Channel subscribe hook
-export([subscribe_user/4]).
% Channel subscribed hook
-export([pre_approval/5]).
start(Host, _Opts) ->
  ejabberd_hooks:add(channel_subscribe_hook, Host, ?MODULE, subscribe_user, 60),
  ejabberd_hooks:add(channel_subscribed_hook, Host, ?MODULE, pre_approval, 60).

stop(Host) ->
  ejabberd_hooks:delete(channel_subscribe_hook, Host, ?MODULE, subscribe_user, 60),
  ejabberd_hooks:add(channel_subscribed_hook, Host, ?MODULE, pre_approval, 60).

depends(_Host, _Opts) ->
  [].

mod_options(_) -> [].

add_user(LServer, Channel, User, Subscription) ->
  R = randoms:get_alphanum_string(16),
  R_s = binary_to_list(R),
  R_sl = string:to_lower(R_s),
  Id = list_to_binary(R_sl),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL_INSERT(
      "channel_users",
      ["username=%(User)s",
        "channel=%(Channel)s",
        "id=%(Id)s",
        "subscription=%(Subscription)s"
      ])) of
    {updated,N} when N > 0 ->
      ChannelJID = jid:from_string(Channel),
      UserJID = jid:from_string(User),
      LUser = ChannelJID#jid.luser,
      PUser = UserJID#jid.luser,
      PServer = UserJID#jid.lserver,
      RosterSubscription = case Subscription of
                             <<"both">> ->
                               <<"both">>;
                             _ ->
                               <<"from">>
                           end,
      mod_admin_extra:add_rosteritem(LUser,
        LServer,PUser,PServer,PUser,<<"Users">>,RosterSubscription),
      ok;
    _ ->
      error
  end.

subscribe_user(_Acc, LServer, Channel, User) ->
  Subscription = <<"wait">>,
  Status = check_user_if_exist(LServer,User,Channel),
  case Status of
    false ->
      case add_user(LServer, Channel, User, Subscription) of
        ok -> {stop, ok};
        _ -> {stop, error}
      end;
    <<"none">> ->
      change_subscription(LServer, Channel, User, Subscription),
      {stop,ok};
    <<"wait">> ->
      {stop,ok};
    <<"both">> ->
      {stop,exist}
  end.

pre_approval(_Acc, LServer, Channel, User, _Lang) ->
  Subscription = <<"both">>,
  Status = check_user_if_exist(LServer,User,Channel),
  case Status of
    false ->
      add_user(LServer, Channel, User, Subscription);
    <<"none">> ->
      change_subscription(LServer,Channel,User,Subscription);
    <<"wait">> ->
      change_subscription(LServer,Channel,User,Subscription);
    <<"both">> ->
      {stop,both}
  end.

check_user_if_exist(LServer,User,Channel) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(subscription)s
         from channel_users where channel=%(Channel)s
              and username=%(User)s")) of
    {selected,[]} ->
      false;
    {selected,[{Subscription}]} ->
      Subscription
  end.

change_subscription(LServer,Channel,Username,State) ->
  case ?SQL_UPSERT(LServer, "channel_users",
    ["!username=%(Username)s",
      "!channel=%(Channel)s",
      "user_updated_at = (now() at time zone 'utc')",
      "subscription=%(State)s"]) of
    ok ->
      ok;
    _Err ->
      {error, db_failure}
  end.

user_list_to_send(LServer, Channel) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(username)s from channel_users where channel=%(Channel)s and subscription='both'")) of
    {selected,[]} ->
      [];
    {selected,[<<>>]} ->
      [];
    {selected,Users} ->
      Users
  end.

form_user_card(User,Channel) ->
  ChannelJID = jid:from_string(Channel),
  LServer = ChannelJID#jid.lserver,
  case get_info(LServer, User, Channel) of
    {ok,Info} ->
      [{Username,ID}] = Info,
      Role = mod_channel_rights:calculate_role(LServer,User,Channel),
      #channel_user_card{id = ID, jid = Username, role = Role};
    _ ->
      #channel_user_card{jid = User}
  end.
%%form_user_card(User,Channel) ->
%%  {Role,UserJID,Badge,UserId,Nick,AvatarEl} = get_user_info(User,Channel),
%%  #xabbergroupchat_user_card{role = Role, jid = UserJID, badge = Badge, id = UserId, nickname = Nick, avatar = AvatarEl}.
%%
%%get_user_info(User,Channel) ->
%%  ChannelJID = jid:from_string(Channel),
%%  LServer = ChannelJID#jid.lserver,
%%  {selected,_Tables,Items} = get_user_rules(LServer,User,Channel),
%%  [Item|_] = Items,
%%  [Username,Badge,UserId,Chat,_Rule,_RuleDesc,_Type,_Subscription,GV,FN,NickVcard,NickChat,_ValidFrom,_IssuedAt,_IssuedBy,_VcardImage,_Avatar,_LastSeen] = Item,
%%  UserRights = [{_R,_RD,T,_VF,_ISA,_ISB}||[UserS,_Badge,_UID,_C,_R,_RD,T,_S,_GV,_FN,_NV,_NC,_VF,_ISA,_ISB,_VI,_AV,_LS] <-Items, UserS == Username, T == <<"permission">> orelse T == <<"restriction">>],
%%  Nick = case nick(GV,FN,NickVcard,NickChat) of
%%           {ok,Value} ->
%%             Value;
%%           _ ->
%%             <<>>
%%         end,
%%  Role = calculate_role(UserRights),
%%  UserJID = jid:from_string(User),
%%  AvatarEl = mod_groupchat_vcard:get_photo_meta(LServer,Username,Chat),
%%  BadgeF = validate_badge_and_nick(LServer,Chat,User,Nick,Badge),
%%  {Role,UserJID,BadgeF,UserId,Nick,AvatarEl}.
%%

get_info(LServer, User, Channel) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(username)s,@(id)s from channel_users where channel=%(Channel)s and username =%(User)s")) of
    {selected,Users} when length(Users) > 0 ->
      {ok,Users};
    _ ->
      false
  end.

get_count(LServer, Channel) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(count(*))d from channel_users where channel=%(Channel)s and subscription = 'both' ")) of
    {selected,Users} when length(Users) > 0 ->
      [{UserCount}] = Users,
      UserCount;
    _ ->
      false
  end.
