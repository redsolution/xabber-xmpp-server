%%%-------------------------------------------------------------------
%%% File    : mod_groups_block.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : Manage blocklists.
%%% Created : 09 Dec 2024 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
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

-module(mod_groups_block).
-author('ilya.kalashnikov@redsolution.com').

-compile([{parse_transform, ejabberd_sql_pt}]).

-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").


%% API
-export([is_blocked/3, block_list/3, block/4, unblock/4, kick/4]).


%%%% API

block(Server, Group, Admin, JIDs) ->
  case mod_groups_users:is_permitted(Server, Group, Admin,
    block_user, false, []) of
    true ->
      do_block(Server, Group, Admin,
        validate_jids(Server, Group,JIDs));
    _ ->
      {error, xmpp:err_not_allowed()}
  end.

unblock(Server, Group, Admin, JID) ->
  case mod_groups_users:is_permitted(Server, Group, Admin,
    block_user, false, []) of
    true ->
      do_unblock(Server, Group, JID);
    _ ->
      {error, xmpp:err_not_allowed()}
  end.
is_blocked(Server, Group, User) ->
  {_,Domain,_} = jid:tolower(jid:from_string(User)),
  sql_is_blocked(Server, Group, User, Domain).


block_list(Server, Group, User) ->
  case mod_groups_users:is_permitted(Server, Group, User,
    block_user, false, []) of
    true ->
      block_list(Server, Group);
    _ ->
      {error, xmpp:err_not_allowed()}
  end.

kick(Server, Group, Admin, JID) ->
  case mod_groups_users:is_permitted(Server, Group, Admin,
    kick_user, false, []) of
    true ->
      JIDS = validate_jid(Server, Group, JID),
      do_kick(Server, Group, Admin, JIDS);
    _ ->
      {error, xmpp:err_not_allowed()}
  end.

%%%% Internal functions

block_list(Server, Group) ->
  Items = lists:map(fun({Data}) ->
    jid:from_string(Data)
                    end,
    sql_select_blocked(Server, Group)),
  #groups_block{jids = Items}.

do_block(_Server, _Group, _Admin, false) ->
  {error, xmpp:err_not_allowed()};
do_block(_Server, _Group, _Admin, []) ->
  ok;
do_block(Server, Group, Admin, [JIDS | Tail]) ->
  sql_block(Server, Group, JIDS, Admin),
  block(Server, Group, Admin, Tail).


do_unblock(Server, Group, JID) ->
  JIDS = jid:to_string(JID),
  sql_unblock(Server, Group, JIDS),
  ok.

do_kick(_Server, _Group, _Admin, false) ->
  {error, xmpp:err_not_allowed()};
do_kick(Server, Group, _Admin, User) ->
  mod_groups_users:kick_user(Server, Group, User),
  ok.

validate_jids(Server, Group, JIDs) ->
  BareJIDs = [jid:remove_resource(J) || J <- JIDs],
  Owners = [jid:from_string(O) || O <-
    mod_groups_users:get_owners(Server, Group)],
  case BareJIDs -- Owners of
    BareJIDs -> [jid:to_string(I) || I <- BareJIDs];
    _ -> false
  end.

validate_jid(Server, Group, JID)  ->
  JIDS = jid:to_string(jid:remove_resource(JID)),
  case mod_groups_users:user_role(Server, JIDS, Group) of
    <<"member">> -> JIDS;
    _ -> false
  end.


%%%% SQL functions

sql_is_blocked(Server, Group, User, Domain) ->
  case  ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(1)d from groupchat_block "
    " where chatgroup=%(Group)s and "
    " (blocked=%(User)s or blocked=%(Domain)s)")) of
    {selected,[]} ->
      false;
    _ ->
      true
  end.

sql_select_blocked(Server, Group) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(blocked)s "
    " from groupchat_block where chatgroup=%(Group)s")) of
    {selected, Items} -> Items;
    _ -> []
  end.

sql_block(Server, Group, Blocked, IssuedBy) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL_INSERT(
      "groupchat_block",
      ["chatgroup=%(Group)s",
        "blocked=%(Blocked)s",
        "issued_by=%(IssuedBy)s",
        "issued_at=CURRENT_TIMESTAMP"])).


sql_unblock(Server, Group, Blocked) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_block where
         blocked=%(Blocked)s and chatgroup=%(Group)s")).
