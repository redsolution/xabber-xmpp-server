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
-export([start/2, stop/1, mod_options/1, depends/2, reload/3, mod_opt_type/1, decode_iq_subel/1]).

%% Hooks
-export([copy_newbies_perms/2, user_left/2, kick_users/3]).

%% API

-export([process_iq/1]).
-export([is_owner/3,
  get_owners/2,
  is_manager/3,
  validate_users/4,
  get_permissions/2,
  get_permissions/3,
  get_perms_query/3,
  set_permissions/4,
  set_permission/6,
  fast_is_permitted/3,
  is_permitted/3
 ]).

-record(permission,{name, display_name, role, status, expires, seconds, fixed, tag, issued_by}).
-record(fast_group_perms, {gup, status,  expires}).
-define(NS_GROUPS_PERMS, <<"https://xabber.com/protocol/groups/perms">>).
-define(NS_GROUPS_PERMS_DEFAULT, <<"https://xabber.com/protocol/groups/perms#default">>).
-define(NS_GROUPS_PERMS_NEWBIES, <<"https://xabber.com/protocol/groups/perms#newbies">>).

%% gen_mod
start(Host, _Opts) ->
  init_fast_perms(Host),
  register_hooks(Host),
  gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_GROUPS_PERMS,
    ?MODULE, process_iq),
  gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_GROUPS_PERMS_DEFAULT,
    ?MODULE, process_iq),
  gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_GROUPS_PERMS_NEWBIES,
    ?MODULE, process_iq),
%%  ejabberd_hooks:add(disco_local_items, Host, ?MODULE,
%%    get_local_items, 50),
  ok.

stop(Host) ->
  unregister_hooks(Host),
  gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_GROUPS_PERMS),
  gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_GROUPS_PERMS_DEFAULT),
  gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_GROUPS_PERMS_NEWBIES),
%%  ejabberd_hooks:delete(disco_local_items, Host, ?MODULE,
%%    get_local_items, 50).
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

process_iq(#iq{from = From, to = To, sub_els = [Query]} = Iq) ->
  {GUser, GServer, _} = jid:tolower(To),
  NS = xmpp_codec:get_attr(<<"xmlns">>, Query#xmlel.attrs, <<>>),
  case mod_xabber_entity:get_entity_type(GUser, GServer) of
    group ->
      Group = jid:to_string(jid:remove_resource(To)),
      User = jid:to_string(jid:remove_resource(From)),
      case mod_groups_users:check_if_exist(GServer, Group, User) of
        true ->
          process_iq(NS, Iq);
        _ ->
          xmpp:make_error(Iq, xmpp:err_not_allowed())
      end;
    _ ->
      xmpp:make_error(Iq, xmpp:err_not_allowed())
  end.

process_iq(?NS_GROUPS_PERMS, Iq) ->
  make_result(process_iq_personal(Iq), Iq);
process_iq(?NS_GROUPS_PERMS_DEFAULT, Iq) ->
  make_result(process_iq_default(Iq), Iq);
process_iq(?NS_GROUPS_PERMS_NEWBIES, Iq) ->
  make_result(process_iq_newbies(Iq), Iq);
process_iq(_, Iq) ->
  xmpp:make_error(Iq, xmpp:err_feature_not_implemented()).


%% Hooks

register_hooks(Host) ->
  ejabberd_hooks:add(groupchat_users_kicked, Host, ?MODULE, kick_users, 80),
  ejabberd_hooks:add(groupchat_presence_unsubscribed_hook, Host, ?MODULE, user_left, 30),
  ejabberd_hooks:add(groupchat_presence_subscribed_hook, Host, ?MODULE, copy_newbies_perms, 40).

unregister_hooks(Host) ->
  ejabberd_hooks:delete(groupchat_users_kicked, Host, ?MODULE, kick_users, 80),
  ejabberd_hooks:delete(groupchat_user_kick, Host, ?MODULE, kick_user, 35),
  ejabberd_hooks:delete(groupchat_presence_unsubscribed_hook, Host, ?MODULE, user_left, 30),
  ejabberd_hooks:delete(groupchat_presence_subscribed_hook, Host, ?MODULE, copy_newbies_perms, 40).

copy_newbies_perms(Acc, {Server, UserJID, Group, _Lang}) ->
  User = jid:to_string(jid:remove_resource(UserJID)),
  case is_owner(Server, Group, User) of
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


is_owner(Server, Group, Member) ->
  Perms = personal_perms(Server, Group, Member),
  is_permitted(<<"owner">>, Perms).

get_owners(Server, Group) ->
  sql_select_owners(Server,Group).

is_manager(Server, Group, Member) ->
  Perms = personal_perms(Server, Group, Member),
  P1 = filter_by_role(Perms, [<<"admin">>, <<"owner">>]),
  case [P || P <- P1, P#permission.status] of
    [] -> false;
    _ -> true
  end.

validate_users(Server, Group, Admin, User) ->
  Perms = personal_perms(Server, Group, User),
  IsOwner = is_owner(Perms),
  IsAdmin = is_admin(Perms),
  if
    IsOwner -> false;
    IsAdmin ->
      case get_promoter(Server, Group, User) of
        Admin -> true;
        _ -> false
      end;
    true -> true
  end.

get_permissions(Group, UserId) when is_binary(Group) ->
  get_permissions(jid:from_string(Group), UserId);
get_permissions(Group, UserId)->
  Server = Group#jid.lserver,
  GroupS = jid:to_string(jid:remove_resource(Group)),
  case mod_groups_users:get_user_by_id(Server, GroupS, UserId) of
    none -> {error, not_found};
    User ->
      get_permissions(Server, GroupS, User)
  end.

get_permissions(Server, Group, Member) ->
  GroupDefaults = group_perms(Server, Group),
  Personal = personal_perms(Server, Group, Member),
  calculate_perms(GroupDefaults, Personal).

fast_is_permitted(<<"send-messages">>, User, Group)->
  fast_is_permitted(member, <<"send-messages">>, User, Group);
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

is_permitted(Action, User, Group)->
  {_, Server, _} = jid:tolower(jid:from_string(Group)),
  UserPerms = get_permissions(Server, Group, User),
  is_permitted(<<"owner">>, UserPerms) orelse is_permitted(Action, UserPerms).



set_permissions(Group, Member, Perms, IssuedBy) ->
  lists:foreach(
    fun(#permission{name = Name, seconds = Secs, status = Status})->
    set_permission(Group, Member, Name, Status, Secs, IssuedBy)
    end, Perms).


set_permission(Group, Member, PermName, Status, Seconds, IssuedBy) ->
  {_, Server, _} = jid:tolower(jid:from_string(Group)),
  Expires = case Seconds of
              0 -> 0;
              _ -> erlang:system_time(second) + Seconds
            end,
  case lists:keyfind(PermName, #permission.name, defaults()) of
    false -> error;
    Perm ->
      sql_add_perm(Server, Group, Member, PermName, Perm#permission.role,
        Status, Expires, IssuedBy)
  end.


%% Internal
defaults() ->
  [
    #permission{name = <<"send-messages">>, display_name = <<"Send messages">>,
      role = <<"member">>, status = true},
    #permission{name = <<"send-media">>, display_name = <<"Send media">>,
      role = <<"member">>, status = true},
    #permission{name = <<"add-members">>, display_name = <<"Add members">>,
      role = <<"member">>, status = true},
    #permission{name = <<"pin-messages">>, display_name = <<"Pin messages">>,
      role = <<"member">>, status = false},
    #permission{name = <<"change-group-info">>, display_name = <<"Change group info">>,
      role = <<"member">>, status = false},
    #permission{name = <<"owner">>, display_name = <<"Owner">>,
      role = <<"owner">>, status = false},
    #permission{name = <<"change-group-settings">>, display_name = <<"Edit group settings">>,
      role = <<"admin">>, status = false},
    #permission{name = <<"change-user-info">>, display_name = <<"Edit users' info">>,
      role = <<"admin">>, status = false},
    #permission{name = <<"delete-messages">>, display_name = <<"Delete messages">>,
      role = <<"admin">>, status = false},
    #permission{name = <<"change-permissions">>, display_name = <<"Change users' permissions">>,
      role = <<"admin">>, status = false},
    #permission{name = <<"change-default-permissions">>, display_name = <<"Change default permissions">>,
      role = <<"admin">>, status = false},
    #permission{name = <<"block-users">>, display_name = <<"Kick and block users">>,
      role = <<"admin">>, status = false},
    #permission{name = <<"create-admins">>, display_name = <<"Create admins">>,
      role = <<"admin">>, status = false}
  ].

process_iq_personal(#iq{type = get, from = From, to = To,
  sub_els = [Query]}) ->
  case lists:keyfind(<<"id">>, 1, Query#xmlel.attrs) of
    {_, Val} when Val /= <<>> ->
      get_perms_query(To, From, Val);
    _ -> {error, bad_request}
  end;
process_iq_personal(#iq{type = set, from = From, to = To,
  sub_els = [Query]}) ->
  Perms = decode_query(Query),
  case lists:keyfind(<<"id">>, 1, Query#xmlel.attrs) of
    {_, Val} when Val /= <<>> ->
      set_perms_query(To, From, Val, Perms);
    _ -> {error, bad_request}
  end;
process_iq_personal(_) ->
  {error, bad_request}.

process_iq_default(#iq{type = get, from = From, to = To}) ->
  get_default_perms_query(To, From);
process_iq_default(#iq{type = set, from = From, to = To,
  sub_els = [Query]} ) ->
  Perms = decode_query(Query),
  set_default_perms_query(To, From, Perms);
process_iq_default(_) ->
  {error, bad_request}.

process_iq_newbies(#iq{type = get, from = From, to = To}) ->
  get_newbies_perms_query(To, From);
process_iq_newbies(#iq{type = set, from = From, to = To,
  sub_els = [Query]}) ->
  Perms = decode_query(Query),
  set_newbies_perms_query(To, From, Perms);
process_iq_newbies(_) ->
  {error, bad_request}.


get_default_perms_query(GroupJID, UserJID) ->
  Server = GroupJID#jid.lserver,
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  User = jid:to_string(jid:remove_resource(UserJID)),
  UserPerms = get_permissions(Server, Group, User),
  IsOwner = is_permitted(<<"owner">>, UserPerms),
  IsChangePerms =is_permitted(<<"change-default-permissions">>, UserPerms),
  if
    IsOwner; IsChangePerms ->
      GrPerms = calculate_default_perms(Server, Group),
      permissions_xmlel(GrPerms);
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
  IsAdminPerms = check_roles(Perms, [<<"admin">>,<<"owner">>]),
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
    Perm#permission.name, Perm#permission.status),
  copy_to_fast_perms(Server,Group, Group, Perm),
  add_default_perms(Server, Group, Perms).

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

%%set_perms_query(Server, Group, Requester, Member, Perms)->
%%  RPerms = get_permissions(Server, Group, Requester),
%%  Owner = is_permitted(<<"owner">>, RPerms),
%%  CreateAdmins = is_permitted(<<"create-admins">>, RPerms),
%%  ChangePerms = is_permitted(<<"change-permissions">>, RPerms),
%%  MemberPerms = get_permissions(Server, Group, Member),
%%  MemberIsAdmin = is_admin(MemberPerms),
%%  MemberIsOwner = is_permitted(<<"owner">>, MemberPerms),
%%  MPs = check_roles(Perms, [<<"member">>]),
%%  APs = check_roles(Perms, [<<"admin">>]),
%%  OPs = check_roles(Perms, [<<"owner">>]),
%%  case is_allowed(Owner, CreateAdmins, ChangePerms,
%%    MemberIsOwner, MemberIsAdmin, MPs, APs, OPs) of
%%    true ->
%%      add_personal_perms(Server, Group, Requester, Member, Perms);
%%    false ->
%%      {error, not_allowed}
%%  end.

set_perms_query(Server, Group, Requester, Member, Perms) ->
  R = verify_users(Server, Group, Requester, Member),
  set_perms_query(R, Server, Group, Requester, Member, Perms).

set_perms_query({true, ReqOpts, MemberOpts}, Server, Group,
    Requester, Member, Perms) ->
  {RisOwner, CreateAdmins, ChangePerms} = ReqOpts,
  {MisOwner, MisAdmin} = MemberOpts,
  MPs = check_roles(Perms, [<<"member">>]),
  APs = check_roles(Perms, [<<"admin">>]),
  OPs = check_roles(Perms, [<<"owner">>]),
  case is_allowed(RisOwner, CreateAdmins, ChangePerms,
    MisOwner, MisAdmin, MPs, APs, OPs) of
    true ->
      add_personal_perms(Server, Group, Requester, Member, Perms),
      update_user(Server, Group, Requester, Member, MemberOpts);
    false ->
      {error, not_allowed}
  end ;
set_perms_query(_, _, _, _, _, _) ->
  {error, not_allowed}.

add_personal_perms(Server, Group, IssuedBy, Member, Perms) ->
  lists:foreach(fun(Perm) ->
    Expires = case Perm#permission.seconds of
                0 -> 0;
                S -> erlang:system_time(second) + S
              end,

    sql_add_perm(Server, Group, Member, Perm#permission.name,
      Perm#permission.role, Perm#permission.status, Expires, IssuedBy),
    copy_to_fast_perms(Server, Group, Member,
      Perm#permission{expires = Expires})
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
  Perms = get_permissions(Server, Group, Requester),
  IsOwner = is_permitted(<<"owner">>, Perms),
  AllowCreateAdmins = is_permitted(<<"create-admins">>, Perms),
  AllowChangePerms = is_permitted(<<"change-permissions">>, Perms),
  perms_query_result(
    {IsOwner, AllowChangePerms, AllowCreateAdmins}, Server, Group, Member).

delete_admin_perms(Server, Group, Member) ->
  sql_delete_admin_perms(Server, Group, Member),
  sql_delete_promoter(Server, Group, Member),
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
      permissions_xmlel(Perms);
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
  IsAdminPerms = check_roles(Perms, [<<"admin">>,<<"owner">>]),
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
    Perm#permission.name, Perm#permission.status, Perm#permission.seconds),
  add_newbies_perms(Server, Group, Perms).

delete_newbies_perms(Server, Group) ->
  sql_delete_newbies_perms(Server, Group).

save_promoter(Server, Group, IssuedBy, Member) ->
  case get_promoter(Server, Group, Member) of
    not_found ->
      sql_save_promoter(Server, Group, IssuedBy, Member);
    _ ->
      ok
  end.

delete_promoter(Server, Group, Member) ->
  sql_delete_promoter(Server, Group, Member),
  ok.

get_role(Perm) ->
  case lists:keyfind(Perm, #permission.role, defaults()) of
    #permission{role = V} -> V;
    _ -> <<"member">>
  end.

group_perms(Server, Group) ->
  sql_select_default_perms(Server, Group).

personal_perms(Server, Group, Member) ->
  Perms = sql_select_perms(Server, Group, Member),
  lists:map(fun({Name, Status, Expires}) ->
    P = lists:keyfind(Name, #permission.name, defaults()),
    P#permission{status = Status, expires = Expires}
            end, Perms).




copy_to_fast_perms(_Server, Group, Group,
    #permission{name = <<"send-messages">>} = P) ->
  Default = is_permitted(P#permission.name, defaults()),
  case P#permission.status of
    Default ->
      del_fast_perm(Group, Group, P);
    _ ->
      add_fast_perm(Group, Group, P)
  end;
copy_to_fast_perms(Server, Group, Member,
    #permission{name = <<"send-messages">>} = P) ->
  GroupPerms = calculate_default_perms(Server,Group),
  Default = is_permitted(P#permission.name, GroupPerms),
  case P#permission.status of
    Default ->
      del_fast_perm(Group, Member, P);
    _ ->
      add_fast_perm(Group, Member, P)
  end;
copy_to_fast_perms(_Server, _Group, _Member, _) ->
  ok.

add_fast_perm(Group, Member, P) ->
  Expires = case P#permission.expires of
              0 -> infinity;
              undefined -> infinity;
              V -> V
            end,
  mnesia:dirty_write(#fast_group_perms{
    gup = {Group, Member, P#permission.name},
    status = P#permission.status,
    expires = Expires}).

del_fast_perm(Group, Member, P) ->
  mnesia:dirty_delete(fast_group_perms,
    {Group, Member, P#permission.name}).


newbies_perms(Server, Group)->
  Values = sql_select_newbies_perms(Server, Group),
  lists:filtermap(
    fun(#permission{name = Name} = P)->
      case lists:keyfind(Name, 1, Values) of
        {Name, Status, Secs} ->
          {true, P#permission{status = Status, seconds = Secs}};
        _ ->
          false
      end
    end, defaults()).


calculate_default_perms(Server, Group) ->
  GroupPerms = group_perms(Server, Group),
  Perms = lists:map(
    fun(#permission{name = Name} = P)->
      case lists:keyfind(Name, 1, GroupPerms) of
        {Name, Status} ->
          P#permission{status = Status};
        _ ->
          P
      end
    end, defaults()),
  filter_by_role(Perms, [<<"member">>]).


calculate_perms(Perms) ->
  Role = lists:foldl(
    fun(#permission{role = <<"admin">>, status = true}, owner) -> owner;
      (#permission{role = <<"admin">>, status = true}, _) -> admin;
      (#permission{role = <<"owner">>, status = true}, _) -> owner;
      (_, Acc) -> Acc
    end, member, Perms),
  case Role of
    owner ->
      [P#permission{status = true, expires = 0} || P <- Perms];
    admin ->
      lists:map(
        fun(#permission{role = <<"member">>} = P) ->
          P#permission{status = true, expires = 0};
          (P) -> P
        end, Perms);
    _ ->
      Perms
  end.

calculate_perms(GroupDefaults, Personal) ->
  Perms =lists:map(
    fun(#permission{name = Name} = P)->
      case lists:keyfind(Name, #permission.name, Personal) of
        false ->
          case lists:keyfind(Name, 1, GroupDefaults) of
            {Name, Status} ->
              P#permission{status = Status};
            _ ->
              P
          end;
        Perm -> Perm
      end
    end, defaults()),
  calculate_perms(Perms).


is_permitted(Perm, Perms) ->
  case lists:keyfind(Perm, #permission.name, Perms) of
    #permission{status = S} -> S;
    _ -> false
  end.

filter_by_role(Perms, Roles)->
  [P || P <- Perms, lists:member(P#permission.role, Roles)].

check_roles(Perms, Roles) ->
  case filter_by_role(Perms, Roles) of
    [] -> false;
    _ -> true
  end.

lock_perms(Perms, Roles) ->
  lists:map(fun(P) ->
    case  lists:member(P#permission.role, Roles) of
      true -> P#permission{fixed = true};
      _ -> P
    end
            end, Perms).

is_owner(Perms) ->
  is_permitted(<<"owner">>, Perms).

is_admin(Perms) ->
  P1 = filter_by_role(Perms, [<<"admin">>]),
  case [P || P <- P1, P#permission.status] of
    [] -> false;
    _ -> true
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
  Perms = get_permissions(Server, Group, User),
  UserIsOwner = is_permitted(<<"owner">>, Perms),
  UserIsAdmin = is_admin(Perms),
  UserOpts = {UserIsOwner, UserIsAdmin},
  {ReqIsOwner, _, _} = ReqOpts,
  if
    UserIsOwner -> false;
    ReqIsOwner -> {true, ReqOpts, UserOpts};
    UserIsAdmin ->
       case get_promoter(Server, Group, User) of
         Requester -> {true, ReqOpts, UserOpts};
         _ -> false
       end;
    true -> {true, ReqOpts, UserOpts}
  end.

update_user(Server, Group, IssuedBy, Member, {WasOwner, WasAdmin})->
  Perms = get_permissions(Server, Group, Member),
  IsOwner = is_permitted(<<"owner">>, Perms),
  IsAdmin = is_admin(Perms),
  if
    (not WasOwner and IsOwner) orelse
      (not WasAdmin and IsAdmin) ->
      save_promoter(Server, Group, IssuedBy, Member);
    WasAdmin and not IsAdmin ->
      delete_promoter(Server, Group, Member);
    true -> ok
  end,
  Role = if
           IsOwner -> <<"owner">>;
           IsAdmin -> <<"admin">>;
           true -> <<"member">>
         end,
  mod_groups_users:update_user_status(Server, Member, Group, Role),
  ok.

get_promoter(Server, Group, Protege) ->
  {_, Server, _ } = jid:tolower(jid:from_string(Group)),
  case sql_get_promoter(Server, Group, Protege) of
    not_found -> not_found;
    P -> P
  end.


%% RiO - Requester is Owner, RCA - Requester can Crete Admin, RCP - Requester can Change Perms,
%% MiO - Member is Owner, MiA - Member is Admin,
%% MPs - Perms for members, APs - Perms for admins, OPs - Perms for owner
%%         _RiO, _RCA , _RCP, _MiO, _MiA, _MPs, _APs, _OPs
is_allowed( true, _RCA, _RCP, true, _MiA, true, _APs, _OPs) -> false;
is_allowed( true, _RCA, _RCP, true, _MiA, _MPs, true, _OPs) -> false;
is_allowed( true, _RCA, _RCP, true, _MiA, _MPs, _APs, true) -> true;
is_allowed( true, _RCA, _RCP, _MiO, true, true, _APs, _OPs) -> false;
is_allowed( true, _RCA, _RCP, _MiO, true, _MPs, true, _OPs) -> true;
is_allowed( true, _RCA, _RCP, _MiO, true, _MPs, _APs, true) -> true;
is_allowed( true, _RCA, _RCP, _MiO, _MiA, _MPs, _APs, _OPs) -> true;
%% only owners can manage owners
is_allowed(false, _RCA, _RCP, true, _MiA, _MPs, _APs, _OPs) -> false;
is_allowed(false, _RCA, _RCP, _MiO, _MiA, _MPs, _APs, true) -> false;

is_allowed(false, true, false, _MiO, _MiA, true, _APs, _OPs) -> false;
is_allowed(false, true, false, _MiO, _MiA, _MPs, true, _OPs) -> true;

is_allowed(false, true, true, _MiO, true, true, _APs, _OPs) -> false;
is_allowed(false, true, true, _MiO, true, _MPs, true, _OPs) -> true;
is_allowed(false, true, true, _MiO, false, _MPs, _APs, _OPs) -> true;

is_allowed(false, false, true, _MiO, true, _MPs, _APs, _OPs) -> false;
is_allowed(false, false, true, _MiO, false, _MPs, true, _OPs) -> false;
is_allowed(false, false, true, _MiO, false, true, _APs, _OPs) -> true;

is_allowed(_RIO, _RCA, _RCP, _MiO, _MiA, _MPs, _APs, _OPs) -> false.


make_result({error, not_found},Iq) ->
  xmpp:make_error(Iq, xmpp:err_item_not_found());
make_result({error, not_allowed},Iq) ->
  xmpp:make_error(Iq, xmpp:err_not_allowed());
make_result({error, bad_request},Iq) ->
  xmpp:make_error(Iq, xmpp:err_bad_request());
make_result({error, _},Iq) ->
  xmpp:make_error(Iq, xmpp:err_internal_server_error());
make_result(Result,Iq) when is_tuple(Result) ->
  xmpp:make_iq_result(Iq, Result);
make_result(_,Iq) ->
  xmpp:make_iq_result(Iq).

%%set_perms_query(Server, Group, Requester, Member, Perms)->
%%  RPerms = get_permissions(Server, Group, Requester),
%%  Owner = is_permitted(<<"owner">>, RPerms),
%%  CreateAdmins = is_permitted(<<"create-admins">>, RPerms),
%%  ChangePerms = is_permitted(<<"change-permissions">>, RPerms),
%%  IsAllowed =
%%    if
%%      Owner; ChangePerms; CreateAdmins ->
%%        MemberPerms = get_permissions(Server, Group, Member),
%%        MemberAdmin = is_admin(MemberPerms),
%%        case {MemberAdmin, check_roles(Perms, [<<"member">>])} of
%%          {true, true} ->
%%            false;
%%          _ ->
%%            true
%%        end;
%%     true ->
%%        false
%%    end,
%%  if
%%    IsAllowed ->
%%      set_perms_query({Owner, ChangePerms, CreateAdmins},
%%      Server, Group, Requester, Member, Perms);
%%    true ->
%%      {error, not_allowed}
%%  end.

%% owner
%%set_perms_query({true, _, _}, Server, Group, IssuedBy, Member, Perms) ->
%%  add_personal_perms(Server, Group, IssuedBy, Member, Perms);
%%%% change-permissions and create-admins
%%set_perms_query({_, true, true}, Server, Group, IssuedBy, Member, Perms) ->
%%  case lists:keyfind(<<"owner">>, #permission.name, Perms) of
%%    false ->
%%      add_personal_perms(Server, Group, IssuedBy, Member, Perms);
%%    _ ->
%%      {error, not_allowed}
%%  end;
%%%% change-permissions
%%set_perms_query({_, true, _}, Server, Group, IssuedBy, Member, Perms) ->
%%  Forbidden = check_forbidden(Perms, [<<"owner">>, <<"admin">>]),
%%  set_perms_query(Forbidden, Server, Group, IssuedBy, Member, Perms);
%%%% create-admins
%%set_perms_query({_, _, true}, Server, Group, IssuedBy, Member, Perms) ->
%%  Forbidden = check_forbidden(Perms, [<<"owner">>, <<"member">>]),
%%  set_perms_query(Forbidden, Server, Group, IssuedBy, Member, Perms);
%%set_perms_query(true, Server, Group, IssuedBy, Member, Perms) ->
%%  add_personal_perms(Server, Group, IssuedBy, Member, Perms);
%%set_perms_query(_, _Server, _Group, _IssuedBy, _Member, _Perms) ->
%%  {error, not_allowed}.


%% owner
perms_query_result({true, _, _}, Server, Group, Member) ->
  Perms = get_permissions(Server, Group, Member),
  permissions_xmlel(Perms);
%% create-admins and change-permissions
perms_query_result({_, true, true}, Server, Group, Member) ->
  Perms = get_permissions(Server, Group, Member),
  permissions_xmlel(lock_perms(Perms,[<<"owner">>]));
%% change-permissions
perms_query_result({_, true, _}, Server, Group, Member) ->
  Perms = get_permissions(Server, Group, Member),
  permissions_xmlel(lock_perms(Perms,[<<"owner">>, <<"admin">>]));
%% create-admins
perms_query_result({_, _, true}, Server, Group, Member) ->
  Perms = get_permissions(Server, Group, Member),
  permissions_xmlel(lock_perms(Perms,[<<"owner">>, <<"member">>]));
perms_query_result(my_perms, Server, Group, Member) ->
  Perms = get_permissions(Server, Group, Member),
  Locked = lock_perms(Perms,[<<"owner">>, <<"admin">>, <<"member">>]),
  permissions_xmlel(Locked);
%% not allowed
perms_query_result(_, _Server, _Group, _Member) ->
  {error, not_allowed}.


permissions_xmlel(Perms) ->
  PermsELs = lists:map(
    fun(Perm) ->
      Expires = case Perm#permission.expires of
                  undefined -> [];
                  0 -> [];
                  V -> [{<<"expires">>, integer_to_binary(V)}]
                end,
      Fixed = case Perm#permission.fixed of
                true -> [{<<"fixed">>, <<"true">>}];
                _ -> []
              end,
      Seconds = case Perm#permission.seconds of
                  undefined -> [];
                  0 -> [];
                  S -> [{<<"seconds">>, integer_to_binary(S)}]
                end,

      #xmlel{name = <<"permission">>, attrs = [
        {<<"xmlns">>, ?NS_GROUPS_PERMS},
        {<<"name">>, Perm#permission.name},
        {<<"role">>, Perm#permission.role},
        {<<"status">>, atom_to_binary(Perm#permission.status, latin1)}
        ] ++ Expires ++ Fixed ++ Seconds,
        children = [{xmlcdata, Perm#permission.display_name}]}
    end, Perms),
  #xmlel{name = <<"permissions">>,
    attrs = [{<<"xmlns">>, ?NS_GROUPS_PERMS}],
    children = PermsELs}.

-spec decode_iq_subel(xmpp_element() | xmlel()) -> xmpp_element() | xmlel().
%% Tell gen_iq_handler not to auto-decode IQ payload
decode_iq_subel(El) ->
  Els = El#xmlel.children,
  Perms = lists:filter(
    fun({xmlcdata, _}) -> false;
      (_) -> true
    end, Els),
  El#xmlel{children = Perms}.

decode_query(Query) ->
  PermsEl = decode_iq_subel(hd(Query#xmlel.children)),
  Els = PermsEl#xmlel.children,
  Perms = lists:filtermap(
    fun(#xmlel{} = P) ->
      Name = xmpp:get_name(P),
      if
        Name == <<"permission">> ->
          validate_perm_el(P);
        true ->
          false
      end;
      (_) -> false
    end, Els),
  Perms.

validate_perm_el(El) ->
  Name = xmpp_codec:get_attr(<<"name">>, El#xmlel.attrs, undefined),
  Perm = lists:keyfind(Name, #permission.name, defaults()),
  Status = xmpp_codec:get_attr(<<"status">>, El#xmlel.attrs, undefined),
  Seconds = xmpp_codec:get_attr(<<"seconds">>, El#xmlel.attrs, <<"0">>),
  if
    Perm == false orelse Status == undefined ->
      false;
    true ->
      {true, Perm#permission{status = dec_bool(Status),
        seconds = binary_to_integer(Seconds)}}
  end.

dec_bool(<<"1">>) -> true;
dec_bool(<<"0">>) -> false;
dec_bool(<<"true">>) -> true;
dec_bool(<<"false">>) -> false.

init_fast_perms(Host) ->
  ejabberd_mnesia:create(?MODULE, fast_group_perms,
    [{ram_copies, [node()]},
      {attributes, record_info(fields, fast_group_perms)}]),
  Perms  = get_all_fast_perms_from_db(Host),
  lists:foreach(fun(FP) -> mnesia:dirty_write(FP) end, Perms).

get_all_fast_perms_from_db(Host)->
  UPerms = lists:map(
    fun({G, M, P, S, E}) ->
      #fast_group_perms{gup = {G, M, P}, status = S, expires = E}
    end, sql_get_users_with_perm(Host, <<"send-messages">>, false)),
  GPerms = lists:map(
    fun({G, P, S}) ->
      #fast_group_perms{gup = {G, G, P}, status = S, expires = 0}
    end, sql_get_groups_with_perm(Host, <<"send-messages">>, false)),
  UPerms ++ GPerms.

%% SQL

sql_select_perms(Server, Group, User) ->
  Now = erlang:system_time(second),
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(permission)s,@(status)b,@(valid_until)d "
    " from groupchat_permissions where groupchat=%(Group)s "
    " and member=%(User)s and (valid_until = 0 or valid_until > %(Now)d)")) of
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

%%sql_select_perm(Server, Group, User, Perm) ->
%%  Now = erlang:system_time(second),
%%  case ejabberd_sql:sql_query(
%%    Server,
%%    ?SQL("select @(status)b from groupchat_permissions "
%%    " where groupchat=%(Group)s and member=%(User)s and permission=%(Perm)s"
%%    " and (valid_until = 0 or valid_until > %(Now)d) and "
%%    " (select subscription from groupchat_users where chatgroup=%(Group)s "
%%    " and username=%(User)s)='both'")) of
%%    {selected, []} -> undefined;
%%    {selected, [Result | _]} -> Result ;
%%    _ -> false
%%  end.



sql_add_perm(Server, Group, Member, Perm, Role,
    Status, Expires, IssuedBy) ->
  ?SQL_UPSERT(Server, "groupchat_permissions",
    ["!groupchat=%(Group)s",
      "!member=%(Member)s",
      "!permission=%(Perm)s",
      "grole=%(Role)s",
      "status=%(Status)b",
      "valid_until=%(Expires)d",
      "issued_by=%(IssuedBy)s"
    ]).

sql_delete_admin_perms(Server, Group, Member) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_permissions "
    " where groupchat=%(Group)s and member=%(Member)s "
    " and grole in ('admin','owner')")).

sql_add_default_perm(Server, Group, Perm, Status) ->
  ?SQL_UPSERT(Server,
    "groupchat_default_permissions",
    ["!groupchat=%(Group)s",
      "!permission=%(Perm)s",
      "status=%(Status)b"]).

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

sql_select_owners(Server, Group) ->
  Now = erlang:system_time(second),
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(member)s from groupchat_permissions where "
    " groupchat=%(Group)s and permission = 'owner' and status "
    " and (valid_until = 0 or valid_until > %(Now)d) "
    " and (select true from groupchat_users where "
    "chatgroup=%(Group)s and username=member "
    " and subscription='both')") ) of
    {selected, Result} -> [V || {V} <- Result];
    _ ->
      []
  end.


sql_get_promoter(Server, Group, Protege)->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(promoter)s from groupchat_permissions_promoter "
    " where groupchat=%(Group)s and protege=%(Protege)s")) of
    {selected, [{Result}]} -> Result;
    _ ->
      not_found
  end.

sql_save_promoter(Server, Group, Promoter, Protege) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL_INSERT(
      "groupchat_permissions_promoter",
      ["groupchat=%(Group)s",
        "promoter=%(Promoter)s",
        "protege=%(Protege)s"])).

sql_delete_promoter(Server, Group, Protege)->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_permissions_promoter "
    " where groupchat=%(Group)s and protege=%(Protege)s")).

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


