%%%-------------------------------------------------------------------
%%% File    : mod_panel.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : HTTP API for Xabber Server Panel
%%% Created : 24 Jan 2022 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%%
%%%
%%% xabberserver, Copyright (C) 2007-2022   Redsolution OÜ
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
-module(mod_panel).
-author("ilya.kalashnikov@redsolution.com").
-behavior(gen_mod).
-include("logger.hrl").
-include("ejabberd_commands.hrl").
-include("ejabberd_http.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).

-define(CT_PLAIN,
  {<<"Content-Type">>, <<"text/plain">>}).

-define(CT_JSON,
  {<<"Content-Type">>, <<"application/json">>}).

-define(AC_ALLOW_ORIGIN,
  {<<"Access-Control-Allow-Origin">>, <<"*">>}).

-define(AC_ALLOW_METHODS,
  {<<"Access-Control-Allow-Methods">>,
    <<"GET, POST, OPTIONS, PUT, DELETE">>}).

-define(AC_ALLOW_HEADERS,
  {<<"Access-Control-Allow-Headers">>,
    <<"Content-Type, Authorization, X-Admin">>}).

-define(OPTIONS_HEADER,
  [?CT_PLAIN, ?AC_ALLOW_ORIGIN, ?AC_ALLOW_METHODS,
    ?AC_ALLOW_HEADERS]).

-define(HEADER(CType),
  [CType, ?AC_ALLOW_ORIGIN, ?AC_ALLOW_HEADERS]).

%% TOKEN TTL 4 hour
-define(TOKEN_TTL, 14400).

-define(PERM_KEYS, [<<"server">>, <<"users">>, <<"groups">>, <<"vcard">>, <<"circles">>]).
-define(PERM_VALUES, [<<"write">>, <<"read">>, <<"forbidden">>]).
-define(FORBID_ALL,<<"sfufgfvfcf">>).

%% Permissions string
%%     sXuXgXvXcX
%%     | | | | |
%%     | | | | |__circles
%%     | | | |____vcard
%%     | | |______groups
%%     | |________users
%%     |__________server
%%
%%
%% X is:
%%  w - write
%%  r - read
%%  f - forbidden


%% API
-export([start/2, stop/1, depends/2, mod_options/1, mod_opt_type/1]).

%% ejabberd_http callback.
-export([process/2]).

%% register commands
-export([get_commands_spec/0, set_admin/2, issue_token/3, add_group/8]).

%% internal
%%-export([create_user/1]).


%% gen_mod
start(_Host, _Opts) ->
  ejabberd_commands:register_commands(get_commands_spec()),
  ok.

stop(_Host) ->
  ok.

depends(_Host, _Opts) -> [].

mod_options(_Host) ->
  [{cronjob_token, undefined}].

mod_opt_type(cronjob_token) ->
  fun(undefined) -> undefined;
    (Token) -> iolist_to_binary(Token)
  end.

%%%
%%% Register commands
%%%

get_commands_spec() ->
  [
    #ejabberd_commands{name = panel_set_admin, tags = [panel],
      desc = "Make Panel admin",
      policy = admin,
      module = ?MODULE, function = set_admin,
      args_desc = ["Username", "Local vhost served by ejabberd"],
      args_example = [<<"bob">>, <<"example.com">>],
      args = [{user, binary}, {host, binary}],
      result = {res, rescode}},
    #ejabberd_commands{name = panel_issue_token, tags = [panel],
      desc = "Issue token for Panel",
      policy = admin,
      module = ?MODULE, function = issue_token,
      args_desc = ["Username", "Local vhost served by ejabberd","Time to live of generated token in seconds"],
      args_example = [<<"bob">>, <<"example.com">>, 3600],
      args = [{user, binary}, {host, binary},{ttl, integer}],
      result = {res, rescode}},
    #ejabberd_commands{name = create_group, tags = [groups],
      desc = "Create groupchat with owner",
      module = ?MODULE, function = add_group,
      args = [{host, binary},
        {ownerusername, binary},
        {ownerdomain, binary},
        {name, binary},
        {localpart, binary},
        {privacy, binary},
        {index, binary},
        {membership, binary}
      ],
      args_example = [<<"myserver.com">>, <<"user1">>, <<"someserver.com">>,  <<"Group 3">>,
        <<"group3">>, <<"public">>, <<"global">>, <<"open">>, <<"Group number 3">>],
      args_desc = ["Host","Owner username", "Owner domain", "Group name",
        "Group localpart", "Group privacy", "Group index", "Group membership"],
      result = {result, string},
      result_example = "created",
      result_desc = "Returns i:\n"
      " - created\n"
      " - error: already exist\n"
      " - error:"}
  ].

%%===================================================================
%%% HTTP API
%%%===================================================================
process(_Path, #request{method = 'OPTIONS', data = <<>>}) ->
  {200, ?OPTIONS_HEADER, []};
process(_, #request{method = 'OPTIONS'}) ->
  {400, ?OPTIONS_HEADER, []};
process(Path, #request{method = Method, data = Data, q = Q, headers = Headers} = Req) ->
  ?DEBUG("Request: ~p ~p ~p ~p ~p~n",[Method, Path,Data,Headers,Q]),
  case extract_auth(Req) of
    {error, expired} -> invalid_token_response();
    {error, not_found} -> invalid_token_response();
    {error, invalid_auth} -> unauthorized_response();
    {error, _} -> unauthorized_response();
    cronjob ->
      json_format(
        handle_request(Method, Path, Req, {false,<<"cronjob">>}, <<>>, <<>>));
    Auth when is_map(Auth) ->
      {User, Server, <<"">>} = maps:get(usr, Auth),
      Result = case get_permissions(User, Server) of
                 {error, notfound} -> forbidden_response();
                 {error, _} -> {500, <<>>};
                 Perms ->
                   handle_request(Method, Path, Req, Perms, User, Server)
      end,
      json_format(Result);
    _ ->
      unauthorized_response()
  end.

handle_request('POST',[<<"issue_token">>], _Req, _Perms, User, Server) ->
  issue_token(User, Server, ?TOKEN_TTL);
handle_request('POST',[<<"revoke_token">>], #request{data = Data}, _Perms, User, Server) ->
  case extract_args(Data, [token]) of
    error -> badrequest_response();
    Args ->
      revoke_token(User, Server, proplists:get_value(token, Args))
  end;
handle_request('POST',[<<"config">>,<<"reload">>], _Req, {true, _}, _User, _Server) ->
  ejabberd_admin:reload_config(),
  {200, <<>>};
handle_request('GET',[<<"registration">>,<<"keys">>], #request{q = Q}, {true, _}, _User, _Server) ->
  Args = check_args(Q, [host]),
  case check_args(Q, [host]) of
    error ->
      badrequest_response();
    Args ->
      get_reg_keys(Args)
  end;
handle_request('POST',[<<"registration">>,<<"keys">>], #request{data = Data}, {true, _}, _User, _Server) ->
  case extract_args(Data, [host, expire, description]) of
    error -> badrequest_response();
    Args ->
      make_reg_key(Args)
  end;
handle_request('PUT',[<<"registration">>,<<"keys">>,Key], #request{data = Data}, {true, _}, _User, _Server) ->
  case extract_args(Data, [host, expire, description]) of
    error -> badrequest_response();
    Args ->
      update_reg_key(Key,Args)
  end;
handle_request('DELETE',[<<"registration">>,<<"keys">>,Key], #request{data = Data}, {true, _}, _User, _Server) ->
  case extract_args(Data, [host]) of
    error -> badrequest_response();
    Args ->
      remove_reg_key(Key, Args)
  end;
handle_request('POST',[<<"permissions">>], #request{data = Data}, {true, _}, _User, _Server) ->
  case extract_args(Data, [username, host, permissions]) of
    error -> badrequest_response();
    Args ->
      set_permissions(Args)
  end;
handle_request('POST',[<<"admins">>], #request{data = Data}, {true, _}, _User, _Server) ->
  case extract_args(Data, [username, host]) of
    error -> badrequest_response();
    Args ->
      set_admin(Args)
  end;
handle_request('DELETE',[<<"admins">>], #request{data = Data}, {true, _}, _User, _Server) ->
  case extract_args(Data, [username, host]) of
    error -> badrequest_response();
    Args ->
      remove_admin(Args)
  end;
handle_request('GET',[<<"vhosts">>], _Req, _Perms, _User, _Server) ->
  Result = {[{vhosts,  ejabberd_config:get_myhosts()}]},
  {200, Result};
handle_request('POST',[<<"users">>], #request{data = Data},
    {Adm, <<_:24,P:8,_/binary>>}, _User, Server) when Adm orelse P == $w ->
  Args = extract_args(Data, [username, host, password]),
  check_and_run(Adm, Server, Args, fun create_user/1);
handle_request('DELETE',[<<"users">>], #request{data = Data},
    {Adm, <<_:24,P:8,_/binary>>}, _User, Server) when Adm orelse P == $w ->
  Args = extract_args(Data, [username, host]),
  check_and_run(Adm, Server, Args,fun remove_user/1);
handle_request('GET',[<<"users">>], #request{q = Q}, {_, <<"cronjob">>}, _, _) ->
  Args = check_args(Q, [host]),
  check_and_run(true, <<>>, Args,fun get_users/1);
handle_request('GET',[<<"users">>], #request{q = Q},
    {Adm, <<_:24,P:8,_/binary>>}, _User, Server) when Adm orelse P >= $r ->
  Args = check_args(Q, [host]),
  check_and_run(Adm, Server, Args,fun get_users/1);
handle_request('GET',[<<"users">>,<<"count">>], #request{q = Q},
    {Adm, <<_:8,P:8,_/binary>>}, _User, Server) when Adm orelse P >= $r ->
  Args = check_args(Q, [host]),
  check_and_run(Adm, Server, Args,fun get_users_count/1);
handle_request('GET',[<<"users">>,<<"online">>], #request{q = Q},
    {Adm, <<_:8,P:8,_/binary>>}, _User, Server) when Adm orelse P >= $r ->
  Args = check_args(Q, [host]),
  check_and_run(Adm, Server, Args,fun get_online_count/1);
handle_request('PUT',[<<"users">>,<<"set_password">>], #request{data = Data},
    {Adm, <<_:24,P:8,_/binary>>}, _User, Server) when Adm orelse P == $w ->
  Args = extract_args(Data, [username, host, password]),
  check_and_run(Adm, Server, Args, fun set_password/1);
handle_request('POST',[<<"users">>,<<"block">>], #request{data = Data},{_, <<"cronjob">>}, _, _) ->
  Args = extract_args(Data, [username, host, reason]),
  check_and_run(true, <<>>, Args, fun block_user/1);
handle_request('POST',[<<"users">>,<<"block">>], #request{data = Data},
    {Adm, <<_:24,P:8,_/binary>>}, _User, Server) when Adm orelse P == $w ->
  Args = extract_args(Data, [username, host, reason]),
  check_and_run(Adm, Server, Args, fun block_user/1);
handle_request('DELETE',[<<"users">>,<<"block">>], #request{data = Data},{_, <<"cronjob">>}, _, _) ->
  Args = extract_args(Data, [username, host]),
  check_and_run(true, <<>>, Args, fun unblock_user/1);
handle_request('DELETE',[<<"users">>,<<"block">>], #request{data = Data},
    {Adm, <<_:24,P:8,_/binary>>}, _User, Server) when Adm orelse P == $w ->
  Args = extract_args(Data, [username, host]),
  check_and_run(Adm, Server, Args, fun unblock_user/1);
handle_request('POST',[<<"users">>,<<"ban">>], #request{data = Data},
    {Adm, <<_:24,P:8,_/binary>>}, _User, Server) when Adm orelse P == $w ->
  Args = extract_args(Data, [username, host]),
  check_and_run(Adm, Server, Args, fun ban_user/1);
handle_request('DELETE',[<<"users">>,<<"ban">>], #request{data = Data},
    {Adm, <<_:24,P:8,_/binary>>}, _User, Server) when Adm orelse P == $w ->
  Args = extract_args(Data, [username, host]),
  check_and_run(Adm, Server, Args, fun unban_user/1);
handle_request(_,[<<"users">>], _, _, _, _) ->
  forbidden_response();
handle_request(_,[<<"users">>| _], _, _, _, _) ->
  forbidden_response();
handle_request('POST',[<<"groups">>], #request{data = Data},
    {Adm, <<_:40,P:8,_/binary>>}, _User, Server) when Adm orelse P == $w ->
  Args = extract_args(Data, [localpart, host, owner, name, privacy, index, membership]),
  check_and_run(Adm, Server, Args, fun add_group/1);
handle_request('DELETE',[<<"groups">>], #request{data = Data},
    {Adm, <<_:40,P:8,_/binary>>}, _User, Server) when Adm orelse P == $w ->
  Args = extract_args(Data, [localpart, host]),
  check_and_run(Adm, Server, Args , fun remove_group/1);
handle_request('GET',[<<"groups">>], #request{q = Q},
    {Adm, <<_:40,P:8,_/binary>>}, _User, Server) when Adm orelse P >= $r->
  Args = check_args(Q, [host]),
  check_and_run(Adm, Server, Args , fun get_groups/1);
handle_request('GET',[<<"groups">>,<<"count">>], #request{q = Q},
    {Adm, <<_:40,P:8,_/binary>>}, _User, Server) when Adm orelse P >= $r->
  Args = check_args(Q, [host]),
  check_and_run(Adm, Server, Args , fun get_groups_count/1);
handle_request(_,[<<"groups">>], _, _, _, _) ->
  forbidden_response();
handle_request(_,[<<"groups">>| _], _, _, _, _) ->
  forbidden_response();
handle_request('POST',[<<"vcard">>], #request{data = Data},
    {Adm, <<_:56,P:8,_/binary>>}, _User, Server) when Adm orelse P == $w ->
  Args = extract_args(Data, [username, host, vcard]),
  check_and_run(Adm, Server, Args, fun update_vcard/1);
handle_request('GET',[<<"vcard">>], #request{q = Q},
    {Adm, <<_:56,P:8,_/binary>>}, _User, Server) when Adm orelse P >= $r->
  Args = check_args(Q, [username, host]),
  check_and_run(Adm, Server, Args , fun get_vcard/1);
handle_request(_,[<<"vcard">>], _, _, _, _) ->
  forbidden_response();
handle_request('POST',[<<"circles">>], #request{data = Data},
    {Adm, <<_:72,P:8,_/binary>>}, _User, Server) when Adm orelse P == $w ->
  Args = extract_args(Data, [circle, host]),
  check_and_run(Adm, Server, Args, fun add_circle/1);
handle_request('DELETE',[<<"circles">>], #request{data = Data},
    {Adm, <<_:72,P:8,_/binary>>}, _User, Server) when Adm orelse P == $w ->
  Args = extract_args(Data, [circle, host]),
  check_and_run(Adm, Server, Args, fun remove_circle/1);
handle_request('GET',[<<"circles">>], #request{q = Q},
    {Adm, <<_:72,P:8,_/binary>>}, _User, Server) when Adm orelse P >= $r ->
  Args = check_args(Q, [host]),
  check_and_run(Adm, Server, Args , fun get_circles/1);
handle_request('GET',[<<"circles">>, <<"info">>], #request{q = Q},
    {Adm, <<_:72,P:8,_/binary>>}, _User, Server) when Adm orelse P >= $r ->
  Args = check_args(Q, [host, circle]),
  check_and_run(Adm, Server, Args , fun get_circle_info/1);
handle_request('POST',[<<"circles">>, <<"members">>], #request{data = Data},
    {Adm, <<_:72,P:8,_/binary>>}, _User, Server)  when Adm orelse P == $w ->
  Args = extract_args(Data, [circle, host, members]),
  check_and_run(Adm, Server, Args, fun circle_add_members/1);
handle_request('DELETE',[<<"circles">>, <<"members">>], #request{data = Data},
    {Adm, <<_:72,P:8,_/binary>>}, _User, Server) when Adm orelse P == $w ->
  Args = extract_args(Data, [circle, host, members]),
  check_and_run(Adm, Server, Args, fun circle_remove_members/1);
handle_request('GET',[<<"circles">>, <<"members">>], #request{q = Q},
    {Adm, <<_:72,P:8,_/binary>>}, _User, Server) when Adm orelse P >= $r ->
  Args = check_args(Q, [host, circle]),
  check_and_run(Adm, Server, Args , fun get_circle_members/1);
handle_request(_,[<<"circles">>], _, _, _, _) ->
  forbidden_response();
handle_request(_,[<<"circles">>| _], _, _, _, _) ->
  forbidden_response();
handle_request(Method, Path, _Req, _Perms, _User, _Server) ->
  ?DEBUG("Path not found ~p ~p~n",[Method,Path]),
  {404, [], [<<"path no found">>]}.

%% Internal
extract_auth(#request{auth = HTTPAuth, ip = {IP, _}}) ->
  Info = case HTTPAuth of
           {SJID, Pass} ->
             try jid:decode(SJID) of
               #jid{luser = User, lserver = Server} ->
                 case ejabberd_auth:check_password(User, <<"">>, Server, Pass) of
                   true ->
                     #{usr => {User, Server, <<"">>}, caller_server => Server};
                   false ->
                     {error, invalid_auth}
                 end
             catch _:{bad_jid, _} ->
               {error, invalid_auth}
             end;
           {oauth, Token, _} ->
             case check_token(Token) of
               {ok, {U, S}} ->
                 #{usr => {U, S, <<"">>}, caller_server => S};
               {false, Reason} ->
                 case gen_mod:get_module_opt(global,?MODULE,cronjob_token) of
                   Token -> cronjob;
                   _ -> {error, Reason}
                 end
             end;
           _ ->
             {error, invalid_auth}
         end,
  case Info of
    Map when is_map(Map) ->
      Map#{caller_module => ?MODULE, ip => IP};
    _ ->
      ?DEBUG("Invalid auth data: ~p", [Info]),
      Info
  end.

unauthorized_response() ->
  json_error(401, 401001,
    <<"You are not authorized to call this command.">>).

invalid_token_response() ->
  json_error(401, 401002, <<"Token is invalid or expired.">>).

badrequest_response() ->
  badrequest_response(<<"Bad Request">>).
badrequest_response(Body) ->
  {400, 40001, Body}.

forbidden_response() ->
  {403 , 403001, <<"Forbidden">>}.


json_format({Code, Result}) ->
  json_response(Code, jiffy:encode(Result));
json_format({HTMLCode, JSONErrorCode, Message}) ->
  json_error(HTMLCode, JSONErrorCode, Message).

json_response(Code, Body) when is_integer(Code) ->
  {Code, ?HEADER(?CT_JSON), Body}.

%% HTTPCode, JSONCode = integers
%% message is binary
json_error(HTTPCode, JSONCode, Message) ->
  {HTTPCode, ?HEADER(?CT_JSON),
    jiffy:encode({[{<<"status">>, <<"error">>},
      {<<"code">>, JSONCode},
      {<<"message">>, Message}]})
  }.

decode_json(Data) ->
  PL = try
         case jiffy:decode(Data) of
           List when is_list(List) -> List;
           {List} when is_list(List) -> List;
           Other -> [Other]
         end
      catch _:_  -> []
      end,
  lists:map(fun({K, null}) -> {K, <<>>};
    (V) -> V end, PL).

check_args(ArgsRaw, RequiredKeys) ->
  Args = lists:map(
    fun({K, V}) ->
      {binary_to_atom(K, latin1), V}
    end, ArgsRaw
  ),
  ExistingKeys = lists:filter(
    fun(Key) ->
      lists:keymember(Key, 1, Args)
    end, RequiredKeys),
  case RequiredKeys of
    ExistingKeys -> Args;
    _ -> error
  end.

extract_args(<<>>, _Keys) ->
  error;
extract_args(Data, Keys) ->
  case decode_json(Data) of
    [] ->
      error;
    Args ->
      check_args(Args, Keys)
  end.

check_and_run(_IsAdmin, _UserHost, error, _Fun)->
  badrequest_response();
check_and_run(true, _UserHost, Args, Fun)->
  case check_host(proplists:get_value(host,Args)) of
    {ok, _Host} -> Fun(Args);
    Result -> Result
  end;
check_and_run(_IsAdmin, UserHost, Args, Fun) ->
  Host = extract_host(Args),
  if
    Host == UserHost ->
      Fun(Args);
    true ->
      forbidden_response()
  end.

check_host(undefined)->
  badrequest_response();
check_host(Host) ->
  case jid:nameprep(Host) of
    error ->
      badrequest_response();
    LServer ->
      case lists:member(LServer, ejabberd_config:get_myhosts()) of
        true ->
          {ok, LServer};
        _ ->
          {404,<<"Unknown Host">>}
      end
  end.

check_user(User, Host) when User == undefined orelse Host == undefined ->
  badrequest_response();
check_user(User, Host) ->
  JID = try
          jid:make(User, Host)
        catch
          _:_  -> undefined
        end,
  check_user(JID).

check_user(#jid{luser = LUser, lserver = LServer} = JID) ->
  case ejabberd_auth:user_exists(LUser, LServer) of
    true -> JID;
    _ -> {404,<<"Account does not exist">>}
  end.

convert_vcard([]) -> [];
convert_vcard([VCard|_Rest]) ->
  Els = VCard#xmlel.children,
  JSON = xml_to_json(Els),
  {[{Key, Value} || {Key, Value} <- JSON, Value =/= {[]}]}.

xml_to_json(Els) ->
  lists:filtermap(fun(El) ->
    case El#xmlel.children of
      [{xmlcdata, CData}] -> {true, {El#xmlel.name, CData}};
      [] -> false;
      List -> {true, {El#xmlel.name, {xml_to_json(List)}}}
    end
                  end, Els).

get_permissions(User, Host) ->
  case sql_get_permissions(User, Host) of
    {true, _} -> {true, <<"justforcomparison">>};
    P -> P
  end.

parse_permissions(Perms) ->
  PL = lists:map(fun(K) ->
    Value  = proplists:get_value(K, Perms, <<"forbidden">>),
    IsValid = lists:member(Value, ?PERM_VALUES),
    if
      IsValid ->
        {binary_part(K,0,1), binary_part(Value,0,1)};
      true ->
        error
    end end, ?PERM_KEYS),
  lists:foldl(fun({K,V}, Acc) -> <<Acc/binary,K/binary,V/binary>> end, <<>>,PL).

%% Commands
issue_token(User, Server, TTL) ->
  AccessToken = oauth2_token:generate(32),
  Expires = seconds_since_epoch(TTL),
  sql_save_token(User, Server, AccessToken, Expires),
  {201, {[{token, AccessToken},{expires_in, TTL}]}}.

revoke_token(User, Server, Token) ->
  sql_remove_token(Server, User, Token),
  {200, <<>>}.

set_permissions(Args) ->
  {Username, Host} = extract_user_host(Args),
  {PermsPL} = proplists:get_value(permissions,Args,{[]}),
  Perms = parse_permissions(PermsPL),
  Result = case Perms of
             ?FORBID_ALL -> sql_remove_permissions(Username, Host);
             _ -> sql_set_permissions(Username, Host, false, Perms)
           end,
  case Result of
    ok -> {201, <<>>};
    _ -> {500, <<>>}
  end.

set_admin(Args) ->
  {Username, Host} = extract_user_host(Args),
  case sql_set_permissions(Username, Host, true, <<>>) of
    ok -> {201, <<>>};
    _ -> {500, <<>>}
  end.

set_admin(Username, Host) ->
  Username = jid:nodeprep(Username),
  Host = jid:nameprep(Host),
  sql_set_permissions(Username, Host, true, <<>>).

remove_admin(Args) ->
  {Username, Host} = extract_user_host(Args),
  case sql_remove_permissions(Username, Host) of
    ok -> {201, <<>>};
    _ -> {500, <<>>}
  end.

get_reg_keys(Args) ->
  Host = extract_host(Args),
  Keys = mod_registration_keys:get_keys(Host),
  case mod_registration_keys:get_keys(Host) of
    error ->
      {500, <<>>};
    Keys ->
      Result = {[{keys,[{[{key,K},{expire,E},{description,D}]} || {K, E, D} <- Keys]}]},
      {200, Result}
  end.

make_reg_key(Args) ->
  Host = extract_host(Args),
  Expire = case proplists:get_value(expire,Args) of
             V when is_integer(V) -> V;
             V -> binary_to_integer(V)
           end,
  Desc = proplists:get_value(description,Args,<<>>),
  case mod_registration_keys:make_key(Host, Expire, Desc) of
    {K, E, D} ->
      {201, {[{key,K},{expire,E},{description,D}]}};
    _ ->
      {500, <<>>}
  end.

update_reg_key(Key, Args) ->
  Host = extract_host(Args),
  Expire = case proplists:get_value(expire,Args) of
             V when is_integer(V) -> V;
             V -> binary_to_integer(V)
           end,
  Desc = proplists:get_value(description,Args,<<>>),
  case mod_registration_keys:update_key(Host, Key, Expire, Desc) of
    ok ->
      {200, <<>>};
    notfound ->
      {404, <<>>};
    _ ->
      {500, <<>>}
  end.

remove_reg_key(Key, Args) ->
  Host = extract_host(Args),
  mod_registration_keys:remove_key(Host,Key),
  {200, <<>>}.

create_user(Args) ->
  {Username, Host} = extract_user_host(Args),
  Password = proplists:get_value(password, Args),
  case check_host(Host) of
    {ok, _} ->
      create_user(Username, Host, Password);
    _ ->
      badrequest_response(<<"Unknown Host">>)
  end.

create_user(Username, Host, Password) ->
  case ejabberd_admin:register(Username, Host, Password) of
    {ok, String} ->
      {201, list_to_binary(String)};
    {error, conflict, _, String} ->
      {409, list_to_binary(String)};
    {error, _, _, String} ->
      {500, list_to_binary(String)}
  end.

remove_user(Args) ->
  {Username, Host} = extract_user_host(Args),
  ejabberd_auth:remove_user(Username, Host),
  case ejabberd_auth:user_exists(Username, Host) of
    true ->
      {500, <<"Unable to delete user">>};
    _ ->
      {200, <<>>}
  end.

set_password(Args) ->
  {Username, Host} = extract_user_host(Args),
  Password = proplists:get_value(password, Args),
  case ejabberd_auth:user_exists(Username, Host) of
    true ->
      case catch ejabberd_auth:set_password(Username, Host, Password) of
        ok -> {200, <<>>};
        Error ->
          ?ERROR_MSG("Command returned: ~p", [Error]),
          {500, <<>>}
      end;
    false ->
      {404, <<"unknown user">>}
  end.

block_user(Args) ->
  {Username, Host} = extract_user_host(Args),
  Reason = proplists:get_value(reason, Args),
  case gen_mod:is_loaded(Host, mod_block_users) of
    true ->
      mod_block_users:block_user(Username, Host, Reason),
      {200, <<>>};
    _ ->
      {503, <<"feature not implemented">>}
  end.

unblock_user(Args) ->
  {Username, Host} = extract_user_host(Args),
  Reason = proplists:get_value(reason, Args, <<>>),
  case gen_mod:is_loaded(Host, mod_block_users) of
    true ->
      mod_block_users:unblock_user(Username, Host, Reason),
      {200, <<>>};
    _ ->
      {503, <<"feature not implemented">>}
  end.

ban_user(Args) ->
  ban_user(do, Args).

unban_user(Args) ->
  ban_user(undo, Args).

ban_user(Action, Args) ->
  {Username, Host} = extract_user_host(Args),
  Default = ejabberd_config:default_db(Host, ejabberd_auth),
  Result = case ejabberd_config:get_option({auth_method, Host}, [Default]) of
             [sql] when Action == do ->
               mod_devices:remove_user(Username, Host),
               kick_user_sessions(Username, Host),
               sql_ban_user(Username, Host);
             [sql] when Action == undo ->
               sql_unban_user(Username, Host);
             _ ->
               not_implemented
           end,
  case Result of
    {updated,1} -> {200, <<>>};
    {updated,0} -> {404, <<"user not found">>};
    not_implemented -> {503, <<"feature not implemented">>};
    _ -> {500, <<>>}
  end.

sql_ban_user(Username, Host) ->
  ejabberd_sql:sql_query(
    Host,
    ?SQL("update users SET password = '+++BANNED+++' || password "
    "where username=%(Username)s and %(Host)H")).

sql_unban_user(Username, Host) ->
  ejabberd_sql:sql_query(
    Host,
    ?SQL("update users SET password = ltrim(password,'+++BANNED+++') "
    "where username=%(Username)s and %(Host)H")).

get_users(Args) ->
  Host = extract_host(Args),
  Users1 = lists:sort(get_users(Host, [])),
  Users2 = [{[{username,U},{backend,B}]} || {U,_S, B} <- Users1],
  {200, {[{users, Users2}]}}.

get_users_count(Args) ->
  Host = extract_host(Args),
  Count = length(get_users(Host, [])),
  {200, {[{count, Count}]}}.

get_users(Server, Opts) ->
  case jid:nameprep(Server) of
    error -> [];
    LServer ->
      lists:flatmap(
        fun(M) -> db_get_users(LServer, Opts, M) end,
        auth_modules(LServer))
  end.

db_get_users(Server, Opts, {Mod,Auth}) ->
  case erlang:function_exported(Mod, get_users, 2) of
    true ->
      lists:map(fun({U,S}) ->
        {U,S,Auth} end,
        Mod:get_users(Server, Opts));
    false ->
      []
  end.

auth_modules(Server) ->
  LServer = jid:nameprep(Server),
  Default = [sql, ldap],
  Methods = ejabberd_config:get_option({auth_method, LServer}, Default),
  [{ejabberd:module_name([<<"ejabberd">>, <<"auth">>,
    misc:atom_to_binary(M)]), misc:atom_to_binary(M)}
    || M <- Methods].

get_online_count(Args) ->
  Host = extract_host(Args),
  Count = length(lists:usort(
    [U || {U, _H, _R} <- ejabberd_sm:get_vh_session_list(Host)])),
  {200, {[{count, Count}]}}.

add_group(Args) ->
  Owner = proplists:get_value(owner,Args, false),
  LocalPart = jid:nodeprep(proplists:get_value(localpart,Args, false)),
  GroupHost = extract_host(Args),
  GroupName = proplists:get_value(name,Args),
  Privacy = proplists:get_value(privacy,Args),
  Index = proplists:get_value(index,Args),
  Membership = proplists:get_value(membership,Args),
  ChPrivacy = lists:member(Privacy,[<<"public">>, <<"incognito">>]),
  ChIndex = lists:member(Index,[<<"none">>, <<"local">>, <<"global">>]),
  ChMembership = lists:member(Membership,[<<"open">>, <<"member-only">>]),
  AnyErrors = lists:member(false,[Owner, LocalPart, ChPrivacy,
    ChIndex, ChMembership]),
  IsExist = mod_xabber_entity:is_exist_anywhere(LocalPart, GroupHost),
  if
    IsExist ->
      {409, <<"JID already exists">> };
    AnyErrors ->
      badrequest_response();
    true ->
      add_group(Owner, LocalPart,
        GroupHost, GroupName, Privacy, Index, Membership)
  end.

add_group(Owner, LocalPart,GroupHost, GroupName,
    Privacy, Index, Membership) ->
  GroupInfo = [
    #xabbergroupchat_localpart{cdata = LocalPart},
    #xabbergroupchat_name{cdata = GroupName},
    #xabbergroupchat_index{cdata = Index},
    #xabbergroupchat_privacy{cdata = Privacy},
    #xabbergroupchat_membership{cdata = Membership}
    ],
  case mod_groups_chats:create_chat(GroupHost, Owner, GroupInfo) of
    {ok, _ , _, _} ->
      {201, <<"Group created">>};
    exist ->
      {409, <<"JID already exists">> };
    _ ->
      {500, <<>>}
  end.

add_group(GroupHost, OwnerUsername, OwnerDomain, GroupName,
    LocalPart, Privacy, Index, Membership) ->
  OwnerJID = jid:make(OwnerUsername, OwnerDomain),
  case jid:to_string(OwnerJID) of
    <<>> ->
      error;
    _ ->
      Args = [{localpart, LocalPart}, {host, GroupHost},
        {owner, jid:to_string(OwnerJID)}, {name, GroupName},
        {privacy, Privacy},{index, Index}, {membership, Membership}],
      case add_group(Args) of
        {201,_} -> "created";
        {409,_} -> "error: already exist";
        _ -> "error"
      end
  end.

remove_group(Args) ->
  LUser = jid:nodeprep(proplists:get_value(localpart,Args)),
  LServer = extract_host(Args),
  JID = jid:make(LUser, LServer),
  case mod_xabber_entity:is_group(LUser, LServer) of
    true ->
      mod_groups_chats:delete_chat_hook([], LServer, <<>>, jid:to_string(JID)),
      {200, <<>>};
    _ ->
      {404, <<"Group does not exist">>}
  end.

get_groups(Args) ->
  Host = extract_host(Args),
%%  Limit = binary_to_integer(proplists:get_value(limit, Args, <<"250">>)),
%%  Page = binary_to_integer(proplists:get_value(page, Args, <<"1">>)),
  Groups = mod_groups_chats:get_all_groups_info(Host),
  GroupArray = lists:map(fun({{LocalPart, LServer, _}, InfoMap}) ->
    InfoMap1 = InfoMap#{localpart => LocalPart, host => LServer},
    {maps:to_list(InfoMap1)} end, Groups),
  {200, {[{groups,GroupArray}]}}.

get_groups_count(Args) ->
  Host = extract_host(Args),
  Count = mod_groups_chats:get_count_chats(Host),
  {200, {[{count, Count}]}}.

update_vcard(Args) ->
  {Username, Host} = extract_user_host(Args),
  VCard = proplists:get_value(vcard,Args),
  update_vcard(Username, Host, <<>>, VCard).

update_vcard(Username, Host, _Ancestor , JSON) when Username == error
  orelse Host == error  orelse not is_tuple(JSON)->
  badrequest_response();
update_vcard(Username, Host, Ancestor, {List}) ->
  lists:foreach(fun({Key, Value}) when is_binary(Value) ->
    case Ancestor of
      <<>> -> mod_admin_extra:set_vcard(Username, Host, Key, Value);
      _ -> mod_admin_extra:set_vcard(Username, Host, Ancestor, Key, Value)
    end;
    ({Key, Value}) -> update_vcard(Username, Host, Key, Value) end, List),
  {200, <<>>}.

get_vcard(Args) ->
  {Username, Host} = extract_user_host(Args),
  case check_user(Username, Host) of
    #jid{luser = LUser, lserver = LServer} ->
      case convert_vcard(mod_vcard:get_vcard(LUser, LServer)) of
        [] -> {204, {[]}};
        VCard -> {200, {[{vcard,VCard}]}}
      end;
    Result ->
      Result
  end.

add_circle(Args)->
  Circle = jid:nameprep(proplists:get_value(circle,Args)),
  Host = jid:nameprep(proplists:get_value(host, Args)),
  OldDisplay = proplists:get_value(display, Args, []),
  Display = case proplists:get_value(displayed_groups, Args) of
              L when is_list(L) -> L;
              _ -> OldDisplay
            end,
  AllUsers = case proplists:get_value(all_users, Args, false) of
               true ->
                 [{all_users, true}];
               _ -> []
             end,
  Opts = [
    {name, proplists:get_value(name, Args, Circle)},
    {description, proplists:get_value(description, Args, <<>>)},
    {displayed_groups, Display}] ++ AllUsers,
  case mod_shared_roster:create_group(Host, Circle, Opts) of
    {atomic, _} -> {200, <<>>};
    _ -> badrequest_response()
  end.

remove_circle(Args) ->
  Circle = jid:nodeprep(proplists:get_value(circle,Args)),
  Host = extract_host(Args),
  mod_shared_roster:delete_group(Host, Circle),
  {200, <<>>}.

circle_add_members(Args) ->
  circle_change_members(add, Args).

circle_remove_members(Args)->
  circle_change_members(remove, Args).

circle_change_members(Action, Args)->
  Circle = jid:nodeprep(proplists:get_value(circle,Args)),
  Host = extract_host(Args),
  Members =  proplists:get_value(members,Args),
  if
    is_list(Members) ->
      lists:foreach(fun(Member) ->
        {U, S, _} = case Member of
                      <<"@all@">> -> {<<"@all@">>, Host, <<>>};
                      M -> jid:tolower(jid:from_string(M))
                    end,
        case Action of
          add ->
            mod_shared_roster:add_user_to_group(Host, {U, S}, Circle);
          remove ->
            mod_shared_roster:remove_user_from_group(Host, {U, S}, Circle)
        end
                    end, Members),
      {200, <<>>};
    true ->
      badrequest_response()
  end.

get_circles(Args) ->
  Host = extract_host(Args),
  Circles = lists:sort(mod_shared_roster:list_groups(Host)),
  Result = {[{circles, Circles}]},
  {200, Result}.

get_circle_info(Args) ->
  Host = extract_host(Args),
  Circle = jid:nodeprep(proplists:get_value(circle,Args)),
  case mod_shared_roster:get_group_opts(Host,Circle) of
    Os when is_list(Os) -> {200, {Os}};
    error -> {404, [], [<<"circle no found">>]}
  end.

get_circle_members(Args) ->
  Host = extract_host(Args),
  Circle = jid:nodeprep(proplists:get_value(circle,Args)),
  Members = mod_shared_roster:get_group_explicit_users(Host,Circle),
  Members2 = [jid:encode(jid:make(MUser, MServer)) || {MUser, MServer} <- Members],
  Result = {[{members, Members2}]},
  {200, Result}.


check_token(Token) ->
  case ejabberd_sql:use_new_schema() of
    true ->
      check_token_new(Token);
    _ ->
      check_token_old(Token)
  end.

check_token_new(Token) ->
  Host  = hd(ejabberd_config:get_myhosts()),
  case sql_check_token_new(Host, Token) of
    {U, S} -> {ok, {U, S}};
    _ -> {false, not_found}
  end.

check_token_old(Token) ->
  Hosts  = ejabberd_config:get_myhosts(),
  Users = lists:filtermap(fun(Host) ->
    case sql_check_token_old(Host, Token) of
      error -> false;
      R -> {true, R}
    end end, Hosts),
  case Users of
    [UserServer] -> {ok, UserServer};
    _ -> {false, not_found}
  end.

extract_user_host(PropList)->
  Username = jid:nodeprep(proplists:get_value(username,PropList)),
  Host = jid:nameprep(proplists:get_value(host,PropList)),
  {Username, Host}.

extract_host(PropList) ->
  jid:nameprep(proplists:get_value(host,PropList)).

-spec seconds_since_epoch(integer()) -> non_neg_integer().
seconds_since_epoch(Diff) ->
  {Mega, Secs, _} = os:timestamp(),
  Mega * 1000000 + Secs + Diff.

kick_user_sessions(User, Server) ->
  lists:map(
    fun(Resource) ->
      ejabberd_sm:route(jid:make(User, Server, Resource),
        {exit, <<"Kicked by administrator">>})
    end,
    ejabberd_sm:get_user_resources(User, Server)).

%% SQL functions

sql_set_permissions(_User, Server, _IsAdmin, _Permissions) ->
  case ?SQL_UPSERT(Server, "panel_permissions",
    ["!username=%(_User)s",
      "!server_host=%(Server)s",
      "is_admin=%(_IsAdmin)b",
      "permissions=%(_Permissions)s"
      ]) of
    ok ->
      ok;
    _Err ->
      {error, db_failure}
  end.

sql_remove_permissions(_User, Server) ->
  case ejabberd_sql:sql_query(
    Server, ?SQL("delete from panel_permissions
     where username=%(_User)s and %(Server)H")) of
    {updated, _} ->
      ok;
    Err ->
      Err
  end.

sql_get_permissions(_User, Server) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(is_admin)b,@(permissions)s "
    "from panel_permissions where username=%(_User)s and %(Server)H")) of
    {selected,[]} ->
      {error, notfound};
    {selected,[Result]} ->
      Result;
    _ ->
      {error,internal}
  end.

sql_save_token(_LUser, LServer, _Token, _Expires) ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL_INSERT(
      "panel_tokens",
      ["username=%(_LUser)s",
        "server_host=%(LServer)s",
        "token=%(_Token)s",
        "expire=%(_Expires)d"])).

sql_remove_token(LServer, _LUser, _Token) ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from panel_tokens "
    "where username=%(_LUser)s and token=%(_Token)s and %(LServer)H")).

sql_check_token_old(LServer, _Token) ->
  _Now = seconds_since_epoch(0),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(username)s from panel_tokens "
    "where token=%(_Token)s and expire > %(_Now)d")) of
    {selected,[{Username}]} ->
      {Username, LServer};
    _->
      error
  end.

sql_check_token_new(LServer, _Token) ->
  _Now = seconds_since_epoch(0),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(username)s,@(server_host)s from panel_tokens "
    "where token=%(_Token)s and expire > %(_Now)d")) of
    {selected,[{Username, Host}]} ->
      {Username, Host};
    _->
      error
  end.
