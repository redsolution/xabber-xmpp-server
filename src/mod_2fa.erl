%%%-------------------------------------------------------------------
%%% File    : mod_2fa.erl
%%% Purpose : TOTP two-factor authentication for XEP-DEVICES
%%%
%%% Hooks into the wait_for_bind phase. After password auth (PLAIN/SCRAM),
%%% if the user has 2FA enabled, device registration and bind are blocked
%%% until a valid TOTP code is submitted via IQ.
%%%
%%% Also provides IQ handlers for 2FA enrollment:
%%%   - setup:   generate TOTP secret, return to client
%%%   - confirm: verify code, enable 2FA
%%%   - disable: turn off 2FA
%%%   - status:  check if 2FA is enabled
%%%
%%% DEVICES-OCRA sessions bypass 2FA entirely (device already trusted).
%%%
%%% Install:
%%%   1. Copy this file to src/ in xabber-xmpp-server
%%%   2. Run the SQL migration (user_totp table)
%%%   3. Add mod_2fa: {} to modules in ejabberd.yml
%%%   4. Rebuild
%%%-------------------------------------------------------------------

-module(mod_2fa).
-author('xabber-2factor').
-behavior(gen_mod).
-compile([{parse_transform, ejabberd_sql_pt}]).

%% gen_mod
-export([start/2, stop/1, depends/2, mod_options/1]).
%% Hooks
-export([c2s_handle_recv/3, c2s_post_auth_features/2]).
%% IQ handler (post-bind enrollment)
-export([process_local_iq/1, decode_iq_subel/1]).

-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").

-define(NS_2FA, <<"https://xabber.com/protocol/devices#2fa">>).
-define(MAX_ATTEMPTS, 3).

%% TOTP parameters (Google Authenticator compatible)
-define(TOTP_DIGITS, 6).
-define(TOTP_PERIOD, 30).
-define(TOTP_WINDOW, 1).  %% +/- 1 step

start(Host, _Opts) ->
  ejabberd_hooks:add(c2s_handle_recv, Host, ?MODULE, c2s_handle_recv, 52),
  ejabberd_hooks:add(c2s_post_auth_features, Host, ?MODULE,
    c2s_post_auth_features, 49),
  gen_iq_handler:add_iq_handler(ejabberd_local, Host,
    ?NS_2FA, ?MODULE, process_local_iq),
  ok.

stop(Host) ->
  ejabberd_hooks:delete(c2s_handle_recv, Host, ?MODULE, c2s_handle_recv, 52),
  ejabberd_hooks:delete(c2s_post_auth_features, Host, ?MODULE,
    c2s_post_auth_features, 49),
  gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_2FA),
  ok.

depends(_Host, _Opts) -> [].
mod_options(_Host) -> [].

%%====================================================================
%% IQ handler: 2FA enrollment (post-bind, via gen_iq_handler)
%%====================================================================

%% Prevent gen_iq_handler from re-decoding our custom namespace elements.
%% Without this, it calls xmpp:decode(El) which fails on unknown namespaces.
decode_iq_subel(El) -> El.

process_local_iq(#iq{type = get, from = #jid{luser = User, lserver = LServer} = From,
                     to = To, sub_els = SubEls} = IQ) ->
  ?INFO_MSG("2FA: process_local_iq GET from ~s@~s", [User, LServer]),
  case find_xmlel(<<"status">>, ?NS_2FA, SubEls) of
    false ->
      xmpp:make_error(IQ, xmpp:err_bad_request());
    _ ->
      Enabled = has_totp(User, LServer),
      StatusEl = #xmlel{name = <<"status">>,
        attrs = [{<<"xmlns">>, ?NS_2FA}],
        children = [{xmlcdata, atom_to_binary(Enabled, utf8)}]},
      IQ#iq{type = result, from = To, to = From, sub_els = [StatusEl]}
  end;

process_local_iq(#iq{type = set, from = #jid{luser = User, lserver = LServer} = From,
                     to = To, sub_els = SubEls} = IQ0) ->
  ?INFO_MSG("2FA: process_local_iq SET from ~s@~s", [User, LServer]),
  IQ = IQ0#iq{from = To, to = From},
  case {find_xmlel(<<"setup">>, ?NS_2FA, SubEls),
        find_xmlel(<<"confirm">>, ?NS_2FA, SubEls),
        find_xmlel(<<"disable">>, ?NS_2FA, SubEls)} of
    {false, false, false} ->
      xmpp:make_error(IQ, xmpp:err_bad_request());
    {_, false, false} ->
      handle_setup(IQ, User, LServer);
    {false, ConfirmEl, false} ->
      handle_confirm(IQ, User, LServer, ConfirmEl);
    {false, false, _} ->
      handle_disable(IQ, User, LServer);
    _ ->
      xmpp:make_error(IQ, xmpp:err_bad_request())
  end;

process_local_iq(IQ) ->
  ?WARNING_MSG("2FA: process_local_iq unhandled: ~p", [IQ]),
  xmpp:make_error(IQ, xmpp:err_not_allowed()).

%%====================================================================
%% Handle setup: generate secret, store (disabled), return to client
%%====================================================================

handle_setup(IQ, User, LServer) ->
  Secret = generate_base32_secret(20),
  JID = jid:to_string(jid:make(User, LServer)),
  URI = <<"otpauth://totp/", User/binary, "@", LServer/binary,
          "?secret=", Secret/binary, "&issuer=xabber&digits=6&period=30">>,
  case store_totp_secret(JID, Secret, LServer) of
    ok ->
      ?INFO_MSG("2FA: Setup initiated for ~s", [JID]),
      SecretEl = #xmlel{name = <<"secret">>,
        attrs = [{<<"xmlns">>, ?NS_2FA}],
        children = [{xmlcdata, Secret}]},
      UriEl = #xmlel{name = <<"uri">>,
        attrs = [{<<"xmlns">>, ?NS_2FA}],
        children = [{xmlcdata, URI}]},
      SetupEl = #xmlel{name = <<"setup">>,
        attrs = [{<<"xmlns">>, ?NS_2FA}],
        children = [SecretEl, UriEl]},
      IQ#iq{type = result, sub_els = [SetupEl]};
    _Error ->
      ?ERROR_MSG("2FA: Failed to store secret for ~s", [JID]),
      xmpp:make_error(IQ,
        xmpp:err_internal_server_error(<<"Failed to setup 2FA">>, <<"en">>))
  end.

%%====================================================================
%% Handle confirm: verify code, enable 2FA
%%====================================================================

handle_confirm(IQ, User, LServer, ConfirmEl) ->
  Code = get_xmlel_cdata_child(<<"code">>, ConfirmEl),
  JID = jid:to_string(jid:make(User, LServer)),
  case Code of
    <<>> ->
      xmpp:make_error(IQ, xmpp:err_bad_request(<<"Missing code">>, <<"en">>));
    _ ->
      case get_totp_secret_any(User, LServer) of
        {ok, Secret} ->
          case verify_totp(Secret, Code) of
            true ->
              case enable_totp(JID, LServer) of
                ok ->
                  ?INFO_MSG("2FA: Enabled for ~s", [JID]),
                  ConfirmedEl2 = #xmlel{name = <<"confirmed">>,
                    attrs = [{<<"xmlns">>, ?NS_2FA}]},
                  IQ#iq{type = result, sub_els = [ConfirmedEl2]};
                _ ->
                  xmpp:make_error(IQ, xmpp:err_internal_server_error())
              end;
            false ->
              ?WARNING_MSG("2FA: Confirm failed for ~s (wrong code)", [JID]),
              xmpp:make_error(IQ,
                xmpp:err_not_authorized(<<"Invalid TOTP code">>, <<"en">>))
          end;
        not_found ->
          xmpp:make_error(IQ,
            xmpp:err_item_not_found(<<"No 2FA setup pending">>, <<"en">>))
      end
  end.

%%====================================================================
%% Handle disable: remove 2FA
%%====================================================================

handle_disable(IQ, User, LServer) ->
  JID = jid:to_string(jid:make(User, LServer)),
  case delete_totp(JID, LServer) of
    ok ->
      ?INFO_MSG("2FA: Disabled for ~s", [JID]),
      DisabledEl = #xmlel{name = <<"disabled">>,
        attrs = [{<<"xmlns">>, ?NS_2FA}]},
      IQ#iq{type = result, sub_els = [DisabledEl]};
    _ ->
      xmpp:make_error(IQ, xmpp:err_internal_server_error())
  end.

%%====================================================================
%% Hook: advertise <totp-required/> in post-auth stream features
%%====================================================================

c2s_post_auth_features(Acc, Host) ->
  case gen_mod:is_loaded(Host, ?MODULE) of
    true -> Acc;
    false -> Acc
  end.

%%====================================================================
%% Hook: intercept IQs during wait_for_bind
%%====================================================================

c2s_handle_recv(#{stream_state := wait_for_bind} = State, _, #iq{type = set} = IQ) ->
  case is_totp_verify_iq(IQ) of
    {true, Code} ->
      handle_totp_verify(State, IQ, Code);
    false ->
      maybe_block_if_totp_required(State, IQ)
  end;
c2s_handle_recv(State, _, _) ->
  State.

%%====================================================================
%% TOTP verification (wait_for_bind phase)
%%====================================================================

handle_totp_verify(State, IQ, Code) ->
  #{user := User, lserver := LServer} = State,
  Attempts = maps:get(totp_attempts, State, 0),
  case get_totp_secret(User, LServer) of
    {ok, Secret} ->
      case verify_totp(Secret, Code) of
        true ->
          ?INFO_MSG("2FA: TOTP verified for ~s@~s", [User, LServer]),
          xmpp_stream_in:send(State,
            make_totp_result(IQ)),
          {stop, State#{totp_verified => true, totp_attempts => 0}};
        false ->
          NewAttempts = Attempts + 1,
          Remaining = ?MAX_ATTEMPTS - NewAttempts,
          ?WARNING_MSG("2FA: TOTP failed for ~s@~s (attempt ~p/~p)",
            [User, LServer, NewAttempts, ?MAX_ATTEMPTS]),
          if
            NewAttempts >= ?MAX_ATTEMPTS ->
              Err = xmpp:make_error(IQ,
                xmpp:err_not_authorized(
                  <<"TOTP verification failed. No attempts remaining.">>,
                  <<"en">>)),
              xmpp_stream_in:send_error(State, IQ, Err),
              {stop, State#{stream_state => disconnected}};
            true ->
              xmpp_stream_in:send(State,
                make_totp_error(IQ, Remaining)),
              {stop, State#{totp_attempts => NewAttempts}}
          end
      end;
    not_found ->
      xmpp_stream_in:send(State,
        make_totp_result(IQ)),
      {stop, State#{totp_verified => true}}
  end.

%%====================================================================
%% Block device registration / bind if TOTP not yet verified
%%====================================================================

maybe_block_if_totp_required(State, IQ) ->
  #{user := User, lserver := LServer} = State,
  AuthModule = maps:get(auth_module, State, undefined),
  case AuthModule of
    mod_devices ->
      State;
    _ ->
      TotpVerified = maps:get(totp_verified, State, false),
      case {TotpVerified, has_totp(User, LServer)} of
        {true, _} ->
          State;
        {false, true} ->
          IsRegister = is_device_register_iq(IQ),
          IsBind = xmpp:has_subtag(IQ, #bind{}),
          if
            IsRegister orelse IsBind ->
              Txt = <<"TOTP verification required.">>,
              Err = xmpp:make_error(IQ,
                xmpp:err_not_allowed(Txt, <<"en">>)),
              xmpp_stream_in:send_error(State, IQ, Err),
              {stop, State};
            true ->
              State
          end;
        {false, false} ->
          State
      end
  end.

%%====================================================================
%% TOTP computation (RFC 6238)
%%====================================================================

verify_totp(SecretB32, Code) when is_binary(Code) ->
  case base32_decode(SecretB32) of
    error -> false;
    Secret ->
      Now = erlang:system_time(second),
      TimeStep = Now div ?TOTP_PERIOD,
      lists:any(
        fun(Offset) ->
          Expected = compute_totp(Secret, TimeStep + Offset),
          Expected =:= Code
        end,
        lists:seq(-?TOTP_WINDOW, ?TOTP_WINDOW))
  end.

compute_totp(Secret, TimeStep) ->
  Msg = <<TimeStep:64/big-unsigned-integer>>,
  Hmac = crypto:hmac(sha, Secret, Msg),
  <<_:19/binary, LastByte>> = Hmac,
  Offset = LastByte band 16#0f,
  <<_:Offset/binary, P:4/binary, _/binary>> = Hmac,
  <<_:1, Num:31/big-unsigned-integer>> = P,
  Mod = Num rem round(math:pow(10, ?TOTP_DIGITS)),
  Digits = integer_to_binary(Mod),
  Pad = ?TOTP_DIGITS - byte_size(Digits),
  <<(binary:copy(<<"0">>, Pad))/binary, Digits/binary>>.

%%====================================================================
%% Base32 encoding/decoding (RFC 4648)
%%====================================================================

-define(B32_ALPHABET, <<"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567">>).

generate_base32_secret(NumBytes) ->
  Bytes = crypto:strong_rand_bytes(NumBytes),
  base32_encode(Bytes).

base32_encode(Bin) ->
  base32_encode(Bin, <<>>).

base32_encode(<<>>, Acc) -> Acc;
base32_encode(Bin, Acc) ->
  case Bin of
    <<V1:5, V2:5, V3:5, V4:5, V5:5, V6:5, V7:5, V8:5, Rest/binary>> ->
      base32_encode(Rest, <<Acc/binary,
        (b32char(V1)), (b32char(V2)), (b32char(V3)), (b32char(V4)),
        (b32char(V5)), (b32char(V6)), (b32char(V7)), (b32char(V8))>>);
    _ ->
      %% Pad remaining bits
      Bits = bit_size(Bin),
      <<Val:Bits/big-unsigned-integer>> = Bin,
      PadBits = case Bits rem 5 of
                  0 -> 0;
                  N -> 5 - N
                end,
      Shifted = Val bsl PadBits,
      TotalBits = Bits + PadBits,
      NumChars = TotalBits div 5,
      encode_remaining(Shifted, NumChars, Acc)
  end.

encode_remaining(_, 0, Acc) -> Acc;
encode_remaining(Val, N, Acc) ->
  Shift = (N - 1) * 5,
  Char = (Val bsr Shift) band 16#1f,
  encode_remaining(Val, N - 1, <<Acc/binary, (b32char(Char))>>).

b32char(N) -> binary:at(?B32_ALPHABET, N).

base32_decode(Encoded) ->
  try
    Cleaned = << <<C>> || <<C>> <= Encoded, C =/= $=, C =/= $ >>,
    base32_decode_bytes(Cleaned, <<>>)
  catch
    _:_ -> error
  end.

base32_decode_bytes(<<>>, Acc) -> Acc;
base32_decode_bytes(Bin, Acc) ->
  Len = byte_size(Bin),
  PadLen = case Len rem 8 of
             0 -> 0;
             N -> 8 - N
           end,
  Padded = <<Bin/binary, (binary:copy(<<"A">>, PadLen))/binary>>,
  base32_decode_full(Padded, Acc).

base32_decode_full(<<>>, Acc) -> Acc;
base32_decode_full(<<A, B, C, D, E, F, G, H, Rest/binary>>, Acc) ->
  [V1,V2,V3,V4,V5,V6,V7,V8] =
    [b32val(X) || X <- [A,B,C,D,E,F,G,H]],
  Chunk = <<V1:5, V2:5, V3:5, V4:5, V5:5, V6:5, V7:5, V8:5>>,
  base32_decode_full(Rest, <<Acc/binary, Chunk/binary>>);
base32_decode_full(_, Acc) -> Acc.

b32val(C) when C >= $A, C =< $Z -> C - $A;
b32val(C) when C >= $a, C =< $z -> C - $a;
b32val(C) when C >= $2, C =< $7 -> C - $2 + 26;
b32val(_) -> 0.

%%====================================================================
%% SQL operations
%%====================================================================

has_totp(User, LServer) ->
  case get_totp_secret(User, LServer) of
    {ok, _} -> true;
    _ -> false
  end.

get_totp_secret(User, LServer) ->
  _SJID = jid:to_string(jid:make(User, LServer)),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(totp_secret)s from user_totp"
    " where jid=%(_SJID)s and enabled=true")) of
    {selected, [{Secret}]} -> {ok, Secret};
    {selected, []} -> not_found;
    _ -> not_found
  end.

%% Get secret regardless of enabled status (for confirm flow)
get_totp_secret_any(User, LServer) ->
  _SJID = jid:to_string(jid:make(User, LServer)),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(totp_secret)s from user_totp"
    " where jid=%(_SJID)s")) of
    {selected, [{Secret}]} -> {ok, Secret};
    {selected, []} -> not_found;
    _ -> not_found
  end.

store_totp_secret(JID, Secret, LServer) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("insert into user_totp (jid, totp_secret, enabled)"
    " values (%(JID)s, %(Secret)s, false)"
    " on conflict (jid) do update"
    " set totp_secret=%(Secret)s, enabled=false")) of
    {updated, _} -> ok;
    Error -> Error
  end.

enable_totp(JID, LServer) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("update user_totp set enabled=true"
    " where jid=%(JID)s")) of
    {updated, _} -> ok;
    Error -> Error
  end.

delete_totp(JID, LServer) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from user_totp where jid=%(JID)s")) of
    {updated, _} -> ok;
    Error -> Error
  end.

%%====================================================================
%% XML helpers — manual stanza construction
%%====================================================================

has_2fa_subelement(#iq{sub_els = SubEls}) ->
  lists:any(fun(#xmlel{attrs = Attrs}) ->
    fxml:get_attr_s(<<"xmlns">>, Attrs) =:= ?NS_2FA;
               (_) -> false
            end, SubEls);
has_2fa_subelement(_) -> false.

is_totp_verify_iq(#iq{type = set, sub_els = SubEls}) ->
  case find_xmlel(<<"verify">>, ?NS_2FA, SubEls) of
    false -> false;
    VerifyEl ->
      Code = get_xmlel_cdata_child(<<"code">>, VerifyEl),
      case Code of
        <<>> -> false;
        _ -> {true, Code}
      end
  end;
is_totp_verify_iq(_) -> false.

is_device_register_iq(#iq{type = set, sub_els = SubEls}) ->
  case find_xmlel(<<"register">>, <<"https://xabber.com/protocol/devices">>,
    SubEls) of
    false -> false;
    _ -> true
  end;
is_device_register_iq(_) -> false.

find_xmlel(_Name, _NS, []) -> false;
find_xmlel(Name, NS, [#xmlel{name = Name, attrs = Attrs} = El | _]) ->
  case fxml:get_attr_s(<<"xmlns">>, Attrs) of
    NS -> El;
    _ -> false
  end;
find_xmlel(Name, NS, [_ | Rest]) ->
  find_xmlel(Name, NS, Rest).

get_xmlel_cdata_child(Name, #xmlel{children = Children}) ->
  case lists:keyfind(Name, #xmlel.name, Children) of
    #xmlel{children = [{xmlcdata, Data}]} -> Data;
    #xmlel{children = []} -> <<>>;
    _ -> <<>>
  end;
get_xmlel_cdata_child(_, _) -> <<>>.

make_totp_result(#iq{id = Id, from = From, to = To}) ->
  #iq{type = result, id = Id, from = To, to = From,
    sub_els = [#xmlel{name = <<"verified">>,
      attrs = [{<<"xmlns">>, ?NS_2FA}]}]}.

make_totp_error(#iq{} = IQ, Remaining) ->
  RemBin = integer_to_binary(Remaining),
  AttemptsEl = #xmlel{name = <<"attempts-remaining">>,
    attrs = [{<<"xmlns">>, ?NS_2FA}],
    children = [{xmlcdata, RemBin}]},
  ErrEl = xmpp:err_not_authorized(
    <<"Invalid TOTP code. ", RemBin/binary, " attempts remaining.">>,
    <<"en">>),
  #xmlel{name = <<"error">>, attrs = ErrAttrs, children = ErrChildren} =
    xmpp:encode(ErrEl),
  CustomErr = #xmlel{name = <<"error">>,
    attrs = ErrAttrs,
    children = ErrChildren ++ [AttemptsEl]},
  xmpp:make_error(IQ, CustomErr).
