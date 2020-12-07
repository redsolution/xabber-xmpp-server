%%%-------------------------------------------------------------------
%%% File    : mod_channel_rights.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Manage rights in channels
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
-module(mod_channel_rights).
-author("andrey.gagarin@redsolution.ru").


-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).

-export([get_permissions/1, get_restrictions/1, insert_rule/6, has_right/4, calculate_role/3]).


insert_rule(Server,Channel,Username,Rule,Expires,IssuedBy) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL_INSERT(
      "channel_policy",
      ["username=%(Username)s",
        "channel=%(Channel)s",
        "right_name=%(Rule)s",
        "valid_until=%(Expires)d",
        "issued_by=%(IssuedBy)s"
        ])).

get_restrictions(Server) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(name)s from channel_rights where type = 'restriction' ")) of
    {selected,[]} ->
      [];
    {selected,[{}]} ->
      [];
    {selected,Restrictions} ->
      Restrictions
  end.

get_permissions(Server) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(name)s from channel_rights where type = 'permission' ")) of
    {selected,[]} ->
      [];
    {selected,[{}]} ->
      [];
    {selected,Permissions} ->
      Permissions
  end.

has_right(Server, Channel, User, Right) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(right_name)s,@(valid_until)d from channel_policy where
    (right_name = %(Right)s or right_name = 'owner') and channel = %(Channel)s and username = %(User)s ")) of
    {selected,Permissions} when length(Permissions) > 0 ->
      check_rights(Permissions);
    _ ->
      false
  end.

check_rights(Permissions) ->
  TimeNow = now_to_timestamp(now()),
  List = lists:map(fun(Permission) ->
    {_Right, Expires} = Permission,
    case Expires of
      0 ->
        true;
      _ when Expires > TimeNow ->
        true;
      _ ->
        false
    end
                   end, Permissions),
  lists:member(true,List).

calculate_role(Server,User,Channel) ->
  case has_right(Server,Channel,User,<<"owner">>) of
    true ->
      <<"owner">>;
    _ ->
      <<"member">>
  end.

now_to_timestamp({MSec, Sec, USec}) ->
  (MSec * 1000000 + Sec) * 1000000 + USec.
