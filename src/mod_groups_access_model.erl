%%%-------------------------------------------------------------------
%%% File    : mod_groups_access_model.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Work with access model of group chat
%%% Created : 12 Jul 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_groups_access_model).
-author('andrey.gagarin@redsolution.com').
-behavior(gen_mod).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).
-export([start/2, stop/1, depends/2, mod_options/1]).
-export([check_model/3]).
%% Hook handlers
-export([model_access_handler/2]).
%% API
-export([check_if_user_invited/3,get_access_model/2, model_pre_access_handler/2]).

start(Host, _Opts) ->
  ejabberd_hooks:add(groupchat_presence_subscribed_hook, Host, ?MODULE, model_pre_access_handler, 23),
  ejabberd_hooks:add(groupchat_presence_hook, Host, ?MODULE, model_access_handler, 25).

stop(Host) ->
  ejabberd_hooks:delete(groupchat_presence_subscribed_hook, Host, ?MODULE, model_pre_access_handler, 23),
  ejabberd_hooks:delete(groupchat_presence_hook, Host, ?MODULE, model_access_handler, 25).

depends(_Host, _Opts) -> [].

mod_options(_) -> [].

model_access_handler(_Acc, Presence) ->
  #presence{to = To, from = From} = Presence,
  Chat = jid:to_string(jid:remove_resource(To)),
  User = jid:to_string(jid:remove_resource(From)),
  Server = To#jid.lserver,
  check_model(Server,Chat,User).

check_model(Server,Chat,User) ->
 case get_access_model(Server,Chat) of
    <<"open">> ->
      ok;
    <<"member-only">> ->
      check_if_user_invited(Server,User,Chat);
    _ ->
      {stop,error}
  end.

model_pre_access_handler(_Acc,{Server,UserJID,Chat,_Lang}) ->
  User = jid:to_string(jid:remove_resource(UserJID)),
  check_model(Server,Chat,User).

%% Internal functions

%% SQL functions
check_if_user_invited(Server,User,Chat) ->
case  ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_users where chatgroup=%(Chat)s and username=%(User)s")) of
  {selected,[]} ->
    {stop,not_ok};
  {selected,[{_Info}]} ->
    ok;
  _ ->
    {stop,error}
end.


get_access_model(Server,Chat) ->
  {selected,[{Model}]} =  ejabberd_sql:sql_query(
  Server,
  ?SQL("select @(model)s from groupchats where jid=%(Chat)s")),
  Model.