%%%-------------------------------------------------------------------
%%% File    : cyrsasl_hotp.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : HOTP SASL mechanism
%%% Created : 9 Nov 2021 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%%
%%%
%%% xabberserver, Copyright (C) 2007-2021   Redsolution OÜ
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

-module(cyrsasl_hotp).

-author('ilya.kalashnikov@redsolution.com').

-export([start/1, stop/0, mech_new/4, mech_step/2, parse/1, format_error/1]).

-behaviour(cyrsasl).
-include("logger.hrl").
-record(state, {host}).
-type error_reason() :: parser_failed | not_authorized | expired.
-export_type([error_reason/0]).

start(_Opts) ->
  cyrsasl:register_mechanism(<<"HOTP">>, ?MODULE, plain).

stop() -> ok.

-spec format_error(error_reason()) -> {atom(), binary()}.
format_error(expired) ->
  {'credentials-expired', <<"Device token expired">>};
format_error(parser_failed) ->
  {'bad-protocol', <<"Response decoding failed">>};
format_error(not_authorized) ->
  {'not-authorized', <<"Invalid password">>}.



mech_new(Host, _GetPassword, _CheckPassword, _CheckPasswordDigest) ->
  {ok, #state{host = Host}}.

mech_step(State, ClientIn) ->
  case prepare(ClientIn) of
    [AuthzId, User, Password] ->
      Server = State#state.host,
      case mod_devices:check_token(User, Server, Password) of
        {ok, {DeviceID, NewCount}} ->
          mod_devices:set_count(User, Server, DeviceID, NewCount),
          {ok,
            [{username, User}, {authzid, AuthzId}, {device_id, DeviceID}, {auth_module, mod_devices}]};
        expared ->
          {error, expired, User};
        _ ->
          {error, not_authorized, User}
      end;
    _ -> {error, parser_failed}
  end.

prepare(ClientIn) ->
  case parse(ClientIn) of
    [<<"">>, UserMaybeDomain, Token] ->
      case parse_domain(UserMaybeDomain) of
        %% <NUL>login@domain<NUL>pwd
        [User, _Domain] -> [User, User, Token];
        %% <NUL>login<NUL>pwd
        [User] -> [User, User, Token]
      end;
    [<<"">>, User, Token, Count] ->
      [User, User, Token, Count];
    _ -> error
  end.

parse(S) -> parse1(binary_to_list(S), "", []).

parse1([0 | Cs], S, T) ->
  parse1(Cs, "", [list_to_binary(lists:reverse(S)) | T]);
parse1([C | Cs], S, T) -> parse1(Cs, [C | S], T);
%parse1([], [], T) ->
%    lists:reverse(T);
parse1([], S, T) ->
  lists:reverse([list_to_binary(lists:reverse(S)) | T]).

parse_domain(S) -> parse_domain1(binary_to_list(S), "", []).

parse_domain1([$@ | Cs], S, T) ->
  parse_domain1(Cs, "", [list_to_binary(lists:reverse(S)) | T]);
parse_domain1([C | Cs], S, T) ->
  parse_domain1(Cs, [C | S], T);
parse_domain1([], S, T) ->
  lists:reverse([list_to_binary(lists:reverse(S)) | T]).