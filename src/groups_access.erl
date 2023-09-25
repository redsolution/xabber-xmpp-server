%%%-------------------------------------------------------------------
%%% File    : groups_access.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : Groups submodule.
%%% Created : 12 Sep 2023 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%%
%%%
%%% xabberserver, Copyright (C) 2007-2024   Redsolution OÜ
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
-module(groups_access).
-author('ilya.kalashnikov@redsolution.com').
-behavior(gen_mod).
-include("logger.hrl").
-include("xmpp.hrl").

%% gen_mod
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% Hook handlers
-export([check_access/2, check_access_pre/2]).
%% API
%%-export([]).

start(Host, _Opts) ->
  ejabberd_hooks:add(groupchat_presence_subscribed_hook, Host, ?MODULE, check_access_pre, 23),
  ejabberd_hooks:add(groupchat_presence_hook, Host, ?MODULE, check_access, 25),
  ok.

stop(Host) ->
  ejabberd_hooks:delete(groupchat_presence_subscribed_hook, Host, ?MODULE, check_access_pre, 23),
  ejabberd_hooks:delete(groupchat_presence_hook, Host, ?MODULE, check_access, 25).

reload(_, _, _) -> ok.

depends(_Host, _Opts) -> [].

mod_options(_) -> [].

%% Hooks

check_access(_Acc, #presence{to = To, from = From}) ->
  Group = jid:to_string(jid:remove_resource(To)),
  UserJID = jid:remove_resource(From),
  Server = To#jid.lserver,
  check_access(Server, UserJID, Group).

check_access_pre(_Acc,{Server, UserJID, Group, _Lang}) ->
  check_access(Server, UserJID, Group).

check_access(Server, UserJID, Group) ->
  case mod_groups_chats:get_info(Group, Server) of
    {_, _, _, Membership, _, _, _, Domains, _, _} ->
      case check_access(UserJID, Group, Membership, Domains) of
        ok -> ok;
        Why -> {stop, Why}
      end;
    _ ->
      {stop, error}
  end.


%% Internal functions

check_access(UserJID, Group, Membership, Domains) ->
  case check_domain(UserJID#jid.lserver, Domains) of
    true ->
      check_membership(UserJID, Group, Membership);
    _ ->
      not_ok
  end.

check_domain(_, <<>>) -> true;
check_domain(_, []) -> true;
check_domain(UserDomain, Domains) when is_binary(Domains) ->
  List = binary:split(Domains,<<",">>,[global]),
  check_domain(UserDomain, [D || D <- List, D /= <<>>]);
check_domain(UserDomain, Domains) ->
  lists:member(UserDomain,Domains).

check_membership(UserJID, Group, Membership) ->
  case Membership of
    <<"open">> -> ok;
    _ ->
      check_if_user_invited(UserJID, Group)
  end.

check_if_user_invited(UserJID, Group) ->
  {_, Server, _} = jid:tolower(jid:from_string(Group)),
  UserB = jid:to_string(UserJID),
  case mod_groups_users:check_user_if_exist(Server, UserB, Group) of
    not_exist -> not_ok;
    _ -> ok %% todo: is the user with subscription "none" invited?
  end.
