%%%-------------------------------------------------------------------
%%% File    : mod_disco_urls.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : Web services discovery.
%%% Created : 14 March 2022 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
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
-module(mod_disco_urls).
-author("ilya.kalashnikov@redsolution.com").
-behaviour(gen_mod).
-include("xmpp.hrl").

%% Configuration.
%% Add the following items to the configuration:
%%   - "service_id": "https://service.domain.com/api/"
%% In disco response, the "ServiceID" will be used as extension
%% of namespace "urn:xabber:http:url" in attribute 'var':
%%    "urn:xabber:http:url:service_id"

%% API
-export([start/2, stop/1, mod_options/1, depends/2, reload/3, mod_opt_type/1]).
%% Hooks
-export([disco_info/5]).


start(Host, _Opts) ->
  ejabberd_hooks:add(disco_info, Host, ?MODULE, disco_info, 110).

stop(Host) ->
  ejabberd_hooks:delete(disco_info, Host, ?MODULE, disco_info, 110).

reload(_Host, _NewOpts, _OldOpts) -> ok.

depends(_Host, _Opts) -> [].

mod_options(_Host) -> [{items, []}].

mod_opt_type(items) ->
  fun(L) -> [{iolist_to_binary(J), iolist_to_binary(U)} || [{J, U}] <- L] end.


-spec disco_info([xdata()], binary(), module(), binary(), binary()) -> [xdata()];
    ([xdata()], jid(), jid(), binary(), binary()) -> [xdata()].
disco_info(Acc, Host, Mod, Node, _Lang) when is_atom(Mod), Node == <<"">> ->
  Acc ++ [#xdata{type = result,
    fields = [#xdata_field{type = hidden,
      var = <<"FORM_TYPE">>,
      values = [<<"urn:xabber:http:url">>]}
      | get_fields(Host)]}];
disco_info(Acc, _, _, _Node, _) -> Acc.

get_fields(Host) ->
  Items = gen_mod:get_module_opt(Host, ?MODULE, items),
  [#xdata_field{var = <<"urn:xabber:http:url:", ID/binary>>,
    values = [URL], type = 'text-single'} || {ID, URL} <- Items].
