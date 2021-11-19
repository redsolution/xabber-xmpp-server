-module(hotp).

% API
-export([hotp/2, hotp/3]).
-export([valid_token/2]).
-export([valid_hotp/3]).


% Types
-export_type([valid_token_options/0,
  hotp_options/0,
  valid_hotp_options/0]).

%%==============================================================================
%% Types
%%==============================================================================
-type token_option() :: {token_length, pos_integer()}.

-type hotp_option() :: token_option() |
{digest_method, atom()}.

-type valid_hotp_option() :: hotp_option() |
{last, integer()} |
return_interval | {return_interval, boolean()} |
{trials, pos_integer()}.

-type hotp_options() :: [hotp_option() | proplists:property()].

-type valid_token_options() :: [token_option() | proplists:property()].
-type valid_hotp_options() :: [valid_hotp_option() | proplists:property()].

-type valid_hotp_return() :: boolean() | {true, LastInterval :: integer()}.

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

%%==============================================================================
%% Token validation
%%==============================================================================

-spec valid_token(binary(), valid_token_options()) -> boolean().
valid_token(Token, Opts) when is_binary(Token) ->
  Length = proplists:get_value(token_length, Opts, 8),
  case byte_size(Token) == Length of
    true ->
      lists:all(fun(X) -> X >= $0 andalso X =< $9 end, binary_to_list(Token));
    false ->
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

%%==============================================================================
%% Internal functions
%%==============================================================================

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
