%%%-------------------------------------------------------------------
%%% File    : mod_groups_users.erl
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

-module(mod_groups_users).
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
%%  get_user_from_chat/3,
  get_user_from_chat/4,
  get_users_from_chat/5,
  form_user_card/2,
  form_user_updated/2,
  users_to_send/2,
  form_kicked/2,
  add_user/6,
  delete_user/2,
  is_in_chat/3,
  check_if_exist/3,
  check_if_exist_by_id/3,
  convert_from_unix_time_to_datetime/1,
  convert_from_datetime_to_unix_time/1,
  current_chat_version/2,
  subscribe_user/2,
  update_last_seen/3,
  get_user_id/3,
  get_user_by_id/3, get_user_info_for_peer_to_peer/3, add_user_to_peer_to_peer_chat/4,
  update_user_status/3, user_no_read/2, get_nick_in_chat/3, get_user_by_id_and_allow_to_invite/3,
  process_subscribed/2, get_vcard/2,check_user/3,choose_name/1, add_user_vcard/2,
  change_peer_to_peer_invitation_state/4
]).

-export([is_exist/2, set_default_restrictions/2]).

%% Change user settings hook export
-export([check_if_exist/6, get_user_rights/6, validate_request/6, change_user_rights/6, user_rights/3, check_if_request_user_exist/6, user_rights_and_time/3]).

% request_own_rights hook export
-export([check_if_user_exist/5, send_user_rights/5]).

% Change user nick and badge
-export([validate_data/8, validate_rights/8, update_user/8]).

% Delete chat
-export([check_if_user_owner/4, unsubscribe_all_for_delete/2]).

% Kick user from groupchat
-export([check_if_user_can/6, check_kick/6, kick_user/6]).

% Decline hook
-export([decline_hook_check_if_exist/4, decline_hook_delete_invite/4]).

-export([calculate_role/3]).
start(Host, _Opts) ->
  ejabberd_hooks:add(groupchat_decline_invite, Host, ?MODULE, decline_hook_check_if_exist, 10),
  ejabberd_hooks:add(groupchat_decline_invite, Host, ?MODULE, decline_hook_delete_invite, 20),
  ejabberd_hooks:add(groupchat_user_kick, Host, ?MODULE, check_if_user_can, 10),
  ejabberd_hooks:add(groupchat_user_kick, Host, ?MODULE, check_kick, 20),
  ejabberd_hooks:add(groupchat_user_kick, Host, ?MODULE, kick_user, 30),
  ejabberd_hooks:add(delete_groupchat, Host, ?MODULE, check_if_user_owner, 10),
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
  ejabberd_hooks:add(groupchat_presence_subscribed_hook, Host, ?MODULE, get_vcard, 30),
  ejabberd_hooks:add(groupchat_presence_subscribed_hook, Host, ?MODULE, process_subscribed, 20),
  ejabberd_hooks:add(groupchat_presence_subscribed_hook, Host, ?MODULE, set_default_restrictions, 40),
  ejabberd_hooks:add(groupchat_invite_hook, Host, ?MODULE, add_user_vcard, 50),
  ejabberd_hooks:add(groupchat_presence_unsubscribed_hook, Host, ?MODULE, delete_user, 20).

stop(Host) ->
  ejabberd_hooks:delete(groupchat_decline_invite, Host, ?MODULE, decline_hook_check_if_exist, 10),
  ejabberd_hooks:delete(groupchat_decline_invite, Host, ?MODULE, decline_hook_delete_invite, 20),
  ejabberd_hooks:delete(groupchat_user_kick, Host, ?MODULE, check_if_user_can, 10),
  ejabberd_hooks:delete(groupchat_user_kick, Host, ?MODULE, check_kick, 20),
  ejabberd_hooks:delete(groupchat_user_kick, Host, ?MODULE, kick_user, 30),
  ejabberd_hooks:delete(delete_groupchat, Host, ?MODULE, check_if_user_owner, 10),
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
  ejabberd_hooks:delete(groupchat_presence_subscribed_hook, Host, ?MODULE, get_vcard, 30),
  ejabberd_hooks:delete(groupchat_presence_subscribed_hook, Host, ?MODULE, process_subscribed, 20),
  ejabberd_hooks:delete(groupchat_presence_subscribed_hook, Host, ?MODULE, set_default_restrictions, 40),
  ejabberd_hooks:delete(groupchat_invite_hook, Host, ?MODULE, add_user_vcard, 50),
  ejabberd_hooks:delete(groupchat_presence_unsubscribed_hook, Host, ?MODULE, delete_user, 20),
  ejabberd_hooks:delete(groupchat_presence_hook, Host, ?MODULE, subscribe_user, 60).

depends(_Host, _Opts) ->  [].

mod_options(_Opts) -> [].

% decline invite hooks

decline_hook_check_if_exist(Acc, User,Chat,Server) ->
  case is_in_chat(Server,Chat,User) of
    true ->
      Acc;
    _ ->
      Txt = <<"Member ", User/binary, " is not in chat">>,
      {stop,{error, xmpp:err_item_not_found(Txt, <<"en">>)}}
  end.

decline_hook_delete_invite(_Acc, User, Chat, Server) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set subscription = 'none',user_updated_at = (now() at time zone 'utc') where
         username=%(User)s and chatgroup=%(Chat)s and  subscription = 'wait' ")) of
    {updated,1} ->
      {stop, ok};
    {updated,0} ->
      Txt = <<"No invitation for ", User/binary, " is found in chat">>,
      {stop,{error, xmpp:err_item_not_found(Txt, <<"en">>)}};
    _ ->
      {error,xmpp:err_internal_server_error()}
  end.

% kick hook
check_if_user_can(_Acc,_LServer,Chat,Admin,_Kick,_Lang) ->
  case mod_groups_restrictions:is_permitted(<<"set-restrictions">>,Admin,Chat) of
    true ->
      ok;
    _ ->
      {stop, {error, xmpp:err_not_allowed()}}
  end.

check_kick(_Acc,LServer,Chat,Admin,Kick,_Lang) ->
  case Kick of
    #xabbergroup_kick{jid = JIDs, id = IDs} when length(JIDs) > 0 orelse length(IDs) > 0 ->
      #xabbergroup_kick{jid = JIDs, id = IDs} = Kick,
      UsersByID = lists:map(fun (Block_ID) ->
        #block_id{cdata = ID} = Block_ID,
        get_user_by_id(LServer,Chat,ID) end, IDs),
      Users = lists:map(fun (Block_JID) ->
        #block_jid{cdata = JID} = Block_JID,
        JID end, JIDs),
      V1 = lists:map(fun(User) -> validate_kick_request(LServer,Chat,Admin,User) end, Users),
      V2 = lists:map(fun(User) -> validate_kick_request(LServer,Chat,Admin,User) end, UsersByID),
      Validations = V1 ++ V2,
      case lists:member(not_ok, Validations) of
        false ->
          AllUsers = UsersByID ++ Users,
          AllUsers;
        _ ->
          {stop, {error, xmpp:err_not_allowed()}}
        end;
    _ ->
      {stop, {error, xmpp:err_bad_request()}}
  end.

kick_user(Acc, LServer, Chat, _Admin, _Kick, _Lang) ->
  lists:foreach(fun(User) -> kick_user_from_chat(LServer,Chat,User) end, Acc),
  mod_groups_chats:update_user_counter(Chat),
  Acc.

validate_kick_request(LServer,Chat, User1, User2) when User1 =/= User2 ->
  mod_groups_restrictions:validate_users(LServer,Chat,User1,User2);
validate_kick_request(_LServer,_Chat, _User1, _User2) ->
  not_ok.

kick_user_from_chat(LServer,Chat,User) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("update groupchat_users set subscription = 'none',user_updated_at = (now() at time zone 'utc') where
         username=%(User)s and chatgroup=%(Chat)s and subscription != 'none'")) of
    {updated,1} ->
      mod_groups_presence:delete_all_user_sessions(User,Chat),
      update_last_seen(LServer,User,Chat),
      UserJID = jid:from_string(User),
      ChatJID = jid:from_string(Chat),
      ejabberd_router:route(ChatJID,UserJID,#presence{type = unsubscribe, id = randoms:get_string()}),
      ejabberd_router:route(ChatJID,UserJID,#presence{type = unavailable, id = randoms:get_string()});
    _ ->
      <<>>
  end.

% delete groupchat hook
check_if_user_owner(_Acc, LServer, User, Chat) ->
  case mod_groups_restrictions:is_owner(LServer,Chat,User) of
    yes ->
      ok;
    _ ->
      {stop,{error, xmpp:err_not_allowed()}}
  end.

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

% request_own_rights hook
check_if_user_exist(Acc, LServer, User, Chat,_Lang) ->
  case check_user_if_exist(LServer,User,Chat) of
    not_exist ->
      {stop,{error, xmpp:err_item_not_found()}};
    _ ->
      Acc
  end.

send_user_rights(_Acc, LServer, User, Chat, Lang) ->
  RightsAndTime = user_rights_and_time(LServer,Chat,User),
  Fields = [
    #xdata_field{var = <<"FORM_TYPE">>, type = hidden, values = [?NS_GROUPCHAT_RIGHTS]},
    #xdata_field{var = <<"user-id">>, type = hidden, values = [<<"">>]}| make_fields_owner_no_options(LServer,RightsAndTime,Lang,'fixed')
  ],
  {stop,{ok,#xabbergroupchat{
    xmlns = ?NS_GROUPCHAT_RIGHTS,
    sub_els = [
      #xdata{type = form,
        title = <<"Group user's rights">>,
        instructions = [],
        fields = Fields}
    ]}}}.

check_if_exist(Acc, LServer, User, Chat, _ID, _Lang) ->
  case check_if_exist(LServer,Chat,User) of
    false ->
      {stop,not_ok};
    _ ->
      Acc
  end.

check_if_request_user_exist(Acc, LServer, _User, Chat, ID, _Lang) ->
  case check_if_exist_by_id(LServer,Chat,ID) of
    false ->
      {stop,not_exist};
    _ ->
      Acc
  end.

get_user_rights(_Acc, LServer, User, Chat, ID, Lang) ->
  RequestUser = get_user_by_id(LServer,Chat,ID),
  case mod_groups_restrictions:validate_users(LServer,Chat,User,RequestUser) of
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
  case mod_groups_restrictions:validate_users(LServer,Chat,User,RequestUser) of
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

get_vcard(_Acc,{Server, UserJID,Chat,_Lang}) ->
  User = jid:to_string(jid:remove_resource(UserJID)),
  From = jid:replace_resource(jid:from_string(Chat),<<"Group">>),
  To = jid:remove_resource(UserJID),
  case mod_groups_chats:is_anonim(Server,Chat) of
    true ->
      mod_groups_vcard:update_parse_avatar_option(Server,User,Chat,<<"no">>);
    _ ->
      mod_groups_vcard:set_update_status(Server,User,<<"true">>),
      ejabberd_router:route(From,To, mod_groups_vcard:get_vcard()),
      ejabberd_router:route(From,To, mod_groups_vcard:get_pubsub_meta())
  end.

add_user_vcard(_Acc, {_Admin,Chat,Server,
  #xabbergroupchat_invite{invite_jid = User, reason = _Reason, send = _Send}}) ->
  case mod_groups_chats:is_anonim(Server,Chat) of
    false ->
      add_wait_for_vcard(Server,User),
      From = jid:from_string(Chat),
      To = jid:from_string(User),
      ejabberd_router:route(From,To, mod_groups_vcard:get_vcard()),
      ejabberd_router:route(jid:replace_resource(From,<<"Group">>),jid:remove_resource(To), mod_groups_vcard:get_pubsub_meta()),
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
      case add_user(Server,User,Role,
        Chat,Subscription, <<>>) of
        ok -> ok;
        _ ->  {stop, not_allowed}
      end;
    <<"none">> ->
      change_subscription(Server,Chat,User,Subscription),
      ok;
    <<"wait">> ->
      ok;
    <<"both">> ->
      {stop, exist}
  end.

process_subscribed(_Acc,{Server,To,Chat,_Lang}) ->
  User = jid:to_string(jid:remove_resource(To)),
  Status = check_user_if_exist(Server,User,Chat),
  case Status of
    <<"wait">> ->
      change_subscription(Server, Chat, User, <<"both">>),
      mod_groups_chats:update_user_counter(Chat),
      ok;
    <<"both">> ->
      {stop,both};
    _ ->
     ?ERROR_MSG("Wrong subscription: user ~s, group ~s, status, ~s",
       [User, Chat, Status]),
      {stop, error}
  end.

delete_user(_Acc,{Server,User,Chat,_UserCard,_Lang}) ->
  Subscription = check_user(Server,User,Chat),
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set role = 'member', subscription = 'none',
    user_updated_at = (now() at time zone 'utc') where
    username=%(User)s and chatgroup=%(Chat)s and subscription != 'none'")) of
    {updated,1} when Subscription == <<"both">> ->
      mod_groups_restrictions:delete_permissions(Server, Chat, User),
      mod_groups_chats:update_user_counter(Chat),
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

set_default_restrictions(_Acc,{Server,To,Chat,_Lang}) ->
  User = jid:to_string(jid:remove_resource(To)),
  case mod_groups_restrictions:is_owner(Server,Chat,User) of
    yes ->
      {stop,owner};
    _ ->
      mod_groups_default_restrictions:set_restrictions(Server,User,Chat),
      ok
  end.

is_anon_card(UserCard) ->
  case UserCard#xabbergroupchat_user_card.jid of
    undefined -> yes;
    _ -> no
  end.

form_user_card(User,Chat) ->
  case get_user_info(User,Chat) of
    error ->
      #xabbergroupchat_user_card{};
    {Role, UserJID, Badge, UserId, Nick, AvatarEl, false} ->
      #xabbergroupchat_user_card{role = Role, jid = UserJID,
        badge = Badge, id = UserId, nickname = Nick, avatar = AvatarEl};
    {Role, _UserJID, Badge, UserId, Nick, AvatarEl, true} ->
      #xabbergroupchat_user_card{role = Role, badge = Badge,
        id = UserId, nickname = Nick, avatar = AvatarEl}
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

users_to_send(Server, Group) ->
  Users =  sql_users_to_send(Server, Group),
  [jid:from_string(U) || {U} <- Users].

add_user(Server, Member, Role, Group, Subs, InvitedBy) ->
  {MUser, MServer, _} = jid:tolower(jid:from_string(Member)),
  case mod_xabber_entity:is_group(MUser, MServer) of
    false ->
      sql_add_user(Server, Member, Role, Group, Subs, InvitedBy),
      ok;
    _ ->
      not_allowed
  end.

% SQL functions

sql_get_vcard_nickname_t(User)->
  case ejabberd_sql:sql_query_t(
    ?SQL("select
         CASE
          WHEN TRIM(nickname) != '' and nickname is not null
            THEN nickname
          WHEN TRIM(givenfamily) != '' and givenfamily is not null
            THEN givenfamily
          WHEN TRIM(fn) != '' and fn is not null
            THEN fn
          ELSE %(User)s
        END as @(result)s
      from groupchat_users_vcard where jid=%(User)s"
    )) of
    {selected,[{V}]} -> V;
    _ -> not_exist
  end.

sql_add_user(Server, User, Role, Group, Subs, InvitedBy) ->
  ID = str:to_lower(randoms:get_alphanum_string(16)),
  IsAnon = mod_groups_chats:is_anonim(Server, Group),
  F = fun() ->
    ANN = case IsAnon of
            true -> ID;
            _ ->
              case sql_get_vcard_nickname_t(User) of
                not_exist -> User;
                V -> V
              end
          end,
    Badge = case ejabberd_sql:sql_query_t(
      ?SQL("select @(username)s from groupchat_users "
      " where chatgroup=%(Group)s and (nickname=%(ANN)s or auto_nickname=%(ANN)s)"
      " and badge != ''")) of
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
          "badge=%(Badge)s"
          ]))
      end,
  ejabberd_sql:sql_transaction(Server, F),
  case mod_groups_chats:is_anonim(Server, Group) of
    true ->
      make_incognito_nickname(Server, User, Group, ID);
    _ -> ok
  end.

sql_users_to_send(Server, Group) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_users "
    " where chatgroup=%(Group)s and subscription='both'")) of
    {selected, Users} -> Users;
    _ -> []
  end.

change_subscription(Server,Chat,Username,State) ->
  case ?SQL_UPSERT(Server, "groupchat_users",
    ["!username=%(Username)s",
      "!chatgroup=%(Chat)s",
      "user_updated_at = (now() at time zone 'utc')",
      "subscription=%(State)s"]) of
    ok ->
      ok;
    _Err ->
      {error, db_failure}
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
       Role = get_user_role_t(User1, Group),
       tuple_to_list(Info) ++ [Role];
     _ ->
       {error, not_exist}
   end end,
  case ejabberd_sql:sql_transaction(Server, F) of
    {atomic, Res} -> replace_nulls(Res);
    {aborted, _Reason} -> {error, db_failure}
  end.

get_user_info_t(User, Group) ->
  ejabberd_sql:sql_query_t(?SQL(
    "select @(username)s, @(id)s, @(subscription)s, @(badge)s,
     CASE
      WHEN TRIM(nickname) != '' and nickname is not null
        THEN nickname
      ELSE auto_nickname
     END as @(r_nickname)s,
    to_char(last_seen, 'YYYY-MM-DDThh24:mi:ssZ') as @(last)s
    from groupchat_users where
    username = %(User)s and chatgroup = %(Group)s"
  )).

get_user_role_t(User, Group) ->
  TS = now_to_timestamp(now()),
  Rights =  case ejabberd_sql:sql_query_t(
    ?SQL("select @(right_name)s,@(type)s from groupchat_policy "
    " left join groupchat_rights on groupchat_rights.name = right_name "
    " where username=%(User)s and chatgroup=%(Group)s "
    " and (valid_until = 0 or valid_until > %(TS)d )")) of
              {selected, Res} -> Res;
              _ -> []
            end,
  case lists:keyfind(<<"owner">>, 1, Rights) of
    false ->
      case lists:keyfind(<<"permission">>, 2, Rights) of
        false -> <<"member">>;
        _ -> <<"admin">>
      end;
    _ -> <<"owner">>
  end.


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

check_if_exist(Server,Chat,User) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(subscription)s
         from groupchat_users where chatgroup=%(Chat)s
              and username=%(User)s and subscription='both'")) of
    {selected,[{_Subscription}]} ->
      true;
    _ ->
      false
  end.

is_in_chat(Server,Chat,User) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(subscription)s
         from groupchat_users where chatgroup=%(Chat)s
              and username=%(User)s and (subscription='both' or subscription='wait')")) of
    {selected,[{_Subscription}]} ->
      true;
    _ ->
      false
  end.

check_if_exist_by_id(Server,Chat,ID) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(subscription)s
         from groupchat_users where chatgroup=%(Chat)s
              and id=%(ID)s and subscription='both'")) of
    {selected,[{_Subscription}]} ->
      true;
    _ ->
      false
  end.

update_user_status(Server,User,Chat) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set user_updated_at = (now() at time zone 'utc')
    where chatgroup=%(Chat)s and username=%(User)s")).

update_last_seen(Server,User,Chat) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set last_seen = (now() at time zone 'utc')
  where chatgroup=%(Chat)s and username=%(User)s")).

sql_update_nickname_badge(LServer, User, Group, Nickname, Badge) ->
  PureUser = <<$',(ejabberd_sql:escape(User))/binary,$'>>,
  PureGroup = <<$',(ejabberd_sql:escape(Group))/binary,$'>>,
  NicknameSet = case Nickname of
                  undefined -> <<>>;
                  _ ->
                    VN = ejabberd_sql:escape(str:strip(Nickname)),
                    <<",nickname = '",VN/binary,"'">>
                end,
  BadgeSet = case Badge of
               undefined -> <<>>;
               _ ->
                 VB = ejabberd_sql:escape(str:strip(Badge)),
                 <<",badge = '",VB/binary,"'">>
                end,
  ejabberd_sql:sql_query(LServer,
    [<<"update groupchat_users set user_updated_at=(now() at time zone 'utc')">>,
      NicknameSet, BadgeSet, <<" where chatgroup=">>,PureGroup,
      <<" and username=">>,PureUser,<<";">>]).

make_incognito_nickname(LServer, User, Group, UserID)->
  RandomNick =
    case mod_nick_avatar:random_nick_and_avatar(LServer) of
      {Nick,{_FileName, Bin}} ->
        %% todo: make a function for this in vcard module
        case mod_groups_vcard:store_user_avatar_file(LServer, Bin, UserID) of
          #avatar_info{bytes = Size, id = ID, type = Type, url = Url} ->
            mod_groups_vcard:update_avatar(LServer, User, Group, ID, Type, Size, Url);
          _ -> ok
        end,
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

sql_update_auto_nickname_t(User, Chat, Nick) ->
  ejabberd_sql:sql_query_t(
    ?SQL("update groupchat_users set auto_nickname=%(Nick)s "
    " where username=%(User)s and chatgroup=%(Chat)s")).

get_user_id(LServer, User, Chat) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(id)s from groupchat_users "
    " where chatgroup=%(Chat)s and username=%(User)s")) of
    {selected,[{UserID}]} ->
      UserID;
    _ ->
      <<>>
  end.

get_user_by_id_t(Chat,Id) ->
  case ejabberd_sql:sql_query_t(
    ?SQL("select @(username)s from groupchat_users "
    " where chatgroup=%(Chat)s and id=%(Id)s")) of
    {selected,[{User}]} -> User;
    _ -> none
  end.

get_user_by_id(Server,Chat,Id) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_users "
    " where chatgroup=%(Chat)s and id=%(Id)s")) of
    {selected,[{User}]} ->
      User;
    _ ->
      none
  end.

get_existed_user_by_id(Server,Chat,Id) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_users "
    " where chatgroup=%(Chat)s and id=%(Id)s and subscription='both'")) of
    {selected,[{User}]} ->
      User;
    _ ->
      false
  end.

get_user_by_id_and_allow_to_invite(Server,Chat,Id) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_users "
    " where chatgroup=%(Chat)s and id=%(Id)s and p2p_state ='true' ")) of
    {selected,[{User}]} ->
      User;
    _ ->
      none
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
  case get_user_info(Server, User, Chat) of
    [Username, UserId, _Subs, Badge, Nick, _Last, Role] ->
      IsAnon = mod_groups_chats:is_anonim(Server,Chat),
      UserJID = jid:from_string(User),
      AvatarEl = mod_groups_vcard:get_photo_meta(Server,Username,Chat),
      {Role, UserJID, Badge, UserId, Nick, AvatarEl, IsAnon};
    _ ->
      error
  end.

validate_data(_Acc, _LServer,_Chat,_Admin,_ID,undefined, undefined,_Lang) ->
  {stop, {error, xmpp:err_bad_request()}};
validate_data(_Acc, LServer,Chat,Admin,ID,_Nickname,_Badge,_Lang) ->
  User = case ID of
           <<>> ->
             Admin;
           _ ->
             get_existed_user_by_id(LServer,Chat,ID)
         end,
  check_user(User).

check_user(false) ->
  {stop, {error,xmpp:err_item_not_found()}};
check_user(User) when is_binary(User) ->
  User.

validate_rights(Admin,LServer,Chat,Admin,_ID,Nickname,undefined,Lang) ->
  validate_unique(LServer,Chat,Admin,Nickname,undefined,Lang);
validate_rights(Admin, LServer,Chat,Admin,_ID,undefined,Badge,Lang) ->
  SetNick = mod_groups_restrictions:is_permitted(<<"change-users">>,Admin,Chat),
  case SetNick of
    true ->
      validate_unique(LServer,Chat,Admin,undefined,Badge,Lang);
    _ ->
      Message = <<"You have no rights to change a badge">>,
      {stop, {error, xmpp:err_not_allowed(Message, Lang)}}
  end;
validate_rights(Admin, LServer,Chat,Admin,_ID,Nickname,Badge,Lang) ->
  SetNick = mod_groups_restrictions:is_permitted(<<"change-users">>,Admin,Chat),
  case SetNick of
    true ->
      validate_unique(LServer,Chat,Admin,Nickname,Badge,Lang);
    _ ->
      Message = <<"You have no rights to change a badge">>,
      {stop, {error, xmpp:err_not_allowed(Message, Lang)}}
  end;
validate_rights(User, LServer,Chat,Admin,_ID,Nickname,undefined,Lang) when Nickname =/= undefined ->
  SetNick = mod_groups_restrictions:is_permitted(<<"change-users">>,Admin,Chat),
  IsValid = mod_groups_restrictions:validate_users(LServer,Chat,Admin,User),
  case SetNick of
    true when IsValid == ok ->
      validate_unique(LServer,Chat,User,Nickname,undefined,Lang);
    _ ->
      Message = <<"You have no rights to change a nickname">>,
      {stop, {error, xmpp:err_not_allowed(Message, Lang)}}
  end;
validate_rights(User, LServer,Chat,Admin,_ID,undefined,Badge,Lang) when Badge =/= undefined ->
  SetBadge = mod_groups_restrictions:is_permitted(<<"change-users">>,Admin,Chat),
  IsValid = mod_groups_restrictions:validate_users(LServer,Chat,Admin,User),
  case SetBadge of
    true when IsValid == ok ->
      validate_unique(LServer,Chat,User,undefined,Badge,Lang);
    _ ->
      Message = <<"You have no rights to change a badge">>,
      {stop, {error, xmpp:err_not_allowed(Message, Lang)}}
  end;
validate_rights(User, LServer,Chat,Admin,_ID,Nickname,Badge,Lang) when Badge =/= undefined andalso Nickname =/= undefined ->
  SetBadge = mod_groups_restrictions:is_permitted(<<"change-users">>,Admin,Chat),
  IsValid = mod_groups_restrictions:validate_users(LServer,Chat,Admin,User),
  case SetBadge of
    true when IsValid == ok ->
      validate_unique(LServer,Chat,User,Nickname,Badge,Lang);
    _ ->
      Message = <<"You have no rights to change a nickname and a badge">>,
      {stop, {error, xmpp:err_not_allowed(Message, Lang)}}
  end.

sql_validate_unique(LServer, Group, User, NewNick, NewBadge) ->
  Current = fun()->
    case ejabberd_sql:sql_query_t(?SQL("select
     CASE
      WHEN TRIM(nickname) != '' and nickname is not null
        THEN nickname
      ELSE auto_nickname
     END as @(r_nickname)s, @(badge)s from groupchat_users
     where chatgroup=%(Group)s and username=%(User)s")) of
      {selected,[V]} -> V;
      _ ->
        error
    end end,
  CheckNew  = fun(Nick, Badge) ->
    case ejabberd_sql:sql_query_t(?SQL("select @(username)s
     from groupchat_users where chatgroup=%(Group)s
      and (nickname=%(Nick)s or auto_nickname=%(Nick)s)
      and badge=%(Badge)s")) of
      {selected,[]} -> ok;
      _ ->
        error
    end end,
  FN = fun() ->
    case Current() of
      {NewNick, NewBadge} ->
        error;
      {CurNick, CurBadge} ->
        Nick = set_value(NewNick, CurNick),
        Badge = set_value(NewBadge, CurBadge),
        CheckNew(Nick, Badge);
      _->
        error
    end end,
  case ejabberd_sql:sql_transaction(LServer, FN) of
    {atomic, Res} -> Res;
    {aborted, _Reason} -> error
  end.

validate_unique(LServer, Group, User, NickRaw, BadgeRaw, Lang) ->
  NewNick = set_value(NickRaw, <<>>),
  NewBadge = set_value(BadgeRaw, <<>>),
  case sql_validate_unique(LServer, Group,
    User, NewNick, NewBadge) of
    ok -> User;
    _ ->
      Message = <<"Duplicated combination
       of nickname and badge is not allowed">>,
      {stop, {error, xmpp:err_not_allowed(Message, Lang)}}
  end.

update_user(User, LServer,Chat, _Admin,_ID,Nickname,Badge,_Lang) ->
  UserCard = form_user_card(User,Chat),
  sql_update_nickname_badge(LServer, User, Chat, Nickname, Badge),
  {User,UserCard}.

%% for backward compatibility
user_no_read(_Server,_Chat) ->
  {selected, []}.

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

get_user_info_for_peer_to_peer(LServer,User,Chat) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(avatar_id)s,@(avatar_type)s,@(avatar_url)s,@(avatar_size)d,
    CASE
      WHEN nickname != '' and nickname is not null
        THEN groupchat_users.nickname
      ELSE groupchat_users.auto_nickname
    END AS @(r_nickname)s,
    @(parse_avatar)s, @(badge)s from groupchat_users
     where chatgroup=%(Chat)s and username=%(User)s")) of
    {selected,[]} ->
      not_exist;
    {selected,[Info]} ->
      Info
  end.

add_user_to_peer_to_peer_chat(LServer,User,Chat,
    {AvatarID,AvatarType,AvatarUrl,AvatarSize,
      Nickname,ParseAvatar,Badge}) ->
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
        "auto_nickname=%(Id)s",
        "parse_avatar=%(ParseAvatar)s",
        "badge=%(Badge)s"
      ])).

change_peer_to_peer_invitation_state(LServer, User, Chat, State)
  when State == <<"true">> orelse State == <<"false">> ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update groupchat_users set p2p_state = %(State)s where "
    " username = %(User)s and chatgroup = %(Chat)s and 'incognito' ="
    " (select anonymous from groupchats where jid = %(Chat)s and %(LServer)H)"
    )),
    ok;
change_peer_to_peer_invitation_state(_, _, _, _) -> ok.

%% user rights change functions
user_rights(LServer,Chat,User) ->
  TS = now_to_timestamp(now()),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(right_name)s from groupchat_policy where username=%(User)s
    and chatgroup=%(Chat)s and (valid_until = 0 or valid_until > %(TS)d )")) of
    {selected,Rights} ->
      Rights;
    _ ->
      []
  end.

user_rights_and_time(LServer,Chat,User) ->
  TS = now_to_timestamp(now()),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(groupchat_policy.right_name)s,@(groupchat_rights.type)s,
    @(groupchat_policy.valid_until)d
    from groupchat_policy left join groupchat_rights on groupchat_rights.name = groupchat_policy.right_name where username=%(User)s
    and chatgroup=%(Chat)s and (valid_until = 0 or valid_until > %(TS)d ) ")) of
    {selected,Rights} ->
      Rights;
    _ ->
      []
  end.

create_right_form(LServer,User,Chat,RequestUser,ID, Lang) ->
  UserRights = user_rights(LServer,Chat,User),
  IsOwner = lists:member({<<"owner">>},UserRights),
  CanRestrictUsers = lists:member({<<"set-restrictions">>},UserRights),
  ?INFO_MSG("User ~p~nIs owner ~p~nCan restrict ~p~n",[User,IsOwner,CanRestrictUsers]),
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
  AllRights = mod_groups_restrictions:get_all_rights(LServer),
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
  PermissionSection = [#xdata_field{var= <<"permission">>, type = 'fixed', values = [<<"Permissions">>]}],
  RestrictionSection = [#xdata_field{var= <<"restriction">>, type = 'fixed', values = [<<"Restrictions">>]}],
  PermissionSection ++ PermissionsFields ++ RestrictionSection ++ RestrictionsFields.

make_fields_owner_no_options(LServer,RightsAndTime,Lang,Type) ->
  AllRights = mod_groups_restrictions:get_all_rights(LServer),
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
  PermissionSection = [#xdata_field{var= <<"permission">>, type = 'fixed', values = [<<"Permissions">>]}],
  RestrictionSection = [#xdata_field{var= <<"restriction">>, type = 'fixed', values = [<<"Restrictions">>]}],
  PermissionSection ++ PermissionsFields ++ RestrictionSection ++ RestrictionsFields.

make_fields_admin(LServer,RightsAndTime,Lang) ->
  AllRights = mod_groups_restrictions:get_all_rights(LServer),
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
  RestrictionSection = [#xdata_field{var= <<"restriction">>, type = 'fixed', values = [<<"Restrictions">>]}],
  RestrictionSection ++ RestrictionsFields.

make_fields_admin_no_options(LServer,RightsAndTime,Lang) ->
  AllRights = mod_groups_restrictions:get_all_rights(LServer),
  ExistingRights = [{UR,ExTime}|| {UR,_UT,ExTime} <- RightsAndTime],
  ?INFO_MSG("Rights ~p~n",[ExistingRights]),
  Restrictions = [{R,D}||{R,T,D} <- AllRights, T == <<"restriction">>],
  RestrictionsFields = lists:map(fun(Right) ->
    {Name,Desc} = Right,
    Values = get_time(Name,ExistingRights),
    #xdata_field{var = Name, label = translate:translate(Lang,Desc), type = 'list-single',
      values = Values
    }
                                 end, Restrictions
  ),
  RestrictionSection = [#xdata_field{var= <<"restriction">>, type = 'fixed', values = [<<"Restrictions">>]}],
  RestrictionSection ++ RestrictionsFields.

get_time(Right,RightsList) ->
  case lists:keyfind(Right,1,RightsList) of
    {Right,Time} ->
      [integer_to_binary(Time)];
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
    #xdata_option{label = <<"5 minutes">>, value = [<<"300">>]},
    #xdata_option{label = <<"10 minutes">>, value = [<<"600">>]},
    #xdata_option{label = <<"15 minutes">>, value = [<<"900">>]},
    #xdata_option{label = <<"30 minutes">>, value = [<<"1800">>]},
    #xdata_option{label = <<"1 hour">>, value = [<<"3600">>]},
    #xdata_option{label = <<"1 week">>, value = [<<"604800">>]},
    #xdata_option{label = <<"1 month">>, value = [<<"2592000">>]},
    #xdata_option{label = <<"Forever">>, value = [<<"0">>]}
  ].

%%convert_time(Time) ->
%%  TimeNow = calendar:datetime_to_gregorian_seconds(calendar:universal_time()) - 62167219200,
%%  UnixTime = convert_from_datetime_to_unix_time(Time),
%%  Diff = UnixTime - TimeNow,
%%  case Diff of
%%    _ when Diff < 3153600000 ->
%%      integer_to_binary(UnixTime);
%%    _ ->
%%      <<"0">>
%%  end.

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
  AllRights = mod_groups_restrictions:get_all_rights(LServer),
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
  [<<"0">>,<<"300">>,<<"600">>,<<"900">>,<<"1800">>,<<"3600">>,<<"604800">>,<<"2592000">>].

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
    mod_groups_restrictions:set_rule(LServer,Rule,Expires,RequestUser,Chat,Admin)
                end, Rights).

set_expires([]) ->
  <<>>;
set_expires([<<"0">>]) ->
  <<"0">>;
set_expires(ExpireOption) ->
  ExpireInteger = binary_to_integer(list_to_binary(ExpireOption)),
  TS = now_to_timestamp(now()),
  Sum = TS + ExpireInteger,
  integer_to_binary(Sum).

current_values(LServer,User,Chat) ->
  AllRights = mod_groups_restrictions:get_all_rights(LServer),
  RightsAndTime = user_rights_and_time(LServer,Chat,User),
  lists:map(fun(El) ->
    {Name,Type,_Desc} = El,
    case lists:keyfind(Name,1,RightsAndTime) of
      {Name,Type,ExTime} ->
        {Name,Type,[integer_to_binary(ExTime)]};
      _ ->
        {Name,Type,[]}
    end
            end, AllRights).

% New methods for user list

get_user_from_chat(LServer, Chat, User, ID) ->
  {User1, ID1} = if
                   ID == <<>> orelse ID == <<"0">> -> {User, undefined};
                   true -> {undefined, ID}
                 end,
  case get_user_info(LServer, Chat, User1, ID1) of
    [Username, Id, Subscription, Badge, Nick, LastSeen, Role] ->
      IsAnon = mod_groups_chats:is_anonim(LServer,Chat),
      AvatarEl = mod_groups_vcard:get_photo_meta(LServer,Username,Chat),
      Present = case mod_groups_presence:select_sessions(Username,Chat) of
                  [] -> LastSeen;
                  _ -> undefined
                end,
      UserCard = #xabbergroupchat_user_card{subscription = Subscription, id = Id, nickname = Nick,
        role = Role, avatar = AvatarEl, badge = Badge, present = Present},
      RequesterRole = calculate_role(LServer,User,Chat),
      SubEls = if
                 IsAnon andalso RequesterRole /= <<"owner">> -> [UserCard] ;
                 true -> [UserCard#xabbergroupchat_user_card{jid = jid:from_string(Username)}]
               end,
      #xabbergroupchat{xmlns = ?NS_GROUPCHAT_MEMBERS, sub_els = SubEls};
    _ ->
      []
  end.

get_users_from_chat(LServer,Chat,RequesterUser,RSM,Version) ->
  {QueryChats, QueryCount} = make_sql_query(Chat,RSM,Version),
  {selected, _, Res} = ejabberd_sql:sql_query(LServer, QueryChats),
  {selected, _, [[CountBinary]]} = ejabberd_sql:sql_query(LServer, QueryCount),
  Users = make_query(LServer,Res,RequesterUser,Chat),
  Count = binary_to_integer(CountBinary),
  SubEls = case Users of
             [_|_] when RSM /= undefined ->
               #xabbergroupchat_user_card{nickname = First} = hd(Users),
               #xabbergroupchat_user_card{nickname = Last} = lists:last(Users),
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
  SubsClause =
    case Version of
      0 ->
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
    case Version of
      I when is_integer(I) ->
        Date = convert_from_unix_time_to_datetime(Version),
        [<<" AND (user_updated_at > ">>,
          <<"'">>, Date, <<"' OR last_seen > ">>,
          <<"'">>, Date, <<"')">>];
      _ ->
        []
    end,

  Users = [<<"WITH group_members AS (SELECT username, id, badge,
  to_char(last_seen,'YYYY-MM-DDThh24:mi:ssZ') as last,
  subscription,
  CASE
  WHEN nickname != '' and nickname is not null
   THEN groupchat_users.nickname
  ELSE groupchat_users.auto_nickname
  END AS r_nickname
  FROM groupchat_users  WHERE chatgroup = '">>,Chat, <<"'">>, VersionClause, SubsClause,<<")
  SELECT username, id, badge, last, subscription, r_nickname
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

  Query = [Users,PageClause],
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

make_query(LServer,RawData,RequesterUser,Chat) ->
  IsAnon = mod_groups_chats:is_anonim(LServer,Chat),
  RequesterUserRole = calculate_role(LServer,RequesterUser,Chat),
  lists:map(
    fun(UserInfo) ->
      [Username, Id, Badge, LastSeen, Subs, Nick] = UserInfo,
      Role = calculate_role(LServer,Username,Chat),
      AvatarEl = mod_groups_vcard:get_photo_meta(LServer,Username,Chat),
      S = mod_groups_presence:select_sessions(Username,Chat),
      L = length(S),
      Present = case L of
                     0 ->
                       LastSeen;
                     _ ->
                       undefined
                   end,
      Card = #xabbergroupchat_user_card{id = Id, nickname = Nick,
        role = Role, avatar = AvatarEl, badge = Badge, present = Present,
        subscription = Subs},
      WithoutJID = IsAnon andalso RequesterUser /= Username andalso
        RequesterUserRole /= <<"owner">>,
      if
        WithoutJID -> Card;
        true -> Card#xabbergroupchat_user_card{jid = jid:from_string(Username)}
      end
    end, RawData).

calculate_role(LServer,Username,Chat) ->
  TS = now_to_timestamp(now()),
  Rights =  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(right_name)s,@(type)s from groupchat_policy left join groupchat_rights on groupchat_rights.name = right_name where username=%(Username)s
     and chatgroup=%(Chat)s and (valid_until = 0 or valid_until > %(TS)d )")) of
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

%% Participants for notification of group deletion
get_all_participants(LServer,Chat) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(username)s from groupchat_users "
    " where chatgroup=%(Chat)s and subscription != 'none'")) of
    {selected,Users} -> [jid:from_string(User) || {User} <- Users];
    _ -> []
  end.

now_to_timestamp({MSec, Sec, _USec}) ->
  (MSec * 1000000 + Sec).

replace_nulls(List) when is_list(List) ->
  lists:map(fun(null) -> <<>>;
               (V) -> V
            end, List);
replace_nulls(Data) -> Data.


-spec set_value(binary() | atom(), any()) -> any().
set_value(Val, Default) ->
  NoneValues = [undefined, null, <<>>, <<"">>],
  case lists:member(Val, NoneValues) of
    true -> Default;
    _ when is_binary(Val) -> str:strip(Val);
    _ -> Val
  end.