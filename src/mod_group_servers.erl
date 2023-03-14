%%%-------------------------------------------------------------------
%%% File    : mod_group_servers.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : Discovery of other group servers.
%%% Created : 14 March 2023 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%%
%%%
%%% xabberserver, Copyright (C) 2007-2023   Redsolution OÜ
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
-module(mod_group_servers).
-author("ilya.kalashnikov@redsolution.com").
-behaviour(gen_mod).
-include("xmpp.hrl").

%% API
-export([start/2, stop/1, mod_options/1, depends/2, reload/3, mod_opt_type/1]).
%% Hooks
-export([get_local_items/5]).


start(Host, _Opts) ->
  ejabberd_hooks:add(disco_local_items, Host, ?MODULE,
    get_local_items, 50),
  ok.

stop(Host) ->
  ejabberd_hooks:delete(disco_local_items, Host, ?MODULE,
    get_local_items, 50).

reload(_Host, _NewOpts, _OldOpts) ->
  ok.

depends(_Host, _Opts) ->
  [].

mod_options(_Host) ->
  [{servers, []}].

mod_opt_type(servers) ->
  fun (L) -> lists:map(fun iolist_to_binary/1, L) end.

get_xabber_group_servers(LServer) ->
  Servers = gen_mod:get_module_opt(LServer, ?MODULE, servers),
  lists:map(fun(JID) ->
    #disco_item{jid = jid:make(JID),
      node = ?NS_GROUPCHAT,
      name = <<"Group Service">>} end, Servers).

get_local_items(Acc, _From, #jid{lserver = LServer} = _To,
    <<"">>, _Lang) ->
  Items = case Acc of
            {result, Its} -> Its;
            empty -> []
          end,
  D = get_xabber_group_servers(LServer),
  {result,Items ++ D};
get_local_items(Acc, _From, _To, _Node, _Lang) ->
  Acc.
