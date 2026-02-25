%%%-------------------------------------------------------------------
%%% File    : groups_presences.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : Presences processing.
%%% Created : 22 Jan 2026 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%%
%%%
%%% xabberserver, Copyright (C) 2007-2026   redsolution corp
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

-module(groups_presences).
-author('ilya.kalashnikov@redsolution.com').
-behavior(gen_mod).
-behavior(gen_server).

-include("logger.hrl").
-include("xmpp.hrl").

%% gen_mod, gen_server
-export([init/1, handle_call/3, handle_cast/2, terminate/2, handle_info/2]).
-export([start/2, stop/1, depends/2, mod_options/1]).

%% API
-export([check_in_subscription/2, send_presence/4]).


%% records
-record(presence_state, {host = <<"">> :: binary()}).

start(Host, Opts) ->
  gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
  gen_mod:stop_child(?MODULE, Host).

depends(_Host, _Opts) ->  [].

mod_options(_Host) -> [].

init([Host, _Opts]) ->
  register_hooks(Host),
  {ok, #presence_state{host = Host}}.

terminate(_Reason, State) ->
  Host = State#presence_state.host,
  unregister_hooks(Host).

register_hooks(Host) ->
  ejabberd_hooks:add(roster_in_subscription, Host, ?MODULE, check_in_subscription, 10).

unregister_hooks(Host) ->
  ejabberd_hooks:delete(roster_in_subscription, Host, ?MODULE, check_in_subscription, 10).

handle_call(_Request, _From, _State) ->
  erlang:error(not_implemented).

handle_cast(#presence{to = To} = Presence, State) ->
  Group = jid:to_string(jid:remove_resource(To)),
  process_presence(groups_groups:group_is_active(Group),Presence),
  {noreply, State};
handle_cast(_Request, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

send_presence(Users, Group, Type, Opts) ->
  GroupJID = jid:replace_resource(jid:from_string(Group), <<"Group">>),
  Server = GroupJID#jid.lserver,
  case groups_groups:group_details(Server,
    undefined, Group, Opts) of
    error ->
      %% Happens when deleting a group
      P = #presence{type = Type, id = randoms:get_string(),
        sub_els = [#groups_group{}], status = []},
      lists:foreach(fun(User) ->
        ejabberd_router:route(GroupJID, User , P)
                    end, Users);
    GroupEl ->
      IsP2P = case GroupEl#groups_group.parent of
                undefined -> false;
                _ -> true
              end,
      Full = proplists:get_value(full, Opts, false),
      send_presence(IsP2P, Users, GroupJID, Type, GroupEl, Full)
  end.

do_send_presence(From, To, Type, GroupEl) ->
  Status = case GroupEl#groups_group.info#groups_info.status of
             undefined -> [];
             Data -> [#text{data = Data}]
           end,
  Show = case GroupEl#groups_group.settings#groups_settings.state of
           inactive -> xa;
           _ -> chat
         end,
  DiscoInfo = groups_discovery:client_disco_info(
    GroupEl#groups_group.privacy),
  DiscoHash = mod_caps:compute_disco_hash(DiscoInfo, sha),
  Caps = #caps{hash = <<"sha-1">>, node = ?NS_GROUPS, version = DiscoHash},
  P = #presence{type = Type, id = randoms:get_string(),
    sub_els = [GroupEl, Caps], status = Status, show = Show},
  ejabberd_router:route(From, To , P).

send_presence(_, [], _, _, _, _)  ->  ok;
send_presence(false, [User|Users], GroupJID, Type, GroupEl, Full) ->
  do_send_presence(GroupJID, User, Type, GroupEl),
  send_presence(false, Users, GroupJID, Type, GroupEl, Full);
send_presence(true, [UserJID | Users], GroupJID, Type, GroupEl, Full) ->
  UserS = jid:to_string(jid:remove_resource(UserJID)),
  GroupS = jid:to_string(jid:remove_resource(GroupJID)),
  Server = GroupJID#jid.lserver,
  Info = GroupEl#groups_group.info,
  Name = groups_groups:get_name(GroupS, UserS, true,
    Info#groups_info.name),
  Avatar = case Full of
             true ->
               groups_groups:get_avatar(Server, GroupS,
                 UserS, true);
             _ -> undefined
           end,
  Info1 = Info#groups_info{name = Name, avatar = Avatar},
  GroupEl1 = GroupEl#groups_group{info = Info1},
  do_send_presence(GroupJID, UserJID, Type, GroupEl1),
  send_presence(true, Users, GroupJID, Type, GroupEl, Full).

check_in_subscription(Acc, #presence{to=To} = Packet) ->
  Group = jid:to_string(jid:remove_resource(To)),
  case groups_groups:group_is_active(Group) of
    false -> Acc;
    inactive -> {stop, false};
    _ ->
      answer_presence(Packet),
      {stop, false}
  end.

process_presence(false, Packet) ->
  Packet;
process_presence(inactive, _Packet) ->
  drop;
process_presence(_, Packet) ->
  answer_presence(Packet).

is_group(SubEls) ->
  case lists:keyfind(groups_group, 1, SubEls) of
    false -> false;
    _ -> true
  end.

answer_presence(#presence{type = available,
  to = GroupJID, from = UserJID} = Presence) ->
  Server = GroupJID#jid.lserver,
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  User = jid:to_string(jid:remove_resource(UserJID)),
  PresenceD = xmpp:decode_els(Presence),
  Decoded = PresenceD#presence.sub_els,
  case is_group(Decoded) of
    true ->
      %% Thr user account became the group account
      process_unsubscribe(UserJID, GroupJID, unsubscribe);
    false ->
      case groups_members:check_if_exist(Server, Group, User) of
        true -> process_available(UserJID, GroupJID, Decoded);
        _ -> ok
      end
  end;
answer_presence(#presence{type = subscribe,
  to = GroupJID, from = UserJID} = Presence) ->
  Server = GroupJID#jid.lserver,
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  GroupFJID = jid:replace_resource(GroupJID, <<"Group">>),
  Nick = case xmpp:get_subtag(Presence, #nick{}) of
           #nick{name = N} -> N;
           _ -> false
         end,
  DenyUserAvatar = case xmpp:get_subtag(Presence,
    #groups_deny_user_avatar{}) of
                     false -> false;
                     _ -> true
                   end,
  case check_access(Server, Group, UserJID) of
    error ->
      ejabberd_router:route(GroupFJID, UserJID,
        #presence{type = error, sub_els =
        [xmpp:err_internal_server_error()]});
    not_allowed ->
      send_presence([UserJID], Group, unsubscribed, []);
    _ ->
      process_subscribe(Server, Group, UserJID, Nick,
        DenyUserAvatar)
  end;
answer_presence(#presence{type = subscribed,
  to = GroupJID, from = UserJID}) ->
  Server = GroupJID#jid.lserver,
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  Result = ejabberd_hooks:run_fold(groups_presence_subscribed,
    Server, [], [{Server, UserJID, Group}]),
  case Result of
    ok ->
      Users = groups_members:users_to_send(Server, Group),
      send_presence(Users, Group, available, [present, members]),
      User = jid:to_string(jid:remove_resource(UserJID)),
      groups_avatars:request_pubsub_metadata(Group, User);
    _ ->
      ok
  end;
answer_presence(#presence{type = unsubscribe,
  to = GroupJID, from = UserJID}) ->
  Server = GroupJID#jid.lserver,
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  User = jid:to_string(jid:remove_resource(UserJID)),
  case groups_members:is_in_group(Server, Group, User) of
    true ->
      process_unsubscribe(UserJID, GroupJID, unsubscribe);
    _ ->
      ok
  end;
answer_presence(#presence{type = unsubscribed,
  to = GroupJID, from = UserJID}) ->
  Server = GroupJID#jid.lserver,
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  User = jid:to_string(jid:remove_resource(UserJID)),
  case groups_members:is_in_group(Server, Group, User) of
    true ->
      process_unsubscribe(UserJID, GroupJID, unsubscribed);
    _ ->
      ok
  end;
answer_presence(#presence{to = To, from = From, type = unavailable}) ->
  groups_messages:change_present_state(To, From, not_present);
answer_presence(Presence) ->
  ?DEBUG("Drop presence ~p",[Presence]).

process_available(UserJID, GroupJID, _SubEls)->
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  Server = GroupJID#jid.lserver,
%%  todo: move to user settings
%%  case lists:keyfind(groups_ban_ptp, 1, SubEls) of
%%    {groups_ban_ptp, Value} ->
%%      groups_members:change_p2p_invitation_state(Server,
%%        User, Group, Value);
%%    _ -> ok
%%  end,
  groups_avatars:send_pep_msg(Server, Group, UserJID),
  send_presence([UserJID], Group, available, []),
  ok.

process_subscribe(Server, Group, UserJID, Nick, DenyUserAvatar)->
  User = jid:to_string(jid:remove_resource(UserJID)),
  case groups_members:subscribe_user(Server, Group, User, Nick) of
    not_allowed ->
      send_presence([UserJID], Group, unsubscribed, []);
    _ ->
      send_presence([UserJID], Group, subscribed, []),
      send_presence([UserJID], Group, subscribe, []),
      case DenyUserAvatar of
        true ->
          groups_members:deny_user_avatar(Server, Group, User);
        _ ->
          ok
      end,
%%      groups_avatars:request_vcard(Group, User),
      groups_avatars:request_pubsub_metadata(Group, User)
  end.

process_unsubscribe(UserJID, GroupJID, Type)->
  Server = GroupJID#jid.lserver,
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  User = jid:to_string(jid:remove_resource(UserJID)),
  GroupFJID = jid:replace_resource(GroupJID,<<"Group">>),
  Result = groups_members:delete_user(Server, Group, User),
  case Result of
    ok ->
      ejabberd_hooks:run(groups_user_left, Server,[Server, Group, User]);
    _ ->
      ok
  end,
  case Type of
    unsubscribe ->
      ejabberd_router:route(GroupFJID, UserJID, #presence{type = unsubscribed,
        id = randoms:get_string()}),
      ejabberd_router:route(GroupFJID, UserJID, #presence{type = unsubscribe,
        id = randoms:get_string()});
    _ ->
      ejabberd_router:route(GroupFJID, UserJID, #presence{type = unsubscribed,
        id = randoms:get_string()})
  end,
  ejabberd_router:route(GroupFJID, UserJID, #presence{type = unavailable,
    id = randoms:get_string()}).

check_access(Server, Group, UserJID) ->
  case groups_groups:get_info(Group, [membership, domains]) of
    [Membership, Domains] ->
      check_access(Server, Group, UserJID, Membership, Domains);
    _ ->
      error
  end.

check_access(Server, Group, UserJID, Membership, Domains) ->
  case check_domain(UserJID, Domains) of
    true ->
      User = jid:to_string(jid:remove_resource(UserJID)),
      case groups_block:is_blocked(Server, Group, User) of
        true -> not_allowed;
        _ ->
          check_membership(Server, Group, User, Membership)
      end;

    _ -> not_allowed
  end.

check_domain(_, #groups_domains{list = []}) -> true;
check_domain(UserJID, #groups_domains{list = Domains}) ->
  {_, LDomain, _} = jid:tolower(UserJID),
  lists:member(jid:from_string(LDomain), Domains);
check_domain(_, _) -> true.

check_membership(_Server, _Group, _User, open) ->
  ok;
check_membership(Server, Group, User, _) ->
  case groups_members:user_subscription(Server, User, Group) of
    not_exist -> not_allowed;
    _ -> ok
  end.
