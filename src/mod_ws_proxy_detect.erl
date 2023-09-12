%%%-------------------------------------------------------------------
%%% File    : mod_ws_proxy_detect.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : WebSocket proxy detection.
%%% Created : 8 Sep 2023 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
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
-module(mod_ws_proxy_detect).
-author("ilya.kalashnikov@redsolution.com").
-behaviour(gen_mod).

-include("xmpp.hrl").
-include("logger.hrl").

%% API
-export([start/2, stop/1, mod_options/1, depends/2, reload/3]).
%% Hooks
-export([
  c2s_unauthenticated_packet/2,
  stream_feature_register/2]).

-define(NS_WS_PROXY,  <<"urn:xabber:ws:proxy">>).

start(Host, _Opts) ->
  ejabberd_hooks:add(c2s_unauthenticated_packet, Host, ?MODULE,
    c2s_unauthenticated_packet, 70),
  ejabberd_hooks:add(c2s_pre_auth_features, Host, ?MODULE,
    stream_feature_register, 50),
  ok.

stop(Host) ->
  ejabberd_hooks:delete(c2s_unauthenticated_packet, Host, ?MODULE,
    c2s_unauthenticated_packet, 70),
  ejabberd_hooks:delete(c2s_pre_auth_features, Host,
    ?MODULE, stream_feature_register, 50).

reload(_Host, _NewOpts, _OldOpts) ->
  ok.

depends(_Host, _Opts) ->
  [].

mod_options(_Host) ->
  [].

stream_feature_register(Acc, _Host) ->
  [#xmlel{name = <<"proxy">>, attrs = [{<<"xmlns">>, ?NS_WS_PROXY}]}|Acc].

c2s_unauthenticated_packet(State, #iq{type = set,
  sub_els = [#xmlel{name = <<"proxy">>, attrs = Attrs}]}) ->
  case xmpp_codec:get_attr(<<"xmlns">>, Attrs, false) of
    ?NS_WS_PROXY ->
      SrcIP = case xmpp_codec:get_attr(<<"src_ip">>, Attrs, false) of
                false -> false;
                Bin ->
                  case inet:parse_address(binary_to_list(Bin)) of
                    {ok, V} -> V;
                    _ -> false
                  end
              end,
      SrcPort = try
                  xmpp_codec:get_attr(<<"src_port">>, Attrs, <<>>)
                catch _:_ ->
                  false
                end,
      if
        not SrcIP; not SrcPort -> {stop, State};
        true -> {stop, State#{forwarded_for => {SrcIP, SrcPort}}}
      end;
    _ ->
      State
  end;

c2s_unauthenticated_packet(State, _) ->
  State.
