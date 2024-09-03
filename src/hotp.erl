%% Copyright (c) 2014-2017 Yüce Tekol
%
%% Permission is hereby granted, free of charge, to any person obtaining a copy of this software
%% and associated documentation files (the "Software"), to deal in the Software without
%% restriction, including without limitation the rights to use, copy, modify, merge, publish,
%% distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
%% Software is furnished to do so, subject to the following conditions:
%
%% The above copyright notice and this permission notice shall be included in all copies or
%% substantial portions of the Software.
%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
%% BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
%% NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
%% DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

-module(hotp).

% API
-export([hotp/2, hotp/3]).
-export([totp/1, totp/2]).
-export([ocra/4, ocra/5, ocra_challenge/1]).

-export([valid_token/2]).
-export([valid_hotp/3]).
-export([valid_totp/2, valid_totp/3]).
-export([valid_ocra/5]).
-export([parse_suite/1, prepare_challenge/2]).


% Types
-export_type([token/0, secret/0, interval/0]).

-export_type([valid_token_options/0,
  hotp_options/0,
  totp_options/0,
  valid_hotp_options/0,
  valid_totp_options/0,
  time_interval_options/0]).

%%==============================================================================
%% Types
%%==============================================================================
-type interval() :: integer().
-type secret() :: binary().
-type token() :: binary().

-type token_option() :: {token_length, pos_integer()}.

-type time_interval_option() :: {addwindow, integer()} |
{interval_length, pos_integer()} |
{timestamp, erlang:timestamp()}.

-type hotp_option() :: token_option() |
{digest_method, atom()}.

-type totp_option() :: hotp_option() | time_interval_option().

-type valid_hotp_option() :: hotp_option() |
{last, interval()} |
return_interval | {return_interval, boolean()} |
{trials, pos_integer()}.

-type valid_totp_option() :: totp_option() |
{window, non_neg_integer()}.

-type hotp_options() :: [hotp_option() | proplists:property()].
-type totp_options() :: [totp_option() | proplists:property()].

-type valid_token_options() :: [token_option() | proplists:property()].
-type valid_hotp_options() :: [valid_hotp_option() | proplists:property()].
-type valid_totp_options() :: [valid_totp_option() | proplists:property()].

-type time_interval_options() :: [time_interval_option() | proplists:property()].

-type valid_hotp_return() :: boolean() | {true, LastInterval :: interval()}.

%%==============================================================================
%% Token generation
%%==============================================================================

-spec hotp(binary(), integer()) -> binary().
hotp(Secret, IntervalsNo) ->
  hotp(Secret, IntervalsNo, []).

-spec hotp(binary(), integer(), hotp_options()) -> binary().
hotp(Secret, IntervalsNo, Opts) ->
  DigestMethod = proplists:get_value(digest_method, Opts, sha),
  TokenLength = proplists:get_value(token_length, Opts, 8),
  Key = base64:decode(Secret),
  Msg = <<IntervalsNo:8/big-unsigned-integer-unit:8>>,
  Digest = crypto:hmac(DigestMethod, Key, Msg),
  <<Ob:8>> = binary:part(Digest, {byte_size(Digest), -1}),
  O = Ob band 15,
  <<TokenBase0:4/integer-unit:8>> = binary:part(Digest, O, 4),
  TokenBase = TokenBase0 band 16#7fffffff,
  Token0 = TokenBase rem trunc(math:pow(10, TokenLength)),
  Token1 = integer_to_binary(Token0),
  prepend_zeros(Token1, TokenLength - byte_size(Token1)).

-spec totp(secret()) -> token().
totp(Secret) ->
  totp(Secret, []).

-spec totp(secret(), totp_options()) -> token().
totp(Secret, Opts) ->
  IntervalsNo = time_interval(Opts),
  hotp(Secret, IntervalsNo, Opts).


-spec ocra(binary(), binary(), integer(), binary()) -> binary() | {error, atom()}.
ocra(_Secret, _Suite, _C, <<>>) ->
  {error, invalid_data_input};
ocra(Secret, Suite, C, Q) ->
  ocra(Secret, Suite, C, Q, []).

ocra(Secret, Suite, C, Q, Opts) ->
  case parse_suite(Suite) of
    {ok, SuiteOpts} ->
      ocra(Secret, Suite, C, Q, SuiteOpts, Opts);
    Err ->
      Err
  end.
ocra_challenge(Suite) ->
  case parse_suite(Suite) of
    {ok, Opts} ->
      F = proplists:get_value(di_qf, Opts, <<"N">>),
      L = proplists:get_value(di_ql, Opts, 8),
      ocra_challenge(F,L);
    Err ->
      Err
  end.

%%==============================================================================
%% Token validation
%%==============================================================================

-spec valid_token(binary(), valid_token_options()) -> boolean().
valid_token(Token, Opts) when is_binary(Token) ->
  Length = proplists:get_value(token_length, Opts, 8),
  case byte_size(Token) == Length of
    true ->
      lists:all(fun(X) -> X >= $0 andalso X =< $9 end, binary_to_list(Token));
    false when Length == 0 andalso byte_size(Token) >= 20->
      true;
    _ ->
      false
  end.

-spec valid_hotp(binary(), binary(), valid_hotp_options()) -> valid_hotp_return().
valid_hotp(Token, Secret, Opts) ->
  Last = proplists:get_value(last, Opts, 1),
  Trials = proplists:get_value(trials, Opts, 3),
  TokenLength = proplists:get_value(token_length, Opts, 8),
  case valid_token(Token, [{token_length, TokenLength}]) of
    true ->
      case check_candidate(Token, Secret, Last + 1, Last + Trials, Opts) of
        false ->
          false;
        LastInterval ->
          valid_hotp_return(LastInterval, proplists:get_value(return_interval, Opts, false))
      end;
    _ ->
      false
  end.

-spec valid_totp(token(), secret()) -> boolean().
valid_totp(Token, Secret) ->
  valid_totp(Token, Secret, []).

-spec valid_totp(token(), secret(), valid_totp_options()) -> boolean().
valid_totp(Token, Secret, Opts) ->
  case valid_token(Token, Opts) of
    true ->
      IntervalsNo = time_interval(Opts),
      case totp(Secret, Opts) of
        Token ->
          true;
        _ ->
          Window = proplists:get_value(window, Opts, 0),
          case check_candidate(Token, Secret, IntervalsNo - Window, IntervalsNo + Window, Opts) of
            false ->
              false;
            _ ->
              true
          end
      end;
    _ ->
      false
  end.

-spec valid_ocra(binary(), binary(), binary(), binary(), valid_hotp_options())
      -> valid_hotp_return().
valid_ocra(_Token, _Secret, _Suite, <<>>, _Opts) ->
  false;
valid_ocra(Token, Secret, Suite, Q, Opts) ->
  Last = proplists:get_value(last, Opts, undefined),
  Trials = proplists:get_value(trials, Opts, 10),
  case parse_suite(Suite) of
    {ok, SuiteOpts} ->
      NewOpts =  SuiteOpts ++ [lists:keyfind(return_interval, 1, Opts)],
      case valid_token(Token, SuiteOpts) of
        true ->
          valid_ocra(Token, Secret, Suite, Q, [Last, Trials], NewOpts);
        _ ->
          false
      end;
    _ ->
      false
  end.


%%==============================================================================
%% Internal functions
%%==============================================================================

-spec ocra(binary(), binary(), integer() | undefined, binary(),hotp_options()) -> binary().
ocra(Secret, Suite, C, Q, SuiteOpts, Opts) ->
  case prepare_challenge(Q, SuiteOpts) of
    error -> {error, invalid_data_input};
    Q1 ->
      DigestMethod = proplists:get_value(digest_method, SuiteOpts, sha256),
      TokenLength = proplists:get_value(token_length, SuiteOpts, 8),
      Key = base64:decode(Secret),
      C1 = case proplists:get_value(di_c, SuiteOpts)  of
             undefined -> <<>>;
             _ -> <<C:8/big-unsigned-integer-unit:8>>
           end,
      PH = case proplists:get_value(di_ph, SuiteOpts) of
             undefined -> <<>>;
             HFun -> crypto:hash(HFun, proplists:get_value(pincode, Opts, <<>>))
           end,
      Ss = case proplists:get_value(di_sl, SuiteOpts) of
             undefined -> <<>>;
             _Len -> proplists:get_value(session, Opts, <<>>)
           end,
      TS = case proplists:get_value(di_ts, SuiteOpts) of
             undefined -> <<>>;
             Step ->
               TS1 = proplists:get_value(ts, Opts, erlang:system_time(second)),
               <<(TS1 div Step):64>>
           end,
      Msg = <<Suite/binary,0,C1/binary,Q1/binary,PH/binary,Ss/binary,TS/binary>>,
      ocra_make_token(Key, Msg, DigestMethod, TokenLength)
  end.

ocra_make_token(Key, Message, DigestMethod, TokenLength) ->
  Digest = crypto:hmac(DigestMethod, Key, Message),
  case TokenLength of
    0 ->
      Digest;
    _ ->
      <<Ob:8>> = binary:part(Digest, {byte_size(Digest), -1}),
      O = Ob band 15,
      <<TokenBase0:4/integer-unit:8>> = binary:part(Digest, O, 4),
      TokenBase = TokenBase0 band 16#7fffffff,
      Token0 = TokenBase rem trunc(math:pow(10, TokenLength)),
      Token1 = integer_to_binary(Token0),
      prepend_zeros(Token1, TokenLength - byte_size(Token1))
  end.

valid_ocra(Token, Secret, Suite, Q, [undefined, _], Opts)->
  case ocra(Secret, Suite, undefined, Q, Opts, []) of
    Token -> true;
    _ -> false
  end;
valid_ocra(Token, Secret, Suite, Q, [Last, Trials], Opts) ->
  NewCount = Last + 1,
  NewTrials = Trials - 1,
  case ocra(Secret, Suite, NewCount, Q, Opts) of
    Token ->
      ReturnCount = proplists:get_value(return_interval, Opts, false),
      valid_hotp_return(NewCount, ReturnCount);
    _ when Last /= <<>> andalso NewTrials > 0 ->
      valid_ocra(Token, Secret, Suite, Q, [NewCount, NewTrials], Opts);
    _ ->
      false
  end.

prepare_challenge(Q, SuiteOpts) when is_binary(Q)->
  Q1 =
    case proplists:get_value(di_qf, SuiteOpts) of
      <<"A">> -> Q ;
      <<"N">> ->
        try integer_to_list(binary_to_integer(Q),16) of
          I1 ->
            I2 = string:pad(I1,length(I1) + (length(I1) rem 2),trailing,"0"),
            hex2bin(list_to_binary(I2))
        catch
            _:_  -> error
        end ;
      <<"H">> -> hex2bin(Q);
      _ ->
        error
    end,
  if
    size(Q1) > 128 -> error;
    true ->
      Pad = 128 - size(Q1),
      <<Q1/binary, 0:(Pad * 8)>>
  end;
prepare_challenge(_Q, _SuiteOpts) ->
  error.

ocra_challenge(<<"A">>, Length) ->
  randoms:get_alphanum_string(Length);
ocra_challenge(<<"N">>, Length) ->
  << <<(X rem 10 + $0)>>  || <<X>> <= crypto:strong_rand_bytes(Length) >>;
ocra_challenge(<<"H">>, Length) ->
  bin2hex(crypto:strong_rand_bytes(Length div 2)).

-spec time_interval(time_interval_options()) -> interval().
time_interval(Opts) ->
  IntervalLength = proplists:get_value(interval_length, Opts, 30),
  AddSeconds = proplists:get_value(addwindow, Opts, 0) * proplists:get_value(interval_length, Opts, 30),
  {MegaSecs, Secs, _} = proplists:get_value(timestamp, Opts, os:timestamp()),
  trunc((MegaSecs * 1000000 + (Secs + AddSeconds)) / IntervalLength).

-spec check_candidate(binary(), binary(), integer(), integer(), hotp_options()) ->
  integer() | false.
check_candidate(Token, Secret, Current, Last, Opts) when Current =< Last ->
  case hotp(Secret, Current, Opts) of
    Token ->
      Current;
    _ ->
      check_candidate(Token, Secret, Current + 1, Last, Opts)
  end;
check_candidate(_Token, _Secret, _Current, _Last, _Opts) ->
  false.

-spec prepend_zeros(binary(), non_neg_integer()) -> binary().
prepend_zeros(Token, N) ->
  Padding = << <<48:8>> || _ <- lists:seq(1, N) >>,
  <<Padding/binary, Token/binary>>.

-spec valid_hotp_return(integer(), boolean()) -> valid_hotp_return().
valid_hotp_return(LastInterval, true = _ReturnInterval) ->
  {true, LastInterval};
valid_hotp_return(_LastInterval, _ReturnInterval) ->
  true.

parse_suite(Suite) when is_binary(Suite)->
  parse_suite(binary:split(Suite,<<$:>>,[global]));
parse_suite([<<"OCRA-1">>, CryptoFun, DataInput]) ->
  [<<"HOTP">>, HashFun, TokenLenB] = binary:split(CryptoFun,<<$->>,[global]),
  TL = binary_to_integer(TokenLenB),
  CheckTL = (TL == 0 orelse (TL > 3 andalso TL < 11)),
  case hash_fun(HashFun) of
    false -> {error, invalid_suite};
    HF when CheckTL ->
      case parse_data_input(DataInput) of
        {error, Why} -> {error, Why,2};
        DI ->
          {ok, [{digest_method, HF}, {token_length, TL}] ++ DI}
      end;
    _ ->
      {error, invalid_suite}
  end.


parse_data_input(DataInput) when is_binary(DataInput) ->
  DI = parse_data_input(binary:split(DataInput,<<$->>,[global]), []),
  case lists:member(false, DI) of
    true -> {error, invalid_suite};
    _ -> DI
  end.

parse_data_input([], Acc) ->
  Acc;
parse_data_input([ <<"C">> |T ], Acc) ->
  parse_data_input(T, Acc ++ [{di_c , true}]);
parse_data_input([ <<"Q",F:1/binary,L/binary>> |T ], Acc) ->
  case lists:member(F, [<<"A">>, <<"N">>, <<"H">>]) of
    true ->
      case binary_to_integer(L) of
        V when V < 4 orelse V > 64 -> [false];
        QL -> parse_data_input(T, Acc ++ [{di_qf, F}, {di_ql, QL}])
      end;
    _ ->
      [false]
  end;
parse_data_input([ <<"P",H/binary>> |T ], Acc) ->
  case hash_fun(H) of
    false -> [false];
    A -> parse_data_input(T, Acc ++ [{di_ph, A}])
  end;
parse_data_input([ <<"S",L/binary>> |T ], Acc) ->
  case binary_to_integer(L) of
    V when V == 0 orelse V > 999 -> [false];
    SL -> parse_data_input(T, Acc ++ [{di_sl, SL}])
  end;
parse_data_input([ <<"T", G/binary>> | T ], Acc) ->
  N = binary_to_integer(binary:part(G, 0, size(G) - 1)),
  I =  case binary:last(G) of
         _ when N < 1 -> false;
         $S when N < 60 -> 1;
         $M when N < 60 -> 60;
         $H when N < 49 -> 60*60;
         _ -> false
         end,
  case I of
    false -> [false];
    _ -> parse_data_input(T , Acc ++ [{di_ts, N * I}])
  end;
parse_data_input(_, _) ->
  [false].

hash_fun(<<"SHA1">>) -> sha;
hash_fun(<<"SHA256">>) -> sha256;
hash_fun(<<"SHA512">>) -> sha512;
hash_fun(_) -> false.

bin2hex(B) ->
  << <<Y>> || <<X:4>> <= B, Y <- integer_to_list(X, 16) >>.

hex2bin(H) ->
  << <<Z>> || <<X:8, Y:8>> <= H, Z <- [binary_to_integer(<<X, Y>>, 16)] >>.
