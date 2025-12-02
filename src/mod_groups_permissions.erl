%%%-------------------------------------------------------------------
%%% File    : mod_groups_permissions.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : Manage permissions in group chats
%%% Created : 06 Oct 2025 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
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

-module(mod_groups_permissions).
-author('ilya.kalashnikov@redsolution.com').
-behaviour(gen_mod).
-compile([{parse_transform, ejabberd_sql_pt}]).

-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").

%% gen_mod
-export([start/2, stop/1, mod_options/1, depends/2, reload/3, mod_opt_type/1]).

%% Hooks
-export([copy_newbies_perms/2, user_left/2, kick_users/3, add_owner/4,
  group_removed/2, is_permitted/4]).

%% API

-export([process_iq/2]).
-export([
  remove_expired_perms/5,
  is_manager/3,
  validate_users/4,
  fast_is_permitted/3,
  is_permitted/3
 ]).

-record(fast_group_perms, {
  gup = {<<>>,<<>>,<<>>} :: {binary(),binary(),binary()},
  status =  false        :: boolean(),
  expires = undefined    :: 'undefined' | non_neg_integer()
}).

%% gen_mod
start(Host, _Opts) ->
  init_fast_perms(Host),
  register_hooks(Host),
  ok.

stop(Host) ->
  unregister_hooks(Host),
  ok.

reload(_Host, _NewOpts, _OldOpts) ->
  ok.

depends(_Host, _Opts) ->
  [].

mod_options(_Host) ->
  [].

mod_opt_type(_) ->
  fun (L) -> lists:map(fun iolist_to_binary/1, L) end.



%% IQ handlers
process_iq(_Acc, #iq{sub_els = [#perms_permissions{}]} = Iq) ->
  make_result(process_iq_personal(Iq));
process_iq(_Acc, #iq{ sub_els = [#perms_defaults{}]} = Iq) ->
  make_result(process_iq_default(Iq));
process_iq(_Acc, #iq{sub_els = [#perms_newbies{}]} = Iq) ->
  make_result(process_iq_newbies(Iq));
process_iq(_Acc, #iq{sub_els = [#perms_delete{sub_els = SunEls}]} = Iq) ->
  Target = case SunEls of
             [#perms_permissions{target = <<>>}] -> undefined;
             [#perms_permissions{target = UserID}] -> UserID;
             [#perms_defaults{}]-> defaults;
             [#perms_newbies{}]-> newbies;
             _ -> undefined
  end,
  make_result(perms_delete(Iq#iq.to, Iq#iq.from, Target));
process_iq(_Acc, _Iq) ->
  {stop, {error, xmpp:err_feature_not_implemented()}}.

%% Hooks

register_hooks(Host) ->
  ejabberd_hooks:add(groups_is_permitted, Host, ?MODULE, is_permitted, 10),
  ejabberd_hooks:add(groups_group_removed, Host, ?MODULE, group_removed, 80),
  ejabberd_hooks:add(groups_permissions_query, Host, ?MODULE, process_iq, 10),
  ejabberd_hooks:add(groups_add_owner, Host, ?MODULE, add_owner, 50),
  ejabberd_hooks:add(groupchat_users_kicked, Host, ?MODULE, kick_users, 80),
  ejabberd_hooks:add(groupchat_presence_unsubscribed_hook, Host, ?MODULE, user_left, 30),
  ejabberd_hooks:add(groupchat_presence_subscribed_hook, Host, ?MODULE, copy_newbies_perms, 40).

unregister_hooks(Host) ->
  ejabberd_hooks:delete(groups_is_permited, Host, ?MODULE, is_permitted, 10),
  ejabberd_hooks:delete(groups_group_removed, Host, ?MODULE, group_removed, 80),
  ejabberd_hooks:delete(groups_permissions_query, Host, ?MODULE, process_iq, 10),
  ejabberd_hooks:delete(groups_add_owner, Host, ?MODULE, add_owner, 50),
  ejabberd_hooks:delete(groupchat_users_kicked, Host, ?MODULE, kick_users, 80),
  ejabberd_hooks:delete(groupchat_presence_unsubscribed_hook, Host, ?MODULE, user_left, 30),
  ejabberd_hooks:delete(groupchat_presence_subscribed_hook, Host, ?MODULE, copy_newbies_perms, 40).

add_owner(Server, Group, Requester, Member) ->
  Perm = lists:keyfind(<<"owner">>, #perms_permission.name, defaults()),
  Perms = [Perm#perms_permission{status = true}],
  add_personal_perms(Server, Group, Requester, Member, Perms).

copy_newbies_perms(Acc, {Server, UserJID, Group, _Lang}) ->
  User = jid:to_string(jid:remove_resource(UserJID)),
  case mod_groups_users:is_owner(Server, Group, User) of
    true -> ok;
    _ ->
      Perms = newbies_perms(Server, Group),
      add_personal_perms(Server, Group, <<"newbies">>, User, Perms)
  end,
  Acc.

user_left(Acc,{Server, User, Group, _X, _Lang})->
  delete_admin_perms(Server, Group, User),
  Acc.

kick_users(Server, Group, Users)->
  lists:foreach(fun(User) ->
    delete_admin_perms(Server, Group, User)
                end, Users).

group_removed(Server, Group) ->
  delete_default_perms(Server, Group),
  delete_newbies_perms(Server, Group),
  delete_perms(Server, Group).

is_permitted(_, {send_message, Msg}, Group, User)->
  case fast_is_permitted(<<"send-messages">>, User, Group) of
    false -> false;
    _ ->
      check_payload(User, Group, Msg)
  end;
is_permitted(_, change_user_info, Group, User)->
  is_permitted(<<"change-user-info">>, User, Group);
is_permitted(_, delete_messages, Group, User)->
  is_permitted(<<"delete-messages">>, User, Group);
is_permitted(_, add_members, Group, User)->
  is_permitted(<<"add-members">>, User, Group);
is_permitted(_, kick_user, Group, User)->
  is_permitted(<<"block-users">>, User, Group);
is_permitted(_, block_user, Group, User)->
  is_permitted(<<"block-users">>, User, Group);
is_permitted(_,change_group_settings, Group, User)->
  is_permitted(<<"change-group-settings">>, User, Group);
is_permitted(_,change_group_info, Group, User)->
  is_permitted(<<"change-group-info">>, User, Group);
is_permitted(Acc, _Action, _Group, _User)->
  Acc.

%% API

is_manager(Server, Group, Member) ->
  {Perms, _} = personal_perms(Server, Group, Member),
  P1 = filter_by_level(Perms, [<<"admin">>, <<"owner">>]),
  case [P || P <- P1, P#perms_permission.status] of
    [] -> false;
    _ -> true
  end.

validate_users(Server, Group, Admin, User) ->
  {Perms, {Actor, _, _}} = personal_perms(Server, Group, User),
  IsOwner = is_owner(Perms),
  IsAdmin = is_admin(Perms),
  if
    IsOwner -> false;
    IsAdmin andalso Admin /= Actor -> false;
    true -> true
  end.

get_permissions(Server, Group, Member) ->
  GroupDefaults = group_perms(Server, Group),
  {Personal, _} = personal_perms(Server, Group, Member),
  {_Role, Perms } = calculate_perms(GroupDefaults, Personal),
  Perms.

fast_is_permitted(<<"send-messages">>, User, Group)->
  fast_is_permitted(member, <<"send-messages">>, User, Group);
fast_is_permitted(<<"send-media">>, User, Group)->
  fast_is_permitted(member, <<"send-media">>, User, Group);
fast_is_permitted(Action, User, Group)->
  is_permitted(Action, User, Group).

fast_is_permitted(member, PermName, User, Group)->
  case mnesia:dirty_read(fast_group_perms, {Group, User, PermName}) of
    [FP] ->
      Now = erlang:system_time(second),
      Expires = FP#fast_group_perms.expires,
      if
        Now < Expires ->
          FP#fast_group_perms.status;
        true ->
          mnesia:dirty_delete_object(FP),
          fast_is_permitted(group, PermName, User, Group)
      end;
    [] ->
      fast_is_permitted(group, PermName, User, Group);
    Err ->
      ?ERROR_MSG("Group: ~p; User: ~p; Err: ~p",[Group, User, Err]),
      is_permitted(PermName, User, Group)
  end;
fast_is_permitted(group, PermName, User, Group)->
  case mnesia:dirty_read(fast_group_perms, {Group, Group, PermName}) of
    [FP] ->
      {_, Server, _} = jid:tolower(jid:from_string(Group)),
      case is_manager(Server, Group, User) of
        true -> true;
        _ -> FP#fast_group_perms.status
      end;
    [] ->
      is_permitted(PermName, defaults());
    Err ->
      ?ERROR_MSG("Group: ~p; User: ~p; Err: ~p",[Group, User, Err]),
      is_permitted(PermName, User, Group)
  end.

is_permitted(Permission, User, Group)->
  {_, Server, _} = jid:tolower(jid:from_string(Group)),
  UserPerms = get_permissions(Server, Group, User),
  is_permitted(<<"owner">>, UserPerms) orelse
    is_permitted(Permission, UserPerms).


%% Internal

defaults() ->
  [
    #perms_permission{name = <<"send-messages">>, display = <<"Send messages">>,
      level = <<"member">>, status = true},
    #perms_permission{name = <<"send-media">>, display = <<"Send media">>,
      level = <<"member">>, status = true},
    #perms_permission{name = <<"add-members">>, display = <<"Add members">>,
      level = <<"member">>, status = true},
    #perms_permission{name = <<"pin-messages">>, display = <<"Pin messages">>,
      level = <<"member">>, status = false},
    #perms_permission{name = <<"change-group-info">>, display = <<"Change group info">>,
      level = <<"member">>, status = false},
    #perms_permission{name = <<"owner">>, display = <<"Owner">>,
      level = <<"owner">>, status = false},
    #perms_permission{name = <<"change-group-settings">>, display = <<"Edit group settings">>,
      level = <<"admin">>, status = false},
    #perms_permission{name = <<"change-user-info">>, display = <<"Edit users' info">>,
      level = <<"admin">>, status = false},
    #perms_permission{name = <<"delete-messages">>, display = <<"Delete messages">>,
      level = <<"admin">>, status = false},
    #perms_permission{name = <<"change-permissions">>, display = <<"Change users' permissions">>,
      level = <<"admin">>, status = false},
    #perms_permission{name = <<"change-default-permissions">>, display = <<"Change default permissions">>,
      level = <<"admin">>, status = false},
    #perms_permission{name = <<"block-users">>, display = <<"Kick and block users">>,
      level = <<"admin">>, status = false},
    #perms_permission{name = <<"create-admins">>, display = <<"Create admins">>,
      level = <<"admin">>, status = false}
  ].
fast_permissions() ->
  [<<"send-messages">>, <<"send-media">>].

process_iq_personal(#iq{type = get, from = From, to = To,
  sub_els = [Perms]}) ->
  case Perms#perms_permissions.target of
    undefined -> get_members(From, To);
    <<>> -> {error, bad_request};
    UserId ->
      case get_perms_query(To, From, UserId) of
        #perms_permissions{} = P ->
          P#perms_permissions{target = UserId};
        Err ->
          Err
      end
  end;
process_iq_personal(#iq{type = set, from = From, to = To,
  sub_els = [PermsEl]}) ->
  case PermsEl#perms_permissions.target of
    undefined -> {error, bad_request};
    <<>> -> {error, bad_request};
    UserId ->
      Perms = validate_perms(PermsEl#perms_permissions.perms,
        [<<"admin">>, <<"member">>]),
      set_perms_query(To, From, UserId, Perms)
  end;
process_iq_personal(_) ->
  {error, bad_request}.

process_iq_default(#iq{type = get, from = From, to = To}) ->
  get_default_perms_query(To, From);
process_iq_default(#iq{type = set, from = From, to = To,
  sub_els = [#perms_defaults{perms = PermsEl}]} ) ->
  Perms =  validate_perms(PermsEl#perms_permissions.perms,
    [<<"member">>]),
  set_default_perms_query(To, From, Perms);
process_iq_default(_) ->
  {error, bad_request}.

process_iq_newbies(#iq{type = get, from = From, to = To}) ->
  get_newbies_perms_query(To, From);
process_iq_newbies(#iq{type = set, from = From, to = To,
  sub_els = [#perms_newbies{perms = PermsEl}]} ) ->
  Perms = validate_perms(PermsEl#perms_permissions.perms,
    [<<"member">>]),
  set_newbies_perms_query(To, From, Perms);
process_iq_newbies(_) ->
  {error, bad_request}.


get_default_perms_query(GroupJID, UserJID) ->
  Server = GroupJID#jid.lserver,
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  User = jid:to_string(jid:remove_resource(UserJID)),
  UserPerms = get_permissions(Server, Group, User),
  IsOwner = is_permitted(<<"owner">>, UserPerms),
  IsChangePerms = is_permitted(<<"change-default-permissions">>, UserPerms)
    orelse is_permitted(<<"change-permissions">>, UserPerms),
  if
    IsOwner; IsChangePerms ->
      GrPerms = calculate_default_perms(Server, Group),
      #perms_defaults{perms =
      #perms_permissions{perms = GrPerms}};
    true ->
      {error, not_allowed}
  end.

set_default_perms_query(_GroupJID, _UserJID, []) ->
  {error, bad_request};
set_default_perms_query(GroupJID, UserJID, Perms) ->
  Server = GroupJID#jid.lserver,
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  User = jid:to_string(jid:remove_resource(UserJID)),
  UserPerms = get_permissions(Server, Group, User),
  IsOwner = is_permitted(<<"owner">>, UserPerms),
  IsChangePerms =is_permitted(<<"change-default-permissions">>, UserPerms),
  IsAdminPerms = check_levels(Perms, [<<"admin">>,<<"owner">>]),
  if
    not IsAdminPerms andalso (IsOwner orelse IsChangePerms)->
      add_default_perms(Server, Group, Perms);
    true ->
      {error, not_allowed}
  end.

add_default_perms(_Server, _Group, []) ->
  ok;
add_default_perms(Server, Group, [Perm | Perms]) ->
  sql_add_default_perm(Server, Group,
    Perm#perms_permission.name, Perm#perms_permission.status),
  copy_to_fast_perms(Server,Group, Group, Perm),
  add_default_perms(Server, Group, Perms).

delete_default_perms(Server, Group) ->
  sql_delete_default_perms(Server, Group).

set_perms_query(_Group, _Requester, _UserId, [])->
  {error, bad_request};
set_perms_query(Group, Requester, UserId, Perms)->
  Server = Group#jid.lserver,
  GroupS = jid:to_string(jid:remove_resource(Group)),
  RequesterS = jid:to_string(jid:remove_resource(Requester)),
  case mod_groups_users:get_user_by_id(Server, GroupS, UserId) of
    none -> {error, not_found};
    RequesterS -> {error, not_allowed};
    Member ->
      set_perms_query(Server, GroupS, RequesterS, Member, Perms)
  end.

set_perms_query(Server, Group, Requester, Member, Perms) ->
  R = verify_users(Server, Group, Requester, Member),
  set_perms_query(R, Server, Group, Requester, Member, Perms).

set_perms_query({true, ReqOpts, MemberOpts}, Server, Group,
    Requester, Member, Perms) ->
  {RisOwner, CreateAdmins, ChangePerms} = ReqOpts,
  {_, MisAdmin} = MemberOpts,
  MPs = check_levels(Perms, [<<"member">>]),
  APs = check_levels(Perms, [<<"admin">>]),
  case is_allowed(RisOwner, CreateAdmins, ChangePerms,
    MisAdmin, MPs, APs) of
    true ->
      add_personal_perms(Server, Group, Requester, Member, Perms),
      update_user(Server, Group, Requester, Member, MemberOpts);
    false ->
      {error, not_allowed}
  end ;
set_perms_query(_, _, _, _, _, _) ->
  {error, not_allowed}.

add_personal_perms(Server, Group, IssuedBy, Member, Perms) ->
  GrPerms = calculate_default_perms(Server, Group),
  lists:foreach(fun(#perms_permission{name = Name,
    status = Status} = Perm) ->
    Expires = case Perm#perms_permission.seconds of
                undefined -> 0;
                0 -> 0;
                S -> erlang:system_time(second) + S
              end,
    case lists:keyfind(Name, #perms_permission.name, GrPerms) of
      #perms_permission{status = Status} ->
        sql_delete_perm(Server, Group, Member, Name);
      _->
        sql_add_perm(Server, Group, Member, Name,
          Perm#perms_permission.level, Status,
          Expires, IssuedBy)
    end,
    copy_to_fast_perms(Server, Group, Member,
      Perm#perms_permission{expires = Expires})
                end, Perms),
  ok.

get_perms_query(Group, Requester, UserId)->
  Server = Group#jid.lserver,
  GroupS = jid:to_string(jid:remove_resource(Group)),
  RequesterS = jid:to_string(jid:remove_resource(Requester)),
  case mod_groups_users:get_user_by_id(Server, GroupS, UserId) of
    none -> {error, not_found};
    Member ->
      get_perms_query(Server, GroupS, RequesterS, Member)
  end.

get_perms_query(Server, Group, Requester, Requester)->
  perms_query_result(my_perms, Server, Group, Requester);
get_perms_query(Server, Group, Requester, Member)->
  Privileges = check_requester(Server, Group, Requester),
  perms_query_result(Privileges, Server, Group, Member).

perms_delete(_GroupJID, _UserJID, undefined) ->
  {error, bad_request};
perms_delete(Group, Requester, UserId) when is_binary(UserId) ->
  Server = Group#jid.lserver,
  GroupS = jid:to_string(jid:remove_resource(Group)),
  RequesterS = jid:to_string(jid:remove_resource(Requester)),
  case mod_groups_users:get_user_by_id(Server, GroupS, UserId) of
    none -> {error, not_found};
    RequesterS -> {error, not_allowed};
    Member ->
      perms_delete(Server, GroupS, RequesterS, Member)
  end;
perms_delete(GroupJID, UserJID, PermsType) ->
  Server = GroupJID#jid.lserver,
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  User = jid:to_string(jid:remove_resource(UserJID)),
  UserPerms = get_permissions(Server, Group, User),
  IsOwner = is_permitted(<<"owner">>, UserPerms),
  IsChangePerms =is_permitted(<<"change-default-permissions">>, UserPerms),
  if
    IsOwner orelse IsChangePerms->
      case PermsType of
        defaults -> delete_default_perms(Server, Group);
        newbies -> delete_newbies_perms(Server, Group);
        _ -> ok
      end,
      ok;
    true ->
      {error, not_allowed}
  end.

perms_delete(Server, Group, Requester, Member) ->
  case verify_users(Server, Group, Requester, Member) of
    {true, _, _} ->
      sql_delete_perms(Server, Group, Member),
      ok;
    _ ->
      {error, not_allowed}
  end.

delete_member_perms(Server, Group, Member) ->
  lists:foreach(fun(N)->
    del_fast_perm(Group, Member,
      #perms_permission{name = N})
                end, fast_permissions()),
  sql_delete_member_perms(Server, Group, Member),
  ok.

delete_admin_perms(Server, Group, Member) ->
  sql_delete_admin_perms(Server, Group, Member),
  ok.

delete_perms(Server, Group) ->
  sql_delete_perms(Server, Group),
  ok.

get_newbies_perms_query(GroupJID, UserJID) ->
  Server = GroupJID#jid.lserver,
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  User = jid:to_string(jid:remove_resource(UserJID)),
  UserPerms = get_permissions(Server, Group, User),
  IsOwner = is_permitted(<<"owner">>, UserPerms),
  IsChangePerms =is_permitted(<<"change-default-permissions">>, UserPerms),
  if
    IsOwner; IsChangePerms ->
      Perms = newbies_perms(Server, Group),
      #perms_newbies{perms = #perms_permissions{perms = Perms}};
    true ->
      {error, not_allowed}
  end.

set_newbies_perms_query(GroupJID, UserJID, Perms) ->
  Server = GroupJID#jid.lserver,
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  User = jid:to_string(jid:remove_resource(UserJID)),
  UserPerms = get_permissions(Server, Group, User),
  IsOwner = is_permitted(<<"owner">>, UserPerms),
  IsChangePerms =is_permitted(<<"change-default-permissions">>, UserPerms),
  IsAdminPerms = check_levels(Perms, [<<"admin">>,<<"owner">>]),
  if
    not IsAdminPerms andalso (IsOwner orelse IsChangePerms)->
      delete_newbies_perms(Server, Group),
      add_newbies_perms(Server, Group, Perms);
    true ->
      {error, not_allowed}
  end.

add_newbies_perms(_Server, _Group, []) ->
  ok;
add_newbies_perms(Server, Group, [Perm | Perms]) ->
  sql_add_newbies_perm(Server, Group,
    Perm#perms_permission.name, Perm#perms_permission.status, Perm#perms_permission.seconds),
  add_newbies_perms(Server, Group, Perms).

get_members(UserJID, GroupJID) ->
  Server = GroupJID#jid.lserver,
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  User = jid:to_string(jid:remove_resource(UserJID)),
  Privileges = check_requester(Server, Group, User),
  case lists:member(true, tuple_to_list(Privileges)) of
    true ->
      List = sql_get_users(Server, Group),
      Sorted = lists:foldl(fun({ID, P, S, T, ITS, A}, Acc) ->
        case lists:keyfind(ID, 1, Acc) of
          false ->
            [{ID, [{P, S, T}], [{A, ITS}]} | Acc];
          {ID, Perms, Actors} ->
            Acc1 = Acc -- [{ID, Perms, Actors}],
            [{ID, [{P, S, T} | Perms], [{A, ITS} | Actors] } | Acc1]
        end
                           end, [], List),
      get_members(Server, Group, Privileges, Sorted);
    _ ->
     {error, not_allowed}
 end.

get_members(_Server, _Group, _Privileges, []) ->
  [];
get_members(Server, Group, Privileges, Perms) ->
  GroupDefaults = group_perms(Server, Group),
  lists:map(fun({ID, UserPerms, Actors}) ->
    Personal = to_records(UserPerms),
    {Role, Perms1} = calculate_perms(GroupDefaults, Personal),
    LockedLevels = case Privileges of
                     {true, _,_} -> [];
                     {_,true, true} -> [];
                     {_, true,_} -> [<<"member">>];
                     {_, _, true} -> [<<"admin">>]
                   end,
    {Actor, TS} =
      lists:foldl(fun({A, T}, {LA, LT}) ->
        if
          A == null -> {LA, LT};
          T > LT -> {A, T};
          true -> {LA, LT}
        end end, {undefined, 0}, Actors),
    El = perms_element(Role, Actor, Perms1, TS, LockedLevels),
    El#perms_permissions{target = ID}
            end, Perms).

check_requester(Server, Group, User) ->
  Perms = get_permissions(Server, Group, User),
  IsOwner = is_permitted(<<"owner">>, Perms),
  AllowCreateAdmins = is_permitted(<<"create-admins">>, Perms),
  AllowChangePerms = is_permitted(<<"change-permissions">>, Perms),
  {IsOwner, AllowCreateAdmins, AllowChangePerms}.


delete_newbies_perms(Server, Group) ->
  sql_delete_newbies_perms(Server, Group).

group_perms(Server, Group) ->
  Perms = sql_select_default_perms(Server, Group),
  to_records([{N, S, 0} || {N, S} <- Perms]).

personal_perms(Server, Group, Member) ->
  Rows = sql_select_perms(Server, Group, Member),
  Perms = [{P, S, T}||{P, S, T, _, _, _} <- Rows],
  Actors = [{T, A, AID, AT}|| {_, _, T, A, AID, AT} <- Rows],
  Now = erlang:system_time(second),
  {Actor, AID, ATS} =
    lists:foldl(fun({T, A, AID, AT}, {LA, LAID, LT}) ->
      if
        AID == null ->  {LA, LAID, LT};
        (T > Now orelse T ==0) andalso AT > LT ->
          {A, AID, AT};
        true -> {LA, LAID, LT}
      end end, {undefined, undefined, 0}, Actors),
  PermsR = to_records(Perms),
  Expired = [R || R <- PermsR, R#perms_permission.expires > 0,
    R#perms_permission.expires < Now ],
  ActivePerms = PermsR -- Expired,
  spawn(?MODULE, remove_expired_perms,
    [Server, Group, Member, ActivePerms, Expired]),
  {ActivePerms, {Actor, AID, ATS}}.


to_records(Perms) ->
  lists:filtermap(fun({Name, Status, Expires}) ->
    case lists:keyfind(Name, #perms_permission.name, defaults()) of
      false -> false;
      P when Expires == 0->
        {true, P#perms_permission{status = Status}};
      P ->
        {true, P#perms_permission{status = Status, expires = Expires}}
    end
            end, Perms).


copy_to_fast_perms(Server, Group, Member,
    #perms_permission{name = Name} = P) ->
  case lists:member(Name, fast_permissions()) of
    true ->
      copy_to_fast_perms1(Server, Group, Member, P);
    _ ->
      ok
  end.

copy_to_fast_perms1(_Server, Group, Group, P) ->
  Default = is_permitted(P#perms_permission.name, defaults()),
  case P#perms_permission.status of
    Default ->
      del_fast_perm(Group, Group, P);
    _ ->
      add_fast_perm(Group, Group, P)
  end;
copy_to_fast_perms1(Server, Group, Member, P) ->
  GroupPerms = calculate_default_perms(Server,Group),
  Default = is_permitted(P#perms_permission.name, GroupPerms),
  case P#perms_permission.status of
    Default ->
      del_fast_perm(Group, Member, P);
    _ ->
      add_fast_perm(Group, Member, P)
  end.

add_fast_perm(Group, Member, P) ->
  Expires = case P#perms_permission.expires of
              0 -> undefined;
              V -> V
            end,
  mnesia:dirty_write(#fast_group_perms{
    gup = {Group, Member, P#perms_permission.name},
    status = P#perms_permission.status,
    expires = Expires}).

del_fast_perm(Group, Member, P) ->
  mnesia:dirty_delete(fast_group_perms,
    {Group, Member, P#perms_permission.name}).

check_payload(User, Group, Msg) ->
  case fast_is_permitted(<<"send-media">>, User, Group) of
    false ->
      not check_media_files(all, Msg);
    _ -> true
  end.

check_media_files(all, Msg) ->
  Refs = lists:filtermap(fun(El) ->
    case {xmpp:get_name(El), xmpp:get_ns(El)} of
      {<<"reference">>, ?NS_REFERENCES} ->
        {true, xmpp:decode(El)};
      _ -> false
    end end, xmpp:get_els(Msg)),
  search_in_references(all, Refs);
check_media_files(_MediaType, _Msg) ->
  true.


search_in_references(all, References) ->
  Files = lists:filter(fun(Reference) ->
    case xmpp:get_subtag(Reference, #files_file_sharing{}) of
      #files_file_sharing{} -> true;
      _ ->
        false
    end end, References),
  Files /= [].

newbies_perms(Server, Group)->
  Values = sql_select_newbies_perms(Server, Group),
  lists:filtermap(
    fun(#perms_permission{name = Name} = P)->
      case lists:keyfind(Name, 1, Values) of
        {Name, Status, Secs} ->
          {true, P#perms_permission{status = Status, seconds = Secs}};
        _ ->
          false
      end
    end, defaults()).


calculate_default_perms(Server, Group) ->
  GroupPerms = group_perms(Server, Group),
  Perms = lists:map(
    fun(#perms_permission{name = Name} = P)->
      case lists:keyfind(Name,  #perms_permission.name, GroupPerms) of
        false -> P;
        Perm -> Perm
      end
    end, defaults()),
  filter_by_level(Perms, [<<"member">>]).


calculate_perms(Perms) ->
  Role = lists:foldl(
    fun(_, <<"owner">>) -> <<"owner">>;
      (#perms_permission{level = <<"admin">>, status = true}, _) -> <<"admin">>;
      (#perms_permission{level = <<"owner">>, status = true}, _) -> <<"owner">>;
      (_, Acc) -> Acc
    end, <<"member">>, Perms),
  Perms1 = lists:map(
    fun(P) when Role == <<"owner">> ->
        P#perms_permission{status = true, expires = undefined};
      (#perms_permission{level = <<"member">>} = P) when Role == <<"admin">> ->
        P#perms_permission{status = true, expires = undefined};
      (P) -> P
    end, Perms),
  {Role, Perms1}.


calculate_perms(GroupDefaults, Personal) ->
  Perms =lists:map(
    fun(#perms_permission{name = Name} = P)->
      case lists:keyfind(Name, #perms_permission.name, Personal) of
        false ->
          case lists:keyfind(Name, #perms_permission.name, GroupDefaults) of
            false -> P;
            Perm -> Perm
          end;
        Perm -> Perm
      end
    end, defaults()),
  calculate_perms(Perms).

member_info(Server, Group, Member) ->
  GroupDefaults = group_perms(Server, Group),
  {Personal, {_, Actor, TS}} =
    personal_perms(Server, Group, Member),
  {Role, Perms} = calculate_perms(GroupDefaults, Personal),
  {Role, Actor, Perms, TS}.

is_permitted(Perm, Perms) ->
  case lists:keyfind(Perm, #perms_permission.name, Perms) of
    #perms_permission{status = S} -> S;
    _ -> false
  end.

filter_by_level(Perms, Levels)->
  [P || P <- Perms, lists:member(P#perms_permission.level, Levels)].

check_levels(Perms, Levels) ->
  case filter_by_level(Perms, Levels) of
    [] -> false;
    _ -> true
  end.

lock_perms(Perms, Levels) ->
  lists:map(fun(P) ->
    case  lists:member(P#perms_permission.level, Levels) of
      true -> P#perms_permission{fixed = true};
      _ -> P
    end
            end, Perms).

is_owner(Perms) ->
  is_permitted(<<"owner">>, Perms).

is_admin(Perms) ->
  P1 = filter_by_level(Perms, [<<"admin">>]),
  case [P || P <- P1, P#perms_permission.status] of
    [] -> false;
    _ -> true
  end.

validate_perms(Perms, Levels) ->
  Perms1 = validate_perms(defaults(), Perms, []),
  filter_by_level(Perms1, Levels).

validate_perms(_Defaults, [], Acc) ->
  Acc;
validate_perms(Defaults,[Perm | Perms], Acc) ->
  #perms_permission{name = Name, status = Status, seconds = Secs} = Perm,
  case lists:keyfind(Name, #perms_permission.name, Defaults) of
    false -> validate_perms(Defaults, Perms, Acc);
    DP ->
      Acc1 = Acc ++ [DP#perms_permission{status = Status, seconds = Secs}],
      validate_perms(Defaults, Perms, Acc1)
  end.

verify_users(Server, Group, Requester, User) ->
  Perms = get_permissions(Server, Group, Requester),
  IsOwner = is_permitted(<<"owner">>, Perms),
  CreateAdmins = is_permitted(<<"create-admins">>, Perms),
  ChangePerms = is_permitted(<<"change-permissions">>, Perms),
  if
    IsOwner orelse CreateAdmins  orelse ChangePerms ->
      verify_users(Server, Group, Requester,
        {IsOwner, CreateAdmins, ChangePerms}, User);
    true -> false
  end.

verify_users(Server, Group, Requester, ReqOpts, User) ->
%%  Perms = get_permissions(Server, Group, User),
  {Perms, {Actor, _,_}} = personal_perms(Server, Group, User),
  UserIsOwner = is_permitted(<<"owner">>, Perms),
  UserIsAdmin = is_admin(Perms),
  UserOpts = {UserIsOwner, UserIsAdmin},
  {ReqIsOwner, _, _} = ReqOpts,
  if
    UserIsOwner -> false;
    ReqIsOwner -> {true, ReqOpts, UserOpts};
    UserIsAdmin andalso Requester /= Actor-> false;
    true -> {true, ReqOpts, UserOpts}
  end.

update_user(Server, Group, _IssuedBy, Member, {_, WasAdmin})->
  GroupDefaults = group_perms(Server, Group),
  {Personal, _} = personal_perms(Server, Group, Member),
  {Role, _Perms} = calculate_perms(GroupDefaults, Personal),
  if
    not WasAdmin andalso Role == <<"admin">> ->
      delete_member_perms(Server, Group, Member);
    WasAdmin andalso Role /= <<"admin">> ->
      delete_admin_perms(Server, Group, Member);
    true -> ok
  end,
  mod_groups_users:update_user_status(Server, Member, Group, Role),
  ok.

remove_expired_perms(_Server, _Group, _Member, _ActivePerms, []) -> ok;
remove_expired_perms(Server, Group, Member, ActivePerms, Expired) ->
  remove_expired_perms(Server, Group, Member),
  {RoleE, _} = calculate_perms([], Expired),
  {RoleA, _} = calculate_perms([], ActivePerms),
  case {RoleE, RoleA} of
    {<<"admin">>, <<"member">>} ->
      mod_groups_users:update_user_status(Server, Member, Group, RoleA);
    _ -> ok
  end.

remove_expired_perms(Server, Group, Member) ->
  sql_delete_expired_perms(Server, Group, Member).

%% RiO - Requester is Owner, RCA - Requester can Crete Admin, RCP - Requester can Change Perms,
%% MiA - Member is Admin, MPs - Perms for members, APs - Perms for admins
%%         _RiO,  _RCA, _RCP, _MiA, _MPs, _APs
is_allowed( true, _RCA, _RCP, true, true, _APs) -> false;
is_allowed( true, _RCA, _RCP, true, _MPs, true) -> true;
is_allowed( true, _RCA, _RCP, _MiA, _MPs, _APs) -> true;

is_allowed(false, true, false, _MiA, true, _APs) -> false;
is_allowed(false, true, false, _MiA, _MPs, true) -> true;

is_allowed(false, true, true, true, true, _APs) -> false;
is_allowed(false, true, true, true, _MPs, true) -> true;
is_allowed(false, true, true, false, _MPs, _APs) -> true;

is_allowed(false, false, true, true, _MPs, _APs) -> false;
is_allowed(false, false, true, false, _MPs, true) -> false;
is_allowed(false, false, true, false, true, _APs) -> true;

is_allowed(_RIO, _RCA, _RCP, _MiA, _MPs, _APs) -> false.


make_result({error, not_found}) ->
  {stop, {error, xmpp:err_item_not_found()}};
make_result({error, not_allowed}) ->
  {stop, {error, xmpp:err_not_allowed()}};
make_result({error, bad_request}) ->
  {stop, {error, xmpp:err_bad_request()}};
make_result({error, _}) ->
  {stop, {error, xmpp:err_internal_server_error()}};
make_result(Result) ->
  Result.


%% owner
perms_query_result({true, _, _}, Server, Group, Member) ->
  {Role, Actor, Perms, TS} = member_info(Server, Group, Member),
  perms_element(Role, Actor, Perms, TS, []);
%% create-admins and change-permissions
perms_query_result({_, true, true}, Server, Group, Member) ->
  {Role, Actor, Perms, TS} = member_info(Server, Group, Member),
  perms_element(Role, Actor, Perms, TS, []);
%% create-admins
perms_query_result({_, true, _}, Server, Group, Member) ->
  {Role, Actor, Perms, TS} = member_info(Server, Group, Member),
  perms_element(Role, Actor, Perms, TS, [<<"member">>]);
%% change-permissions
perms_query_result({_, _, true}, Server, Group, Member) ->
  {Role, Actor, Perms, TS} = member_info(Server, Group, Member),
  perms_element(Role, Actor, Perms, TS, [<<"admin">>]);
perms_query_result(my_perms, Server, Group, Member) ->
  {Role, Actor, Perms, TS} = member_info(Server, Group, Member),
  perms_element(Role, Actor, Perms, TS,
    [<<"owner">>, <<"admin">>, <<"member">>]);
%% not allowed
perms_query_result(_, _Server, _Group, _Member) ->
  {error, not_allowed}.

perms_element(Role, Actor, Perms, TS, []) ->
  TS1 = sec_to_now(TS),
  Perms1 = lists:keydelete(<<"owner">>, #perms_permission.name, Perms),
  #perms_permissions{label = Role, actor = Actor,
    perms = Perms1, stamp = TS1};
perms_element(Role, Actor, Perms, TS, LockedLevels) ->
  TS1 = sec_to_now(TS),
  Perms1 = lists:keydelete(<<"owner">>, #perms_permission.name, Perms),
  Locked = lock_perms(Perms1, LockedLevels),
  #perms_permissions{label = Role, actor = Actor,
    perms = Locked, stamp = TS1}.

-spec sec_to_now(non_neg_integer()) -> erlang:timestamp().
sec_to_now(Int) ->
  MSec = Int div 1000000,
  Sec = Int rem 1000000,
  {MSec, Sec, 0}.

init_fast_perms(Host) ->
  ejabberd_mnesia:create(?MODULE, fast_group_perms,
    [{ram_copies, [node()]},
      {attributes, record_info(fields, fast_group_perms)}]),
  Perms  = get_all_fast_perms_from_db(Host),
  lists:foreach(fun(FP) -> mnesia:dirty_write(FP) end, Perms).

get_all_fast_perms_from_db(Host)->
  lists:flatmap(fun(Name) ->
    #perms_permission{status = Status} =
      lists:keyfind(Name, #perms_permission.name, defaults()),
    UPerms = lists:map(
      fun({G, M, P, S, E}) ->
        #fast_group_perms{gup = {G, M, P}, status = S, expires = E}
      end, sql_get_users_with_perm(Host, Name, not Status)),
  GPerms = lists:map(
    fun({G, P, S}) ->
      #fast_group_perms{gup = {G, G, P}, status = S, expires = 0}
    end, sql_get_groups_with_perm(Host, Name, not Status)),
  UPerms ++ GPerms
                end, fast_permissions()).

%% SQL

sql_select_perms(Server, Group, User) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(permission)s,@(status)b,@(valid_until)d,"
    "@(issued_by)s,(select id from groupchat_users "
    " where username=issued_by and chatgroup=%(Group)s) as @(aid)s,"
    "@(issued_at)d from groupchat_permissions "
    " where groupchat=%(Group)s and member=%(User)s")) of
    {selected, Result} -> Result ;
    _ -> []
  end.

sql_select_default_perms(Server, Group) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(permission)s,@(status)b "
    " from groupchat_default_permissions where groupchat=%(Group)s")) of
    {selected, Result} -> Result ;
    _ -> []
  end.

sql_add_perm(Server, Group, Member, Perm, Level,
    Status, Expires, IssuedBy) ->
  Now = erlang:system_time(second),
  ?SQL_UPSERT(Server, "groupchat_permissions",
    ["!groupchat=%(Group)s",
      "!member=%(Member)s",
      "!permission=%(Perm)s",
      "level=%(Level)s",
      "status=%(Status)b",
      "valid_until=%(Expires)d",
      "issued_by=%(IssuedBy)s",
      "issued_at=%(Now)d"
    ]).

sql_delete_perm(Server, Group, Member, Perm) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_permissions "
    " where groupchat=%(Group)s and member=%(Member)s "
    " and permission=%(Perm)s")).

sql_delete_perms(Server, Group, Member) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_permissions "
    " where groupchat=%(Group)s and member=%(Member)s")).

sql_delete_expired_perms(Server, Group, Member) ->
  Now = erlang:system_time(second),
  ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_permissions "
    " where groupchat=%(Group)s and member=%(Member)s "
    "and valid_until > 0 and valid_until < %(Now)d")).

sql_delete_admin_perms(Server, Group, Member) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_permissions "
    " where groupchat=%(Group)s and member=%(Member)s "
    " and level in ('admin','owner')")).

sql_delete_member_perms(Server, Group, Member) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_permissions "
    " where groupchat=%(Group)s and member=%(Member)s "
    " and level='member'")).

sql_delete_perms(Server, Group) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_permissions "
    " where groupchat=%(Group)s")).

sql_add_default_perm(Server, Group, Perm, Status) ->
  ?SQL_UPSERT(Server,
    "groupchat_default_permissions",
    ["!groupchat=%(Group)s",
      "!permission=%(Perm)s",
      "status=%(Status)b"]).

sql_delete_default_perms(Server, Group) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_default_permissions "
    " where groupchat=%(Group)s")).

sql_select_newbies_perms(Server, Group)->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(permission)s,@(status)b,@(seconds)d "
    " from groupchat_newbies_permissions where groupchat=%(Group)s")) of
    {selected, Result} -> Result ;
    _ -> []
  end.

sql_add_newbies_perm(Server, Group, Perm, Status, Secs) ->
  ?SQL_UPSERT(Server, "groupchat_newbies_permissions",
    ["!groupchat=%(Group)s",
      "!permission=%(Perm)s",
      "status=%(Status)b",
      "seconds=%(Secs)d"
    ]).

sql_delete_newbies_perms(Server, Group)->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_newbies_permissions "
    " where groupchat=%(Group)s")).


sql_get_users_with_perm(Server, Perm, Status) ->
  Now = erlang:system_time(second),
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(groupchat)s,@(member)s,@(permission)s,@(status)b,@(valid_until)d "
    " from groupchat_permissions where permission=%(Perm)s "
    " and status=%(Status)b and (valid_until = 0 or valid_until > %(Now)d)")) of
    {selected, Result} -> Result ;
    _ -> []
  end.

sql_get_groups_with_perm(Server, Perm, Status) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(groupchat)s,@(permission)s,@(status)b "
    " from groupchat_default_permissions where permission=%(Perm)s "
    " and status=%(Status)b ")) of
    {selected, Result} -> Result ;
    _ -> []
  end.

sql_get_users(Server, Group) ->
  Now = erlang:system_time(second),
  case ejabberd_sql:sql_query(Server, ?SQL(
    "select @(users.id)s,@(perms.permission)s,@(perms.status)b,"
    "@(perms.valid_until)d,@(perms.issued_at)d,(select id from groupchat_users "
    " where username=issued_by and chatgroup=%(Group)s) as @(aid)s "
    " from groupchat_permissions as perms "
    " INNER JOIN groupchat_users as users ON "
    " perms.member=users.username and perms.groupchat=users.chatgroup "
    " where perms.groupchat=%(Group)s and perms.permission!='owner' "
    " and (perms.valid_until=0 or perms.valid_until > %(Now)d)")) of
    {selected, Result} -> Result;
    _ -> []
  end.

