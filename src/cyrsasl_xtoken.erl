%%%-------------------------------------------------------------------
%%% File    : cyrsasl_xtoken.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : X-Token SASL mechanism
%%% Created : 10 Sep 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(cyrsasl_xtoken).

-author('andrey.gagarin@redsolution.com').

-export([start/1, stop/0, mech_new/4, mech_step/2, parse/1, format_error/1]).

-behaviour(cyrsasl).
-include("logger.hrl").
-record(state, {host}).
-type error_reason() :: parser_failed | not_authorized.
-export_type([error_reason/0]).

start(_Opts) ->
  cyrsasl:register_mechanism(<<"X-TOKEN">>, ?MODULE, plain).

stop() -> ok.

-spec format_error(error_reason()) -> {atom(), binary()}.
format_error(parser_failed) ->
  {'bad-protocol', <<"Response decoding failed">>};
format_error(not_authorized) ->
  {'not-authorized', <<"Invalid token">>}.

mech_new(Host, _GetPassword, _CheckPassword, _CheckPasswordDigest) ->
  {ok, #state{host = Host}}.

mech_step(State, ClientIn) ->
  case prepare(ClientIn) of
    [AuthzId, User, Token] ->
      case mod_x_auth_token:check_token(
        User, State#state.host, Token) of
        true ->
          {ok,
            [{username, User}, {authzid, AuthzId}, {token, Token},
              {auth_module, mod_x_auth_token}]};
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
    %% login@domain<NUL>login<NUL>pwd
    [AuthzId, User, Token] ->
      case parse_domain(AuthzId) of
        %% login@domain<NUL>login<NUL>pwd
        [AuthzUser, _Domain] -> [AuthzUser, User, Token];
        %% login<NUL>login<NUL>pwd
        [AuthzUser] -> [AuthzUser, User, Token]
      end;
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