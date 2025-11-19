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
-behavior(gen_mod).

-compile([{parse_transform, ejabberd_sql_pt}]).

-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").

%% gen_mod
-export([start/2, stop/1, depends/2, mod_options/1]).
%% Hook handlers
-export([is_allowed/2, validate_block_query/2, block/2,
  unblock/2]).
%% API
-export([is_blocked/3, block_list/2]).


%% gen_mod API
start(Host, _Opts) ->
  ejabberd_hooks:add(groupchat_block_hook, Host, ?MODULE, is_allowed, 10),
  ejabberd_hooks:add(groupchat_block_hook, Host, ?MODULE, validate_block_query, 20),
  ejabberd_hooks:add(groupchat_block_hook, Host, ?MODULE, block, 50),
  ejabberd_hooks:add(groupchat_unblock_hook, Host, ?MODULE, is_allowed, 10),
  ejabberd_hooks:add(groupchat_unblock_hook, Host, ?MODULE, unblock, 20).

stop(Host) ->
  ejabberd_hooks:delete(groupchat_block_hook, Host, ?MODULE, is_allowed, 10),
  ejabberd_hooks:delete(groupchat_block_hook, Host, ?MODULE, validate_block_query, 20),
  ejabberd_hooks:delete(groupchat_block_hook, Host, ?MODULE, block, 50),
  ejabberd_hooks:delete(groupchat_unblock_hook, Host, ?MODULE, is_allowed, 10),
  ejabberd_hooks:delete(groupchat_unblock_hook, Host, ?MODULE, unblock, 20).

depends(_Host, _Opts) -> [].

mod_options(_Opts) -> [].

%%%% Hook handlers

is_allowed(Acc, #iq{from=From, to=To}) ->
  Group = jid:to_string(jid:remove_resource(To)),
  Admin = jid:to_string(jid:remove_resource(From)),
  case mod_groups_permissions:is_permitted(<<"block-users">>,
    Admin, Group) of
    true ->
      Acc;
    _ ->
      {stop, {error, xmpp:err_not_allowed()}}
  end.

validate_block_query(_Acc, #iq{from = From, to = To, sub_els = [El]}) ->
  BlockEl = xmpp:decode(El),
  case validate_domains(BlockEl) of
    error ->
      {stop, {error, xmpp:err_bad_request()}};
    Acc ->
      Group = jid:to_string(jid:remove_resource(To)),
      Server = To#jid.lserver,
      Admin = jid:to_string(jid:remove_resource(From)),
      validate_ids(Acc, BlockEl, Server, Group, Admin)
  end.

block(Acc, #iq{to = To, from = From} = Iq)->
  Elements = Acc#groups_block.domain
    ++ Acc#groups_block.jid
    ++ Acc#groups_block.id,
  Group = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  Admin = jid:to_string(jid:remove_resource(From)),
  Kicked = lists:filtermap(fun(El) ->
    {Type, Cdata} = El,
    case Type of
      block_domain ->
        sql_block(Server, Cdata, <<"domain">>, Admin, Group),
        false;
      block_jid ->
        mod_groups_users:kick_user([Cdata], Server, Group,
          <<>>, <<>>, <<>>),
        sql_block(Server, Cdata, <<"user">>, Admin, Group),
        get_user_card(Server, Cdata, Group);
      block_id ->
        case mod_groups_users:get_user_by_id(Server, Group, Cdata) of
          none ->
            false;
          UserName ->
            mod_groups_users:kick_user([UserName], Server, Group,
              <<>>, <<>>, <<>>),
            sql_block(Server, UserName, <<"user">>, Admin, Group),
            {true, {UserName, mod_groups_users:form_user_card(UserName,Group)}}
        end;
      _ ->
        false
    end end, Elements),
  Cards = [C || {_, C} <- Kicked],
  Users = [U || {U, _} <- Kicked],
  mod_groups_system_message:users_blocked(Cards, Iq),
  ejabberd_hooks:run(groupchat_users_kicked, Server, [Server, Group, Users]),
  Acc.

unblock(_Acc, #iq{to = To, sub_els = [El]}) ->
  Group = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  D = xmpp:decode(El),
  Elements = validate(D#groups_unblock.domain) ++
    validate(D#groups_unblock.jid) ++
    D#groups_unblock.id,
  unblock(Elements, Server, Group).

%%%% API

is_blocked(Server, Group, User) ->
  {_,Domain,_} = jid:tolower(jid:from_string(User)),
  sql_is_blocked(Server, Group, User, Domain).


block_list(UserJID, GroupJID) ->
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  User = jid:to_string(jid:remove_resource(UserJID)),
  case mod_groups_permissions:is_permitted(<<"block-users">>,
    User, Group) of
    true ->
      block_list(GroupJID);
    _ ->
      {error, xmpp:err_not_allowed()}
  end.

%%%% Internal functions

block_list(GroupJID) ->
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  Server = GroupJID#jid.lserver,
  Elements = lists:map(
    fun
      ({Data, <<"user">>}) ->
        #xmlel{name = <<"jid">>, children = [{xmlcdata,Data}]};
      ({Data, Type}) ->
        #xmlel{name = Type, children = [{xmlcdata,Data}]}
    end, sql_select_blocked(Server, Group)),
  #xmlel{name = <<"query">>,
    attrs = [{<<"xmlns">>,<<"https://xabber.com/protocol/groups#block">>}],
    children = Elements}.


validate_domains(BlockEl) ->
  Domains = validate(BlockEl#groups_block.domain),
  case lists:member(error, Domains) of
    true ->
      error;
    _ ->
      #groups_block{domain = Domains}
  end.

validate_ids(Acc, BlockEl, Server, Group, Admin) ->
  UserJIDs = lists:map(
    fun({_,Cdata}) ->
      {block_jid,
        mod_groups_users:get_user_by_id(Server, Group, Cdata )}
    end, BlockEl#groups_block.id),
  case lists:member({block_jid, none}, UserJIDs) of
    false->
      NewAcc = Acc#groups_block{jid= UserJIDs},
      validate_jids(NewAcc, BlockEl, Server, Group, Admin);
    _ ->
      {stop, {error, xmpp:err_bad_request()}}
  end.

validate_jids(Acc, BlockEl, Server, Group, Admin) ->
  JIDs = validate(BlockEl#groups_block.jid),
  case lists:member(error, JIDs)  of
    true ->
      {stop, {error, xmpp:err_bad_request()}};
    _ ->
      JIDsSum = Acc#groups_block.jid ++ JIDs,
      NewAcc = Acc#groups_block{jid = JIDsSum},
      check_permissions(NewAcc, Server, Group, Admin)
  end.

check_permissions(Acc, Server, Group, Admin) ->
  JIDs = [J || {_ ,J} <- Acc#groups_block.jid],
  Domains = [D || {_ ,D} <- Acc#groups_block.domain],
  R = case lists:member(Admin, JIDs) of
        true -> error;
        _ ->
          case check_owners(JIDs ++ Domains, Server, Group) of
            false -> error;
            _ -> true
          end
      end,
  case R of
    error ->
      {stop, {error, xmpp:err_not_allowed()}};
    _ ->
      Acc
  end.

unblock([], _Server, _Group)->
  ok;
unblock([error | Tail], Server, Group)->
  unblock(Tail, Server, Group);
unblock([{block_id, ID} | Tail], Server, Group)->
  case mod_groups_users:get_user_by_id(Server, Group, ID) of
    none -> ok;
    User ->
      sql_unblock(Server, User, Group)
  end,
  unblock(Tail, Server, Group);
unblock([{_, JIDS} | Tail], Server, Group)->
  sql_unblock(Server, JIDS, Group),
  unblock(Tail, Server, Group).


get_domains(Users) ->
  lists:map(fun(User) ->
    JID = jid:from_string(User),
    JID#jid.lserver
            end, Users).

check_owners(BlockList, Server, Group) ->
  OwnerJIDs = mod_groups_users:get_owners(Server, Group),
  OwnerDomains = get_domains(OwnerJIDs),
  Sum = OwnerJIDs ++ OwnerDomains,
  BlockList == BlockList -- Sum.

validate([]) ->
  [];
validate(List) ->
  validate(List, []).

validate([], Acc) ->
  Acc;
validate([{Type, Data}|Tail], Acc) ->
  case jid:from_string(Data) of
    #jid{luser = <<>>, lserver = S} when Type == block_domain ->
      validate(Tail, [{Type, S} | Acc]);
    #jid{luser = <<>>} ->
      error;
    #jid{} = JID when Type == block_jid ->
      JIDS = jid:to_string(jid:remove_resource(JID)),
      validate(Tail, [{Type, JIDS} | Acc]);
    _ ->
      validate(Tail, [error | Acc])
  end.

get_user_card(Server, User, Group) ->
  case mod_groups_users:check_user(Server, User, Group) of
    not_exist ->
      false;
    _ ->
      Card = mod_groups_users:form_user_card(User, Group),
      {true, {User, Card}}
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
    ?SQL("select @(blocked)s,@(type)s "
    " from groupchat_block where chatgroup=%(Group)s")) of
    {selected,Items} ->
      Items;
    _ ->
      []
  end.

sql_block(Server, Blocked, Type, IssuedBy, Group) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL_INSERT(
      "groupchat_block",
      ["chatgroup=%(Group)s",
        "type=%(Type)s",
        "blocked=%(Blocked)s",
        "issued_by=%(IssuedBy)s",
        "issued_at=CURRENT_TIMESTAMP"])).


sql_unblock(Server, Blocked, Group) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_block where
         blocked=%(Blocked)s and chatgroup=%(Group)s")).
