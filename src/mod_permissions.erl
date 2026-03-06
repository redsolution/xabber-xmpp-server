%%%-------------------------------------------------------------------
%%% File    : mod_permissions.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : Manage permissions.
%%% Created : 06 Oct 2025 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%%
%%%
%%% xabberserver, Copyright (C) 2007-2026   redsolution corp
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

-module(mod_permissions).
-author('ilya.kalashnikov@redsolution.com').
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").

%% gen_mod
-export([start/2, stop/1, mod_options/1, depends/2, reload/3, mod_opt_type/1]).

%% Hooks
-export([disco_features/5]).
-export([process_iq/1]).



%% gen_mod
start(Host, _Opts) ->
  register_hooks(Host),
  gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_PERMS, ?MODULE, process_iq),
  ok.

stop(Host) ->
  unregister_hooks(Host),
  gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_PERMS),
  ok.

reload(_Host, _NewOpts, _OldOpts) ->
  ok.

depends(_Host, _Opts) ->
  [].

mod_options(_Host) ->
  [].

mod_opt_type(_) ->
  fun (L) -> lists:map(fun iolist_to_binary/1, L) end.



%% IQ handlers
process_iq(#iq{from = From, to = To} = Iq) ->
  {GUser, GServer, _} = jid:tolower(To),
  case mod_xabber_entity:get_entity_type(GUser, GServer) of
    group ->
      Group = jid:to_string(jid:remove_resource(To)),
      User = jid:to_string(jid:remove_resource(From)),
      case groups_members:check_if_exist(GServer, Group, User) of
        true ->
          Result = ejabberd_hooks:run_fold(groups_permissions_query, GServer, [], [Iq]),
          make_result(Result, Iq);
        _ ->
          xmpp:make_error(Iq, xmpp:err_not_allowed())
      end;
    _ ->
      xmpp:make_error(Iq, xmpp:err_feature_not_implemented())
  end.

%% Hooks

register_hooks(Host) ->
  ejabberd_hooks:add(disco_local_features, Host, ?MODULE, disco_features, 50).

unregister_hooks(Host) ->
  ejabberd_hooks:delete(disco_local_features, Host, ?MODULE, disco_features, 50).

-spec disco_features(empty | {result, [binary()]} | {error, stanza_error()},
    jid(), jid(), binary(), binary())
      -> {result, [binary()]} | {error, stanza_error()}.
disco_features(empty, From, To, Node, Lang) ->
  disco_features({result, []}, From, To, Node, Lang);
disco_features({result, OtherFeatures}, _From, _To, <<"">>, _Lang) ->
  {result, [?NS_PERMS | OtherFeatures]};
disco_features(Acc, _From, _To, _Node, _Lang) ->
  Acc.

%% Internal

make_result({error, Error}, Iq) ->
  xmpp:make_error(Iq, Error);
make_result(Result, Iq) when is_tuple(Result) ->
  xmpp:make_iq_result(Iq, Result);
make_result(Result, Iq) when is_list(Result) ->
  R = xmpp:make_iq_result(Iq),
  R#iq{sub_els = Result};
make_result(_, Iq) ->
  xmpp:make_iq_result(Iq).

