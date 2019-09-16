%%%-------------------------------------------------------------------
%%% File    : mod_groupchat_default_restrictions.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Default restrinctions for group chats
%%% Created : 23 Aug 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_groupchat_default_restrictions).
-author('andrey.gagarin@redsolution.com').
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).

%% API
-export([
  set_default_rights/4,
  restrictions/2,
  set_restrictions/3
]).

restrictions(Query,Iq) ->
  #iq{to = To} = Iq,
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  Restrictions = Query#xabbergroupchat_query_rights.restriction,
  case length(Restrictions) of
    0 ->
      xmpp:err_bad_request();
    _ ->
      lists:foreach(fun(N) ->
        Name = N#xabbergroupchat_restriction.name,
        Time = N#xabbergroupchat_restriction.expires,
        set_default_rights(Server,Chat,Name,Time)
                    end, Restrictions),
      xmpp:make_iq_result(Iq)
  end.



set_default_rights(Server,Chat,Right,Time) ->
  case ?SQL_UPSERT(Server, "groupchat_default_restrictions",
    [
      "action_time=%(Time)s",
      "!right_name=%(Right)s",
      "!chatgroup=%(Chat)s"
    ]) of
    ok ->
      ok;
    _ ->
      {error, db_failure}
  end.

set_restrictions(Server,User,Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(right_name)s,@(action_time)s from groupchat_default_restrictions where chatgroup=%(Chat)s")) of
    {selected,[]} ->
      ok;
    {selected,[{}]} ->
      ok;
    {selected,Restrictions} ->
      lists:map(fun(N) ->
        {Rule,Time} = N,
        ActionTime = set_time(Time),
      mod_groupchat_restrictions:upsert_rule(Server,Chat,User,Rule,ActionTime,<<"server">>) end, Restrictions),
        ok;
    _ ->
      ok
  end.

%% Internal functions
set_time(<<"never">>) ->
  <<"1000 years">>;
set_time(<<"now">>) ->
  <<"0 years">>;
set_time(Time) ->
  Time.