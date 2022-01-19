%%%-------------------------------------------------------------------
%%% File    : mod_xabber_entity.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Store information about entities
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
-module(mod_xabber_entity).
-author("andrey.gagarin@redsolution.ru").
%%-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).
%% API
-export([is_exist/2, is_exist_anywhere/2, get_entity_type/2, is_group/2, is_channel/2]).

is_exist_anywhere(LUser, LServer) ->
  case ejabberd_auth:user_exists(LUser, LServer) of
    true ->
      true;
    _ ->
      is_exist(LUser, LServer)
  end.

is_exist(LUser, LServer) ->
  case get_entity_type(LUser, LServer) of
    user -> false;
    _-> true
  end.

is_group(LUser, LServer) ->
  check_entity_type(group, ejabberd_sm:get_user_info(LUser,LServer)).

is_channel(LUser, LServer) ->
  check_entity_type(channel, ejabberd_sm:get_user_info(LUser,LServer)).

get_entity_type(LUser, LServer) ->
  Ss = ejabberd_sm:get_user_info(LUser,LServer),
  case check_entity_type(group, Ss) of
    true ->
      group;
    _ ->
      case check_entity_type(channel, Ss) of
        true -> channel;
        _ -> user
      end
  end.

%% Internal API

check_entity_type(Type, Sessions) ->
  case lists:filter(fun({_R, Info}) -> proplists:get_value(Type,Info,false) end, Sessions) of
    [] ->
      false;
    _ ->
      true
  end.
