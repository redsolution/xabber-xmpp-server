%%%-------------------------------------------------------------------
%%% File    : cyrsasl_devices_ocra.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : DEVICES-OCRA SASL mechanism
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

-module(cyrsasl_devices_ocra).
-author('ilya.kalashnikov@redsolution.com').
-behaviour(cyrsasl).

-include("logger.hrl").

-export([start/1, stop/0, mech_new/4, mech_step/2, format_error/1]).

-define(OCRA_SUITE, <<"OCRA-1:HOTP-SHA256-0:C-QA10">>).

-record(state, {step, host, username, device_id, secret, count, challenge}).
-type error_reason() :: parser_failed | not_authorized | expired.
-export_type([error_reason/0]).

start(_Opts) ->
  cyrsasl:register_mechanism(<<"DEVICES-OCRA">>, ?MODULE, plain).

stop() -> ok.

-spec format_error(error_reason()) -> {atom(), binary()}.
format_error(device_revoked) ->
  {'account-disabled', <<"Device access revoked">>};
format_error(expired) ->
  {'credentials-expired', <<"Device token expired">>};
format_error(parser_failed) ->
  {'bad-protocol', <<"Response decoding failed">>};
format_error(not_authorized) ->
  {'not-authorized', <<"Invalid password">>}.



mech_new(Host, _GetPassword, _CheckPassword, _CheckPasswordDigest) ->
  {ok, #state{step = 1, host = Host}}.

mech_step(#state{step = 1, host = Host}, ClientIn) ->
  case binary:split(ClientIn, <<0>>, [global]) of
    [_, Username1, DeviceID, OCRASuite, CQ, ValidationKeyB64] ->
      ValidationKey = base64_decode(ValidationKeyB64),
      Username = prepare(Username1),
      case process_initial_resp(Username, Host, DeviceID, OCRASuite,
        CQ, ValidationKey) of
        {ok, Count, Secret, SQ, ServerMessage} when Count >=0 ->
          NewState = #state{step = 2, host = Host, username = Username,
            device_id = DeviceID, secret = Secret, count = Count, challenge = SQ},
          {continue, ServerMessage, NewState};
        parser_failed ->
          {error, parser_failed};
        expired ->
          {error, expired, Username};
        device_revoked ->
          {error, device_revoked, Username};
        _ ->
          {error, not_authorized, Username}
      end;
    _ ->
      {error, parser_failed}
  end;

mech_step(#state{step = 2, host = Host, username = Username, device_id = DevID,
  count = Count, secret = Secret, challenge = SQ}, ClientIn) ->
  case base64_decode(ClientIn) of
    error ->
      {error, parser_failed};
    Token ->
      Options = [{last,Count}, {trials,10}, {return_interval, true}],
      case hotp:valid_ocra(Token, Secret, ?OCRA_SUITE, SQ, Options) of
        {true, NewCount} ->
          mod_devices:set_count(Username, Host, DevID, NewCount),
          {ok,
            [{username, Username}, {authzid, Username}, {device_id, DevID},
              {auth_module, mod_devices}]};
        _ ->
          block_device(Username, Host, DevID),
          {error, not_authorized, Username}
      end
  end.

process_initial_resp(_Username, _Server, _DevID, _Suite, _CQ, error) ->
  parser_failed;
process_initial_resp(Username, Server, DevID, Suite, CQ, VKey) ->
  Check = ejabberd_auth:user_exists(Username, Server),
  process_initial_resp(Check, Username, Server, DevID, Suite, CQ, VKey).

process_initial_resp(false, _, _, _, _, _, _) ->
  not_authorized;
process_initial_resp(true, Username, Server, DevID, Suite, CQ, ValidationKey) ->
  case check_suite(Suite) of
    true ->
      case mod_devices:select_secret(Server, jid:make(Username, Server), DevID) of
        {ESecretB64, Count, Expire, ValidatorB64} ->
          [ESecret, Validator] = [base64:decode(X) || X <- [ESecretB64, ValidatorB64]],
          case make_challenge_resp(ESecret, Validator ,Expire, Suite, CQ, ValidationKey) of
            {ok, Secret, SQ, ServerMsg} ->
              {ok, Count, Secret, SQ, ServerMsg};
            Err ->
              Err
          end;
        {error, not_found} ->
          device_revoked;
        _ ->
          not_authorized
      end;
    _ ->
      parser_failed
  end.

block_device(Username, Host, DevID) ->
  mod_devices:set_count(Username, Host, DevID, -9999).

check_suite(Suite)->
  case hotp:parse_suite(Suite) of
    {ok, SuiteOpts} ->
      Count = proplists:get_value(di_c, SuiteOpts, false),
      PH = proplists:get_value(di_ph, SuiteOpts, false),
      SL = proplists:get_value(di_sl, SuiteOpts, false),
      case {Count, PH, SL} of
        {false, false, false} -> true;
        _ -> false
      end;
    _ -> false
  end.

make_challenge_resp(_ESecret, _Validator, _Expire, _Suite, _CQ, <<>>) ->
  parser_failed;
make_challenge_resp(ESecret, Validator, Expire, Suite, CQ, ValidationKey) ->
  case mod_devices:validate_device(ESecret, Validator,
    ValidationKey, Expire) of
    {ok, Secret} ->
      SecretB64 = base64:encode(Secret),
      SrvSuite = ?OCRA_SUITE,
      SQ = hotp:ocra_challenge(SrvSuite),
      Resp = hotp:ocra(SecretB64, Suite, undefined, CQ),
      Resp64 = base64:encode(Resp),
      {ok, SecretB64, SQ, <<Resp64/binary,0,SrvSuite/binary,0,SQ/binary>>};
    expired ->
      expired;
    _ ->
      not_authorized
  end.

prepare(Username) ->
  case parse_domain(Username) of
    [User, _Domain] -> User;
    [User] -> User
  end.

parse_domain(S) -> parse_domain1(binary_to_list(S), "", []).

parse_domain1([$@ | Cs], S, T) ->
  parse_domain1(Cs, "", [list_to_binary(lists:reverse(S)) | T]);
parse_domain1([C | Cs], S, T) ->
  parse_domain1(Cs, [C | S], T);
parse_domain1([], S, T) ->
  lists:reverse([list_to_binary(lists:reverse(S)) | T]).

base64_decode(B) ->
  try
      base64:decode(B)
  catch
      _:_  -> error
  end.
