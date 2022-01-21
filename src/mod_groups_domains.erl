%%%-------------------------------------------------------------------
%%% File    : mod_groups_domains.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Check if group chat has access by domain policy
%%% Created : 14 Aug 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_groups_domains).
-author('andrey.gagarin@redsolution.com').
-behavior(gen_mod).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).
-export([start/2, stop/1, depends/2, mod_options/1]).

%% Hook handlers
-export([domain_access/2,domain_access_pre/2]).
%% API
-export([domains/2]).

start(Host, _Opts) ->
  ejabberd_hooks:add(groupchat_presence_subscribed_hook, Host, ?MODULE, domain_access_pre, 20),
  ejabberd_hooks:add(groupchat_presence_hook, Host, ?MODULE, domain_access, 35).

stop(Host) ->
  ejabberd_hooks:delete(groupchat_presence_subscribed_hook, Host, ?MODULE, domain_access_pre, 20),
  ejabberd_hooks:delete(groupchat_presence_hook, Host, ?MODULE, domain_access, 35).

depends(_Host, _Opts) -> [].

mod_options(_Opts) -> [].

domain_access(_Acc, Presence) ->
  #presence{to = To, from = From} = Presence,
  Chat = jid:to_string(jid:remove_resource(To)),
  Domain = From#jid.lserver,
  Server = To#jid.lserver,
  case handle(domains(Server,Chat),Domain) of
    ok ->
      ok;
    _ ->
      {stop,not_ok}
  end.

domain_access_pre(_Acc,{Server,From,Chat,_Lang}) ->
  Domain = From#jid.lserver,
  case handle(domains(Server,Chat),Domain) of
    ok ->
      ok;
    _ ->
      {stop,not_ok}
  end.

handle({selected,[{<<>>}]},_Domain) ->
  ok;
handle({selected,[]},_Domain) ->
  ok;
handle({selected,Domains},Domain) ->
  [{DomainString}] = Domains,
  Splited = binary:split(DomainString,<<",">>,[global]),
  Empty = [X||X <- Splited, X == <<>>],
  DomainList = Splited -- Empty,
  case lists:member(Domain,DomainList) of
    true ->
      ok;
    _ ->
      not_ok
  end.


%%%% SQL functions

domains(Server,Chat) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(domains)s from groupchats where jid=%(Chat)s")).