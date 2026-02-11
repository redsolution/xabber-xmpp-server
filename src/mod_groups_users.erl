%%%-------------------------------------------------------------------
%%% File    : mod_groups_users.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : Manage users in groupchats
%%% Created : 22 Jan 2026 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%%
%%%
%%% xabberserver, Copyright (C) 2007-2026   Redsolution
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

-module(mod_groups_users).
-author('ilya.kalashnikov@redsolution.com').
-behavior(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).

%% gen_mod
-export([start/2, stop/1, depends/2, mod_options/1]).
%% API
-export([
  user_subscription/3,
  get_group_member/4,
  get_group_members/6,
  user_card/2,
  users_to_send/2,
  add_user/6,
  is_in_group/3,
  check_if_exist/3,
  update_last_seen/3,
  get_user_id/3,
  get_user_by_id/3,
  add_user_to_p2p_group/4,
  update_user_status/4,
  get_nick_in_chat/3,
  check_invited_to_p2p/3,
  change_p2p_invitation_state/4,
  get_users_from_p2p/2,
  add_owner/4,
  get_owners/2,
  is_owner/3,
  change_user_permitted/4,
  is_permitted/6,
  update_member_query/4,
  user_role/3,
  add_invited_user/4,
  kick_user/3,
  delete_user/3,
  deny_user_avatar/3
]).

-export([subscribe_user/4]).
%% Hook groups_presence_subscribed
-export([process_subscribed/2]).

% Delete group
-export([unsubscribe_all_for_delete/2]).


start(Host, _Opts) ->
  ejabberd_hooks:add(groups_presence_subscribed, Host, ?MODULE, process_subscribed, 20).

stop(Host) ->
  ejabberd_hooks:delete(groups_presence_subscribed, Host, ?MODULE, process_subscribed, 20).


depends(_Host, _Opts) ->  [].

mod_options(_Opts) -> [].

%%External

update_member_query(Server, Group, Actor, Iq) ->
  #iq{sub_els = [#groups_members{id = UserID,
    members = [NewCard]}]} = Iq,
  {User, UserID1} = if
                  UserID == <<"0">> -> {Actor, undefined};
                  true -> {undefined, UserID}
                end,
  [JIDS, UserID, _, CurBadge, CurNick, _, Role] =
    get_user_info(Server, Group, User, UserID1),
  IsNewBadge = case NewCard#groups_user.badge of
                 undefined -> false;
                 CurBadge -> false;
                 _ -> true
               end,
  case change_user_permitted(Server, Group, Actor, JIDS, IsNewBadge) of
    true ->
      CurCard = #groups_user{id = UserID, nickname = CurNick,
        badge = CurBadge, role = Role},
      update_user(Server, Group, JIDS, CurCard, NewCard, Iq);
    _ ->
      {error, xmpp:err_not_allowed()}
  end.

%%update_member_query(Server, Group, Actor, ID, NewCard) ->
%%  {User, ID1} = if
%%                   ID == <<"0">> -> {Actor, undefined};
%%                   true -> {undefined, ID}
%%                 end,
%%  [JIDS, UserID, _, CurBadge, CurNick, _, Role] =
%%    get_user_info(Server, Group, User, ID1),
%%  IsNewBadge = case NewCard#groups_user.badge of
%%                 undefined -> false;
%%                 CurBadge -> false;
%%                 _ -> true
%%               end,
%%  case change_user_permitted(Server, Group, Actor, JIDS, IsNewBadge) of
%%    true ->
%%      CurCard = #groups_user{id = UserID, nickname = CurNick,
%%        badge = CurBadge, role = Role},
%%      update_user(Server, Group, JIDS, CurCard, NewCard);
%%    _ ->
%%      {error, xmpp:err_not_allowed()}
%%  end.

get_group_member(Server, Group, User, ID) ->
  {User1, ID1} = if
                   ID == <<"0">> -> {User, undefined};
                   true -> {undefined, ID}
                 end,

  case get_user_info(Server, Group, User1, ID1) of
    [Username, Id, _Sub, Badge, Nick, LastSeen, Role] ->
      IsAnon = mod_groups_chats:is_anon(Group),
      AvatarEl = mod_groups_vcard:get_user_avatar(Server, Username, Group),
      Last = case mod_groups_messages:select_sessions(Username, Group) of
               [] ->
                 Stamp = misc:usec_to_now(LastSeen * 1000000),
                 #groups_last{stamp = Stamp};
               _ -> undefined
             end,
      CanSeeJID = mod_groups_users:is_permitted(Server, Group, User,
        block_user, false, []),
      JID = if
              IsAnon andalso not CanSeeJID  -> undefined;
              true -> jid:from_string(Username)
            end,
      UserCard = #groups_user{ id = Id,
        nickname = Nick, role = Role, avatar = AvatarEl,
        badge = Badge, last = Last, jid = JID},
      #groups_members{members = [UserCard]};
    _ ->
      {error, xmpp:err_item_not_found()}
  end.

get_group_members(Server, Group, RequesterUser, RSM, Version, XData) ->
  Filters = get_filters(XData),
  {QueryChats, QueryCount} = make_sql_query(Group, RSM, Version, Filters),
  {selected, _, Res} = ejabberd_sql:sql_query(Server, QueryChats),
  {selected, _, [[CountBinary]]} = ejabberd_sql:sql_query(Server, QueryCount),
  Users = make_query(Server,Res,RequesterUser, Group),
  Count = binary_to_integer(CountBinary),
  SubEls = case Users of
             [_|_] when RSM /= undefined ->
               #groups_user{nickname = First} = hd(Users),
               #groups_user{nickname = Last} = lists:last(Users),
               [#rsm_set{first = #rsm_first{data = First},
                 last = Last,
                 count = Count}|Users];
             [] when RSM /= undefined ->
               [#rsm_set{count = Count}|Users];
             _ ->
               Users
           end,
  NewVer = get_chat_version(Server, Group),
  #groups_members{members = SubEls, version = NewVer}.


add_invited_user(Server, Group, User, InvitedBy) ->
  sql_add_invited_user(Server, Group, User, InvitedBy).

user_role(Server, User, Group) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(role)s from groupchat_users "
    " where chatgroup=%(Group)s and username=%(User)s")) of
    {selected,[{Role}]} -> Role;
    _ -> <<"member">>
  end.

kick_user(Server, Group, User) ->
  kick_user_from_chat(Server, Group, User),
  mod_groups_chats:update_user_counter(Group),
  ejabberd_hooks:run(groups_user_left, Server, [Server, Group, User]),
  ok.

user_card(User, Group) ->
  case get_user_info(User, Group) of
    error ->
      #groups_user{};
    {Role, UserJID, Badge, UserId, Nick, AvatarEl, false} ->
      #groups_user{role = Role, jid = UserJID,
        badge = Badge, id = UserId, nickname = Nick, avatar = AvatarEl};
    {Role, _UserJID, Badge, UserId, Nick, AvatarEl, true} ->
      #groups_user{role = Role, badge = Badge,
        id = UserId, nickname = Nick, avatar = AvatarEl}
  end.

process_subscribed(_Acc, {Server, UserJID, Group}) ->
  User = jid:to_string(jid:remove_resource(UserJID)),
  Status = user_subscription(Server, User, Group),
  case Status of
    <<"wait">> ->
      change_subscription(Server, Group, User, <<"both">>),
      mod_groups_chats:update_user_counter(Group),
      ok;
    <<"both">> ->
      {stop, both};
    _ ->
      ?ERROR_MSG("Wrong subscription: user ~s, group ~s, status, ~s",
        [User, Group, Status]),
      {stop, error}
  end.

%%Internal

make_query(Server, RawData, Requester, Group) ->
  IsAnon = mod_groups_chats:is_anon(Group),
  CanSeeJID = mod_groups_users:is_permitted(Server, Group, Requester,
    block_user, false, []),
  lists:map(
    fun(UserInfo) ->
      [Username, Id, Badge, LastSeen, Nick, Role] = UserInfo,
      AvatarEl = mod_groups_vcard:get_user_avatar(Server, Username, Group),
      Last = case mod_groups_messages:select_sessions(Username, Group) of
                  [] ->
                    LSI = binary_to_integer(LastSeen),
                    Stamp = misc:usec_to_now(LSI * 1000000),
                    #groups_last{stamp = Stamp};
                  _ -> undefined
                end,
      Badge1 = case Badge of
                <<>> -> undefined;
                _ -> Badge
              end,
      Card = #groups_user{id = Id, nickname = Nick,
        role = Role, avatar = AvatarEl, badge = Badge1, last = Last},
      WithoutJID = IsAnon andalso Requester /= Username andalso
        not CanSeeJID,
      if
        WithoutJID -> Card;
        true -> Card#groups_user{jid = jid:from_string(Username)}
      end
    end, RawData).

get_user_info(User, Group) ->
  ChatJID = jid:from_string(Group),
  Server = ChatJID#jid.lserver,
  case get_user_info(Server, User, Group) of
    [Username, UserId, _Subs, Badge, Nick, _Last, Role] ->
      IsAnon = mod_groups_chats:is_anon(Group),
      UserJID = jid:from_string(User),
      Avatar = mod_groups_vcard:get_user_avatar(Server,Username, Group),
      {Role, UserJID, Badge, UserId, Nick, Avatar, IsAnon};
    _ ->
      error
  end.

change_user_permitted(_Server, _Group, Actor, Actor, false) ->
  true;
change_user_permitted(Server, Group, Actor, Actor, true) ->
  is_permitted(Server, Group, Actor, change_user_info, false, []);
change_user_permitted(Server, Group, Actor, User, _IsNewBadge) ->
  change_user_permitted(Server, Group, Actor, User).

change_user_permitted(Server, Group, Actor, User) ->
  Roles = sql_get_roles(Server, Group, Actor, User),
  ActorRole = proplists:get_value(Actor, Roles, <<"member">>),
  UserRole = proplists:get_value(User, Roles, <<"member">>),
  if
    UserRole == <<"owner">> -> false;
    ActorRole == <<"owner">> -> true;
    UserRole == <<"admin">> -> false;
    true ->
      ejabberd_hooks:run_fold(groups_is_permitted, Server, false,
        [change_user_info, Group, Actor, []])
  end.

update_user(Server, Group, User, CurCard, NewCard, Iq) ->
  case update_avatar(Server, Group, User, Iq,
    NewCard#groups_user.avatar) of
    continue ->
      update_nick_and_badge(Server, Group, User,
        CurCard, NewCard);
    R -> R
  end.

%%update_user(Server, Group, User, CurCard, NewCard) ->
%%  case update_avatar(Server, Group, User,
%%    NewCard#groups_user.avatar) of
%%    continue ->
%%      update_nick_and_badge(Server, Group, User,
%%        CurCard, NewCard);
%%    {error, Err} ->
%%      {error, Err};
%%    NewInfo ->
%%      CurCard#groups_user{avatar = NewInfo}
%%  end.

update_nick_and_badge(_Server, _Group, _User,
    #groups_user{nickname = Nick, badge = Badge},
    #groups_user{nickname = Nick, badge = Badge}) ->
  ok;
update_nick_and_badge(_Server, _Group, _User, _CurCard,
    #groups_user{nickname = undefined, badge = undefined}) ->
  ok;
update_nick_and_badge(Server, Group, User, CurCard, NewCard) ->
  #groups_user{nickname = CurNick, badge = CurBadge} = CurCard,
  #groups_user{nickname = NewNick, badge = NewBadge} = NewCard,
  Nick = case NewNick of
           undefined -> CurNick;
            _ -> NewNick
         end,
  Badge = case NewBadge of
            undefined -> CurBadge;
            _ -> NewBadge
          end,
  case check_nick_badge(Server, Group, Nick, Badge) of
    true ->
      sql_update_nick_and_badge(Server, Group, User, Nick, Badge),
      ejabberd_hooks:run(groups_user_changed,
        Server, [Server, Group, User, CurCard]),
      ok;
    _ when Nick == CurNick ->
      {error, xmpp:err_conflict()};
    _ when Badge == CurBadge ->
      rand:uniform(1000),
      sql_update_nick_and_badge(Server, Group, User, Nick,
        rand:uniform(1000)),
      ejabberd_hooks:run(groups_user_changed,
        Server, [Server, Group, User, CurCard]),
      ok;
    _ ->
      {error, xmpp:err_conflict()}
  end.

check_nick_badge(Server, Group, Nick, Badge) ->
  sql_check_nick_badge(Server, Group, Nick, Badge).

update_avatar(_Server, _Group, _User, _Iq, undefined) ->
  continue;
update_avatar(Server, Group, User, Iq, #groups_avatar{info = undefined}) ->
%% delete_avatar
  mod_groups_vcard:user_update_avatar(Server, Group, User, Iq, undefined),
  ignore;
update_avatar(Server, Group, User, Iq, #groups_avatar{info = Info} = Avatar) ->
  ID = Info#avatar_info.id,
  case  mod_groups_vcard:get_user_avatar(Server, User, Group) of
    #groups_avatar{info = #avatar_info{id = ID}} ->
      ok;
    _ ->
      mod_groups_vcard:user_update_avatar(Server,Group, User, Iq, Avatar),
      ignore
  end.

get_chat_version(Server, Group) ->
  sql_get_chat_version(Server, Group).

kick_user_from_chat(Server, Group, User) ->
  case sql_kick_user(Server, Group, User) of
    ok ->
      mod_groups_messages:delete_all_user_sessions(User, Group),
      UserJID = jid:from_string(User),
      ChatJID = jid:from_string(Group),
      ejabberd_router:route(ChatJID, UserJID,
        #presence{type = unsubscribe, id = randoms:get_string()}),
      ejabberd_router:route(ChatJID, UserJID,
        #presence{type = unavailable, id = randoms:get_string()});
    _ ->
      ok
  end.

delete_user(Server, Group, User) ->
  IsBoth = check_if_exist(Server, Group, User),
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set role = 'none', subscription = 'none', "
    " user_updated_at = (now() at time zone 'utc'), "
    " last_seen = (now() at time zone 'utc') where "
    " username=%(User)s and chatgroup=%(Group)s and subscription != 'none'")) of
    {updated,1} when IsBoth ->
      mod_groups_messages:delete_all_user_sessions(User, Group),
      mod_groups_chats:update_user_counter(Group),
      ok;
    _ ->
      {stop,no_user}
  end.

change_subscription(Server, Group, User, Sub) ->
  sql_change_subscription(Server, Group, User, Sub).

change_auto_nickname(_Server, _Group, _User, false) ->
  ok;
change_auto_nickname(Server, Group, User, Nick) ->
   case mod_groups_chats:is_anon(Group) of
     false -> sql_change_auto_nickname(Server, Group,
       User, Nick);
     _ ->
       ok
   end.


sql_get_chat_version(Server, Group) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select EXTRACT(EPOCH FROM max(greatest(user_updated_at,last_seen)))::BIGINT"
    " as @(ver)s from groupchat_users where chatgroup=%(Group)s")) of
    {selected, [{Result}]} -> Result;
    _ ->
      error
  end.

sql_get_roles(Server, Group, User1, User2) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s,@(role)s from groupchat_users "
    " where chatgroup=%(Group)s and "
    " (username=%(User1)s or username=%(User2)s)")) of
    {selected, Result} -> Result;
    _ -> []
  end.

sql_update_nick_and_badge(Server, Group, User, Nick, Badge) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set nickname = %(Nick)s, "
    " badge = %(Badge)s, "
    " user_updated_at = (now() at time zone 'utc') where
         username=%(User)s and chatgroup=%(Group)s")).

sql_check_nick_badge(Server, Group, Nick, Badge) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s
     from groupchat_users where chatgroup=%(Group)s
      and (nickname=%(Nick)s or auto_nickname=%(Nick)s)
      and badge=%(Badge)s")) of
    {selected,[]} -> true;
    _ -> false
  end.

sql_add_invited_user(Server, Group, User, InvitedBy) ->
  Role = <<"member">>,
  Sub = <<"wait">>,
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set subscription=%(Sub)s,"
    " invited_by=%(InvitedBy)s where chatgroup=%(Group)s "
    " and username=%(User)s and subscription='none'")) of
    {updated,N} when N > 0 ->
      ok;
    _ ->
      sql_add_user(Server, User, Role, Group, Sub, InvitedBy, false)
  end.


sql_add_user(Server, User, Role, Group, Subs, InvitedBy, Nick) ->
  ID = str:to_lower(randoms:get_alphanum_string(16)),
  {_, Privacy, _, _, _, _, _, _, _, _, _} =
    mod_groups_chats:db_get_info(Server, Group),
%%  IsAnon = mod_groups_chats:is_anon(Group),
  ?INFO_MSG("!!!!!!!~p ~p",[Group, Privacy]),
  F = fun() ->
    {ANN, UseUserAvatar} =
      case Privacy of
        incognito -> {ID, false};
        _ when Nick /= false ->{Nick, true};
        _ -> {User, true}
%%          Nick = case sql_get_vcard_nickname_t(User) of
%%                   not_exist -> User;
%%                   V -> V
%%                 end,
%%          {Nick, true}
      end,
    Badge = case ejabberd_sql:sql_query_t(
      ?SQL("select @(username)s from groupchat_users "
      " where chatgroup=%(Group)s and "
      " (nickname=%(ANN)s or auto_nickname=%(ANN)s)"
      " and badge != '' ")) of
              {selected, [_|_]} -> rand:uniform(1000);
              _ -> <<"">>
            end,
    ejabberd_sql:sql_query_t(
      ?SQL_INSERT(
        "groupchat_users",
        ["username=%(User)s",
          "role=%(Role)s",
          "chatgroup=%(Group)s",
          "id=%(ID)s",
          "subscription=%(Subs)s",
          "invited_by=%(InvitedBy)s",
          "auto_nickname=%(ANN)s",
          "badge=%(Badge)s",
          "use_user_avatar=%(UseUserAvatar)b"
        ]))
      end,
  ejabberd_sql:sql_transaction(Server, F),
  case Privacy of
    incognito ->
      make_nick_avatar(Server, User, Group, ID);
    _ -> ok
  end.

sql_kick_user(Server, Group, User) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set subscription = 'none', role = 'none', "
    " user_updated_at = (now() at time zone 'utc'), "
    " last_seen = (now() at time zone 'utc') where "
    " username=%(User)s and chatgroup=%(Group)s and subscription != 'none'")) of
    {updated, 1} -> ok;
    _ ->
      error
  end.

sql_change_subscription(Server, Group, User, Sub) ->
  Role = case Sub of
           <<"none">> -> <<"none">>;
           _ -> <<"member">>
         end,
  case ?SQL_UPSERT(Server, "groupchat_users",
    ["!username=%(User)s",
      "!chatgroup=%(Group)s",
      "user_updated_at = (now() at time zone 'utc')",
      "subscription=%(Sub)s",
      "role=%(Role)s"]) of
    ok ->
      ok;
    _Err ->
      {error, db_failure}
  end.

sql_change_auto_nickname(Server, Group, User, Nick) ->
  F = fun() ->
    Badge = case ejabberd_sql:sql_query_t(
      ?SQL("select @(username)s from groupchat_users "
      " where chatgroup=%(Group)s and "
      " (nickname=%(Nick)s or auto_nickname=%(Nick)s)"
      " and badge != '' ")) of
              {selected, [_|_]} -> rand:uniform(1000);
              _ -> <<"">>
            end,
    ejabberd_sql:sql_query_t(
    ?SQL("update groupchat_users set auto_nickname = %(Nick)s, "
    " badge = %(Badge)s, user_updated_at = (now() at time zone 'utc') "
    " where username=%(User)s and chatgroup=%(Group)s"))
    end,
  ejabberd_sql:sql_transaction(Server, F).

unsubscribe_all_for_delete(LServer,Chat) ->
  Users = get_all_participants(LServer,Chat),
  From = jid:from_string(Chat),
  lists:foreach(fun(To) ->
    ejabberd_router:route(#presence{type = unsubscribe,
      id = randoms:get_string(), from = From, to = To}),
    ejabberd_router:route(#presence{type = unsubscribed,
      id = randoms:get_string(), from = From, to = To})
                end,
    Users
  ).

subscribe_user(Server, Group, User, Nick) ->
  Role = <<"member">>,
  Subs = <<"wait">>,
  case user_subscription(Server, User, Group) of
    not_exist ->
      add_user(Server, User, Role, Group , Subs, <<>>, Nick);
    <<"none">> ->
      change_auto_nickname(Server, Group, User, Nick),
      change_subscription(Server, Group, User, Subs),
      ok;
    <<"wait">> ->
      change_auto_nickname(Server, Group, User, Nick),
      ok;
    <<"both">> ->
      change_auto_nickname(Server, Group, User, Nick),
      exist
  end.

users_to_send(Server, Group) ->
  Users = sql_users_to_send(Server, Group),
  [jid:from_string(U) || {U} <- Users].

add_user(Server, Member, Role, Group, Subs, InvitedBy) ->
  add_user(Server, Member, Role, Group, Subs, InvitedBy, false).

add_user(Server, Member, Role, Group, Subs, InvitedBy, Nick) ->
  {MUser, MServer, _} = jid:tolower(jid:from_string(Member)),
  case mod_xabber_entity:is_group(MUser, MServer) of
    false ->
      sql_add_user(Server, Member, Role, Group, Subs, InvitedBy, Nick),
      ok;
    _ ->
      not_allowed
  end.

get_owners(Server, Group)->
  sql_get_owners(Server, Group).

is_owner(Server, Group, Member) ->
  lists:member(Member, get_owners(Server, Group)).

add_owner(Server, Group, Requester, MemberID) ->
  case mod_groups_users:get_user_by_id(Server, Group, MemberID) of
    none -> {error, not_found};
    Requester -> {error, not_allowed};
    Member ->
      Owners = get_owners(Server, Group),
      case {lists:member(Requester, Owners), lists:member(Member, Owners)} of
        {true, false} ->
          update_user_status(Server, Member, Group, <<"owner">>),
          ejabberd_hooks:run(groups_add_owner, Server, [Server, Group, Requester, Member]),
          ok;
        _ -> {error, not_allowed}
      end
  end.

% SQL functions

sql_get_owners(Server, Group) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_users "
    " where chatgroup=%(Group)s and subscription='both'"
    " and role='owner' ")) of
    {selected, Users} -> [U || {U} <- Users];
    _ -> []
  end.

%%sql_get_vcard_nickname_t(User)->
%%  case ejabberd_sql:sql_query_t(
%%    ?SQL("select
%%         CASE
%%          WHEN TRIM(nickname) != '' and nickname is not null
%%            THEN nickname
%%          WHEN TRIM(givenfamily) != '' and givenfamily is not null
%%            THEN givenfamily
%%          WHEN TRIM(fn) != '' and fn is not null
%%            THEN fn
%%          ELSE %(User)s
%%        END as @(result)s
%%      from groupchat_user_profile where jid=%(User)s"
%%    )) of
%%    {selected,[{V}]} -> V;
%%    _ -> not_exist
%%  end.

sql_users_to_send(Server, Group) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_users "
    " where chatgroup=%(Group)s and subscription='both'")) of
    {selected, Users} -> Users;
    _ -> []
  end.

sql_users_from_p2p(Server, Group) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s,@(nickname)s from groupchat_users "
    " where chatgroup=%(Group)s")) of
    {selected, Users} -> Users;
    _ -> []
  end.

get_user_info(Server, User, Group) ->
  get_user_info(Server, Group, User, undefined).

get_user_info(Server, Group, User, UserID) ->
  F = fun () ->
   User1 = case UserID of
             undefined -> User;
             _-> get_user_by_id_t(Group, UserID)
           end,
   case get_user_info_t(User1, Group) of
     {selected, [Info]} ->
       tuple_to_list(Info);
     _ ->
       {error, not_exist}
   end end,
  case ejabberd_sql:sql_transaction(Server, F) of
    {atomic, Res} -> replace_nulls(Res);
    {aborted, _Reason} -> {error, db_failure}
  end.

get_user_by_id_t(Chat,Id) ->
  case ejabberd_sql:sql_query_t(
    ?SQL("select @(username)s from groupchat_users "
    " where chatgroup=%(Chat)s and id=%(Id)s")) of
    {selected,[{User}]} -> User;
    _ -> <<>>
  end.

get_user_info_t(User, Group) ->
  ejabberd_sql:sql_query_t(?SQL(
    "select @(username)s, @(id)s, @(subscription)s, @(badge)s,
     CASE
      WHEN TRIM(nickname) != '' and nickname is not null
        THEN nickname
      ELSE auto_nickname
     END as @(r_nickname)s,
    EXTRACT(EPOCH FROM last_seen)::BIGINT as @(last)d,
    @(role)s
    from groupchat_users where
    username = %(User)s and chatgroup = %(Group)s"
  )).

user_subscription(Server, User, Group) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(subscription)s from groupchat_users "
    " where chatgroup=%(Group)s and username=%(User)s")) of
    {selected,[{Subscription}]} -> Subscription;
    _ -> not_exist
  end.

check_if_exist(Server, Group, User) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(subscription)s
         from groupchat_users where chatgroup=%(Group)s
              and username=%(User)s and subscription='both'")) of
    {selected,[{_Subscription}]} -> true;
    _ -> false
  end.

is_in_group(Server, Group, User) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(subscription)s from groupchat_users "
    " where chatgroup=%(Group)s and username=%(User)s "
    " and (subscription='both' or subscription='wait')")) of
    {selected,[{_Subscription}]} -> true;
    _ -> false
  end.

update_user_status(Server, User, Group, Role) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set "
    " user_updated_at = (now() at time zone 'utc'), role=%(Role)s "
    " where chatgroup=%(Group)s and username=%(User)s")).

update_last_seen(Server, User, Group) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set "
    " last_seen = (now() at time zone 'utc') "
    " where chatgroup=%(Group)s and username=%(User)s")).

deny_user_avatar(Server, Group, User) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set use_user_avatar=false "
    " where chatgroup=%(Group)s and username=%(User)s")).


make_nick_avatar(LServer, User, Group, UserID)->
  RandomNick =
    case mod_nick_avatar:random_nick_and_avatar(LServer) of
      {Nick, {_FileName, Bin}} ->
        mod_groups_vcard:store_user_avatar_file(LServer, Group,
          User, UserID, Bin),
        Nick;
      {Nick, _} -> Nick;
      _ ->
        Tail = integer_to_binary(erlang:system_time(second)),
        <<"Nick",Tail/binary>>
    end,
  sql_update_incognito_nickname(LServer, User, Group, RandomNick).

sql_update_incognito_nickname(LServer, User, Group, Nickname) ->
  FN = fun() ->
    case ejabberd_sql:sql_query_t(?SQL("select @(username)s
     from groupchat_users where chatgroup=%(Group)s
      and (nickname=%(Nickname)s or auto_nickname=%(Nickname)s)")) of
      {selected,[]} ->
        sql_update_auto_nickname_t(User, Group, Nickname);
      {selected, _} ->
        Ad = mod_nick_avatar:random_adjective(),
        Nickname1 = <<Ad/binary," ", Nickname/binary>>,
        sql_update_auto_nickname_t(User, Group, Nickname1);
      _ ->
        error
    end end,
  ejabberd_sql:sql_transaction(LServer, FN).

sql_update_auto_nickname_t(User, Group, Nick) ->
  ejabberd_sql:sql_query_t(
    ?SQL("update groupchat_users set auto_nickname=%(Nick)s "
    " where username=%(User)s and chatgroup=%(Group)s")).

get_user_id(LServer, User, Group) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(id)s from groupchat_users "
    " where chatgroup=%(Group)s and username=%(User)s")) of
    {selected,[{UserID}]} -> UserID;
    _ -> <<>>
  end.

get_user_by_id(Server, Group, Id) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_users "
    " where chatgroup=%(Group)s and id=%(Id)s")) of
    {selected,[{User}]} -> User;
    _ -> none
  end.

check_invited_to_p2p(Server, Group, Id) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_users "
    " where chatgroup=%(Group)s and id=%(Id)s "
    " and p2p_state ='true' and subscription='both'")) of
    {selected,[{User}]} -> User;
    _ -> false
  end.

% Internal functions

get_nick_in_chat(Server,User,Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select
     CASE
      WHEN TRIM(nickname) != '' and nickname is not null
        THEN nickname
      ELSE auto_nickname
     END as @(r_nickname)s
     from groupchat_users
     where chatgroup=%(Chat)s and username=%(User)s")) of
    {selected,[{Nick}]} ->
      Nick;
    _ ->
      <<>>
  end.

add_user_to_p2p_group(Server, User, P2PGroup, ParentGroup) ->
  Info = sql_get_user_info_for_p2p(Server, User, ParentGroup),
  sql_add_user_to_p2p_group(Server, User, P2PGroup, Info),
  Info.

sql_get_user_info_for_p2p(LServer, User, Group) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(id)s,@(avatar_id)s,@(avatar_type)s,@(avatar_url)s,@(avatar_size)d,
    CASE
      WHEN nickname != '' and nickname is not null
        THEN groupchat_users.nickname
      ELSE groupchat_users.auto_nickname
    END AS @(r_nickname)s,
    @(badge)s from groupchat_users
     where chatgroup=%(Group)s and username=%(User)s")) of
    {selected,[]} ->
      not_exist;
    {selected,[Info]} ->
      Info
  end.

sql_add_user_to_p2p_group(Server, User, Group,
    {Id, AvatarID, AvatarType, AvatarUrl, AvatarSize,
      Nickname, Badge}) ->
  UseUserAvatar = false,
  ejabberd_sql:sql_query(
    Server,
    ?SQL_INSERT(
      "groupchat_users",
      ["username=%(User)s",
        "role='member'",
        "chatgroup=%(Group)s",
        "id=%(Id)s",
        "subscription='wait'",
        "avatar_id=%(AvatarID)s",
        "avatar_type=%(AvatarType)s",
        "avatar_url=%(AvatarUrl)s",
        "avatar_size=%(AvatarSize)d",
        "nickname=%(Nickname)s",
        "auto_nickname=%(Id)s",
        "use_user_avatar=%(UseUserAvatar)b",
        "badge=%(Badge)s"
      ])).

change_p2p_invitation_state(LServer, User, Chat, State)
  when State == <<"true">> orelse State == <<"false">> ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update groupchat_users set p2p_state = %(State)s where "
    " username = %(User)s and chatgroup = %(Chat)s and 'incognito' ="
    " (select anonymous from groupchats where jid = %(Chat)s and %(LServer)H)"
    )),
    ok;
change_p2p_invitation_state(_, _, _, _) -> ok.

get_filters(#xdata{type = 'submit'} = XData) ->
  case  xmpp_util:get_xdata_values(<<"FORM_TYPE">>, XData) of
    [?NS_GROUPS] ->
      Filters = [<<"role">>, <<"badge">>, <<"nickname">>],
      lists:filtermap(fun(Filter) ->
        case  xmpp_util:get_xdata_values(Filter, XData) of
          [Value] -> {true, {Filter, Value}};
          _ -> false
        end
                      end, Filters);
    _ -> []
  end;
get_filters(_) ->
  [].

make_sql_query(SChat, RSM, Version, Filters) ->
  {Max, Direction, Item} = get_max_direction_item(RSM),
  Chat = ejabberd_sql:escape(SChat),
  SubsClause =
    case Version of
      undefined ->
        <<" and subscription = 'both'">>;
      _ ->
        <<" and (subscription = 'both' or subscription = 'none')">>
    end,
  LimitClause = if is_integer(Max), Max >= 0 ->
    [<<" limit ">>, integer_to_binary(Max)];
                  true ->
                    []
                end,
  VersionClause =
    if is_integer(Version) ->
      [<<" AND (user_updated_at > ">>,
        <<"to_timestamp(">>, Version, <<") OR last_seen > ">>,
        <<"to_timestamp(">>, Version, <<"))">>];
      true -> []
    end,
  FiltersClause = lists:map(
    fun({<<"nickname">>, Value})->
      V = ejabberd_sql:escape(Value),
      <<" and (nickname='",V/binary,"' or "
      "((nickname='' or nickname is null) "
      "and auto_nickname='",V/binary,"')) ">>;
      ({Field, Value}) ->
        V = ejabberd_sql:escape(Value),
        <<" and ",Field/binary," = '",V/binary,"' ">>
    end, Filters),

  Users = [<<"WITH group_members AS (SELECT username, id, badge,
  EXTRACT(EPOCH FROM last_seen)::BIGINT as last, role,
  CASE
  WHEN nickname != '' and nickname is not null
   THEN groupchat_users.nickname
  ELSE groupchat_users.auto_nickname
  END AS r_nickname
  FROM groupchat_users  WHERE chatgroup = '">>,Chat, <<"'">>,
    VersionClause, SubsClause, FiltersClause,
    <<") SELECT username, id, badge, last, r_nickname, role
  from group_members where 0=0 ">>],
  PageClause =
    case Item of
      B when is_binary(B) ->
        case Direction of
          before ->
            [<<" AND r_nickname < '">>, Item,<<"' ">>];
          'after' ->
            [<<" AND r_nickname > '">>, Item,<<"' ">>];
          _ ->
            []
        end;
      _ ->
        []
    end,

  Query = [Users, PageClause],
  QueryPage =
    case Direction of
      before ->
        % ID can be empty because of
        % XEP-0059: Result Set Management
        % 2.5 Requesting the Last Page in a Result Set
        [<<"SELECT * FROM (">>, Query,
          <<" ORDER BY r_nickname DESC ">>,
          LimitClause, <<") AS c ORDER BY r_nickname ASC;">>];
      _ ->
        [Query, <<" ORDER BY r_nickname ASC ">>,LimitClause,<<";">>]
    end,

  {QueryPage,[<<"SELECT COUNT(*) FROM (">>,Users,<<" ) as c;">>]}.

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

get_users_from_p2p(Server, Group)->
 sql_users_from_p2p(Server, Group).

is_permitted(Server, Group, Member, Action, true, Atts) ->
  ejabberd_hooks:run_fold(groups_is_permitted, Server, true,
    [Action, Group, Member, Atts]);
is_permitted(Server, Group, Member, Action, Default, Atts) ->
  case is_owner(Server, Group, Member) of
    true -> true;
    _ ->
      ejabberd_hooks:run_fold(groups_is_permitted, Server, Default,
        [Action, Group, Member, Atts])
  end.


%% Participants for notification of group deletion
get_all_participants(LServer,Chat) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(username)s from groupchat_users "
    " where chatgroup=%(Chat)s and subscription != 'none'")) of
    {selected,Users} -> [jid:from_string(User) || {User} <- Users];
    _ -> []
  end.

replace_nulls(List) when is_list(List) ->
  lists:map(fun(null) -> <<>>;
               (V) -> V
            end, List);
replace_nulls(Data) -> Data.
