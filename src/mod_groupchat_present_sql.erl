%%%-------------------------------------------------------------------
%%% File    : mod_groupchat_present_sql.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Watch for online activity in group chats
%%% Created : 05 Oct 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_groupchat_present_sql).
-author('andrey.gagarin@redsolution.com').
-compile([{parse_transform, ejabberd_sql_pt}]).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("ejabberd_sql_pt.hrl").
%% API
-export([
  change_present_state/4,
  flush_present_state/4,
  count_users_online/2
]).

change_present_state(Server,Chat,Username,Resource) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL_INSERT(
      "groupchat_present",
      ["username=%(Username)s",
        "chatgroup=%(Chat)s",
        "resource=%(Resource)s"
      ])).

flush_present_state(Server,Chat,Username,Resource) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_present
  where username=%(Username)s and chatgroup=%(Chat)s and resource=%(Resource)s")).

count_users_online(Server,Chat) ->
  ejabberd_sql:sql_query(
    Server,
    [<<"select count(distinct username) from groupchat_present where chatgroup= '">>
      ,Chat,<<"';">>
    ]
  ).