%%%-------------------------------------------------------------------
%%% File    : mod_x_auth_token.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : XEP Auth Token
%%% Created : 11 Sep 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_x_auth_token).
-author('andrey.gagarin@redsolution.com').
-behavior(gen_mod).
%% API
-compile([{parse_transform, ejabberd_sql_pt}]).
-export([check_token/3, user_token_info/2, check_token/4, increase_token_count/3]).
-export([strong_rand_bytes_proxy/1, disco_sm_features/5, check_session/1]).
-export([
  stop/1,
  start/2,
  depends/2,
  mod_options/1,
  process_xabber_token/1,
  mod_opt_type/1,
  xabber_revoke_expired_token/1,
  xabber_revoke_long_time_not_used_token/2,
  remove_user/2, revoke_all/2,
  kick_by_tocken_uid/4,
  get_token_uid/3,
  update_presence/1, c2s_handle_recv/3, c2s_stream_features/2, sasl_success/2, get_time_now/0
]).

-export([xabber_revoke_token/2]).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-include("ejabberd_sm.hrl").
-include("ejabberd_commands.hrl").
%% Macros
-define(TOKEN_LENGTH, 32).

start(Host, _Opts) ->
  ejabberd_commands:register_commands(get_commands_spec()),
  ejabberd_hooks:add(c2s_self_presence, Host, ?MODULE,
    update_presence, 80),
  ejabberd_hooks:add(c2s_handle_recv, Host, ?MODULE, c2s_handle_recv, 55),
  ejabberd_hooks:add(c2s_post_auth_features, Host, ?MODULE,
    c2s_stream_features, 50),
  ejabberd_hooks:add(disco_sm_features, Host, ?MODULE, disco_sm_features, 50),
  ejabberd_hooks:add(sasl_success, Host, ?MODULE, sasl_success, 50),
  ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 60),
  ejabberd_hooks:add(c2s_session_opened, Host, ?MODULE, check_session, 50),
  gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_XABBER_TOKEN, ?MODULE, process_xabber_token),
  gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_XABBER_TOKEN_QUERY, ?MODULE, process_xabber_token),
  ok.

stop(Host) ->
  case gen_mod:is_loaded_elsewhere(Host, ?MODULE) of
    false ->
      ejabberd_commands:unregister_commands(get_commands_spec());
    true ->
      ok
  end,
  ejabberd_hooks:delete(sasl_success, Host, ?MODULE, sasl_success, 50),
  ejabberd_hooks:delete(c2s_handle_recv, Host, ?MODULE, c2s_handle_recv, 55),
  ejabberd_hooks:delete(c2s_post_auth_features, Host, ?MODULE,
    c2s_stream_features, 50),
  ejabberd_hooks:delete(c2s_self_presence, Host,
    ?MODULE, update_presence, 80),
  ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE, disco_sm_features, 50),
  ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 60),
  ejabberd_hooks:delete(c2s_session_opened, Host, ?MODULE, check_session, 50),
  gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_XABBER_TOKEN),
  gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_XABBER_TOKEN_QUERY),
  ok.

depends(_Host, _Opts) ->
  [].

sasl_success(State, Props) ->
  AuthModule = proplists:get_value(auth_module, Props),
  case AuthModule of
    mod_x_auth_token ->
      Token = proplists:get_value(token, Props),
      Count = proplists:get_value(count, Props, undefined),
      State#{token => Token, count => Count};
    _ ->
      State
  end.

c2s_handle_recv(#{stream_state := wait_for_bind} = State, _, #iq{type = set, sub_els = [_]} = IQ) ->
  Issue = xmpp:try_subtag(IQ, #xabbertoken_issue{}),
  Bind = xmpp:try_subtag(IQ, #bind{}),
  RevokeAll = xmpp:try_subtag(IQ, #xabbertoken_revoke_all{}),
  #{auth_module := Auth, lang := Lang, lserver := Server, user := User} = State,
  TokenOnly = gen_mod:get_module_opt(Server, ?MODULE, xabber_token_only),
  if
    Issue =/= false->
      Token = issue_and_upgrade_to_token_session(IQ,User,Server,State,Issue),
      State#{auth_module => mod_x_auth_token, token => Token, count => 0};
    Bind =/= false ->
      case Auth of
        mod_x_auth_token ->
          State;
        _ when TokenOnly == true ->
          ?INFO_MSG("You have enabled option xabber_token_only. Disable it in settings, if you want to allow other authorization",[]),
          Txt = <<"Access denied by service policy. Use x-token for auth">>,
          Err = xmpp:make_error(IQ,xmpp:err_not_allowed(Txt,Lang)),
          xmpp_stream_in:send_error(State, IQ, Err),
          State#{stream_state => disconnected};
        _ ->
          State
      end;
    RevokeAll =/= false ->
      case revoke_all(Server,User) of
        ok ->
          State1 = State#{stream_state => disconnected},
          xmpp_stream_in:send(State1,xmpp:make_iq_result(IQ)),
          State1;
        _ ->
          State1 = State#{stream_state => disconnected},
          Err = xmpp:make_error(IQ,xmpp:err_bad_request()),
          xmpp_stream_in:send_error(State1, IQ, Err),
          State1
      end;
    true ->
      State
  end;
c2s_handle_recv(State, _, _) ->
  State.

check_session(State) ->
  #{auth_module := Auth} = State,
  case Auth of
    mod_x_auth_token ->
      #{ip := IP, auth_module := Auth, jid := JID, token := Token, resource := StateResource} = State,
      {PAddr, _PPort} = IP,
      IPs = ip_to_binary(PAddr),
      #jid{lserver = LServer, luser = LUser, lresource = _LRes} = JID,
      TokenUID = get_token_uid(LServer,JID,Token),
      ejabberd_sm:set_user_info(LUser, LServer, StateResource, token_uid, TokenUID),
      refresh_session_info(JID,Token,IPs);
    _ ->
      ok
  end,
  State.

-spec update_presence({presence(), ejabberd_c2s:state()})
      -> {presence(), ejabberd_c2s:state()}.
update_presence({#presence{type = available} = Pres,
  #{auth_module := mod_x_auth_token, jid := JID, token := Token} = State}) ->
  #jid{lserver = LServer, luser = LUser, resource = Resource} = JID,
  TokenUID = get_token_uid(LServer,JID,Token),
  ejabberd_sm:set_user_info(LUser, LServer, Resource, token_uid, TokenUID),
  {Pres, State};
update_presence(Acc) ->
  Acc.

xabber_revoke_expired_token(Host) ->
  revoke_expired_token(Host).

xabber_revoke_long_time_not_used_token(Days,Host) ->
  case is_integer(Days) of
    true ->
      revoke_long_time_not_used_token(integer_to_binary(Days),Host);
    _ ->
     1
  end.

remove_user(User, Server) ->
  revoke_all(Server,User).
%%  remove_all_user_tokens(Server,BareJID).

check_token(User, Server, Token) ->
  UserJid = jid:to_string(jid:make(User,Server,<<>>)),
  case ejabberd_auth:user_exists(User, Server) of
    true ->
      case select_token(Server, UserJid, Token) of
        {ok, _Val} -> true;
        _ -> false
      end;
    _ ->
      false
  end.

check_token(User, Server, Token, _Count) ->
  UserJid = jid:to_string(jid:make(User,Server,<<>>)),
  case ejabberd_auth:user_exists(User, Server) of
    true ->
      case select_token(Server, UserJid, Token) of
        {ok, Val} -> {ok, Val};
        _ -> false
      end;
    _ ->
      false
  end.

issue_and_upgrade_to_token_session(Iq,User,Server,State,#xabbertoken_issue{
  expire = ExpireRaw, device = DeviceRaw, client = ClientRaw, description = DescRaw}) ->
  SJIDNoRes = jid:make(User,Server),
  #{ip := IP} = State,
  {PAddr, _PPort} = IP,
  IPs = ip_to_binary(PAddr),
  SJID = jid:to_string(SJIDNoRes),
  Expire = set_default_time(Server,ExpireRaw),
  Device = set_default(DeviceRaw),
  Client = set_default(ClientRaw),
  Desc = set_default(DescRaw),
  ClientInfo = make_client(Client),
  DeviceInfo = make_device(Device),
  UID = list_to_binary(str:to_lower(binary_to_list(randoms:get_alphanum_string(32)))),
  case issue_token(Server, SJID, Expire, Device, Client, UID, IPs, Desc) of
    {ok,Token,ExpireTime} ->
      xmpp_stream_in:send(State,xmpp:make_iq_result(Iq,#xabbertoken_xtoken{token = Token, uid = UID, expire = integer_to_binary(ExpireTime)})),
      ejabberd_router:route(newtokenmsg(ClientInfo,DeviceInfo,UID,SJIDNoRes,IPs)),
      Token;
    _ ->
      xmpp_stream_in:send(State,xmpp:make_error(Iq,xmpp:err_bad_request())),
      error
  end.

process_xabber_token(#iq{type = set, from = From, to = To,
  sub_els = [#xabbertoken_issue{expire = ExpireRaw, device = DeviceRaw, client = ClientRaw,
    description = DescRaw}]} = Iq) ->
  SJIDNoRes = jid:remove_resource(From),
  SJID = jid:to_string(SJIDNoRes),
  LServer = To#jid.lserver,
  Expire = set_default_time(LServer,ExpireRaw),
  Device = set_default(DeviceRaw),
  Client = set_default(ClientRaw),
  Desc = set_default(DescRaw),
  ClientInfo = make_client(Client),
  DeviceInfo = make_device(Device),
  UID = list_to_binary(str:to_lower(binary_to_list(randoms:get_alphanum_string(32)))),
  IP = ejabberd_sm:get_user_ip(From#jid.luser,LServer,From#jid.lresource),
  IPs = case IP of
          {PAddr, _PPort} -> ip_to_binary(PAddr);
          _ -> <<"">>
        end,
  case issue_token(LServer, SJID, Expire,  Device, Client, UID, IPs, Desc) of
    {ok,Token,ExpireTime} ->
      ejabberd_router:route(xmpp:make_iq_result(Iq,#xabbertoken_xtoken{token = Token, uid = UID, expire = integer_to_binary(ExpireTime)})),
      ejabberd_router:route(To,SJIDNoRes,newtokenmsg(ClientInfo,DeviceInfo,UID,jid:remove_resource(From),IPs));
    _ ->
      xmpp:make_error(Iq,xmpp:err_bad_request())
  end;
process_xabber_token(#iq{type = get, from = From, to = To, sub_els = [#xabbertoken_query_items{}]} = Iq) ->
  SJID = jid:to_string(jid:remove_resource(From)),
  LServer = To#jid.lserver,
  case list_user_tokens(LServer, SJID) of
    {ok,Tokens} ->
      TokenList = token_list_stanza(Tokens),
      xmpp:make_iq_result(Iq, #xabbertoken_query_items{xtokens = TokenList});
    empty ->
      xmpp:make_error(Iq,xmpp:err_item_not_found());
    _ ->
      xmpp:make_error(Iq,xmpp:err_bad_request())
  end;
process_xabber_token(#iq{type = set, from = From, to = To, sub_els = [#xabbertoken_query{xtoken = Token}]} = Iq) ->
  #xabbertoken_xtoken{device = Device, client = Client, description = Desc, uid = UID} = Token,
  LServer = To#jid.lserver,
  Resource = From#jid.lresource,
  OnlineResources = get_resources_by_token_uid(From#jid.luser, From#jid.lserver, UID),
  case lists:member(Resource, OnlineResources) of
    true ->
      case  update_token_info(LServer, UID, [{device,Device}, {client,Client}, {description,Desc}]) of
        ok ->
          xmpp:make_iq_result(Iq);
        notfound ->
          xmpp:make_error(Iq,xmpp:err_item_not_found());
        _ ->
          xmpp:make_error(Iq,xmpp:err_bad_request())
      end;
    _ ->
      xmpp:make_error(Iq,xmpp:err_not_allowed())
  end;
process_xabber_token(#iq{type = set, from = From, to = To,
  sub_els = [#xabbertoken_revoke{xtokens = Tokens}]} = Iq) ->
  LServer = To#jid.lserver,
  TokenUIDs = lists:map(fun(#xabbertoken_xtoken{uid = UID}) -> UID end, Tokens),
  case revoke_user_token(LServer, From, TokenUIDs) of
    ok ->
      xmpp:make_iq_result(Iq);
    notfound ->
      xmpp:make_error(Iq,xmpp:err_item_not_found());
    _ ->
      xmpp:make_error(Iq,xmpp:err_bad_request())
  end;
process_xabber_token(#iq{type = set, from = From, to = To, sub_els = [#xabbertoken_revoke_all{}]} = Iq) ->
  LServer = To#jid.lserver,
  LUser = From#jid.luser,
  Resource = From#jid.lresource,
   case revoke_all_except(LServer, LUser, Resource) of
     {ok,_Sub} ->
       xmpp:make_iq_result(Iq);
     notfound ->
       xmpp:make_error(Iq,xmpp:err_item_not_found());
     _ ->
       xmpp:make_error(Iq,xmpp:err_bad_request())
   end;
process_xabber_token(Iq) ->
  xmpp:make_error(Iq,xmpp:err_feature_not_implemented()).

%%%%
%%  Internal functions
%%%%

ip_to_binary(IP) ->
  IPStr = inet_parse:ntoa(IP),
  case string:prefix(IPStr, "::ffff:") of
    nomatch -> list_to_binary(IPStr); %% IPv6 address
    V -> list_to_binary(V)            %% IPv4 address
  end.

bold() ->
  #xmlel{
    name = <<"bold">>,
    attrs = [
      {<<"xmlns">>, ?NS_XABBER_MARKUP}
    ],
    children = []
  }.

uri(User) ->
  XMPP = <<"xmpp:",User/binary>>,
  #xabber_groupchat_mention{cdata = XMPP}.

bin_len(Bin) ->
  mod_groups_messages:binary_length(Bin).

newtokenmsg(ClientInfo,DeviceInfo,UID,BareJID,IP) ->
  User = jid:to_string(BareJID),
  Server = jid:make(BareJID#jid.lserver),
  X = #xabbertoken_xtoken{uid = UID},
  Time = get_time_now(),
  NewLogin = <<"New login">>,
  Dear = <<". Dear ">>,
  Detected = <<", we detected a new login into your account from a new device on ">>,
  FL = <<NewLogin/binary, Dear/binary, User/binary, Detected/binary, Time/binary, "\n\n">>,
  SL = <<ClientInfo/binary, "\n">>,
  ThL = <<DeviceInfo/binary,"\n">>,
  FoL = <<IP/binary,"\n\n">>,
  FiLStart = <<"If this wasn't you, go to ">>,
  FilMiddle = <<"Settings > XMPP Account > Active sessions">>,
  FilEnd = <<" and terminate suspicious sessions.">>,
  FiL = <<FiLStart/binary, FilMiddle/binary, FilEnd/binary>>,
  TextStr = <<FL/binary, SL/binary, ThL/binary,FoL/binary, FiL/binary>>,
  FirstSecondLinesLength = bin_len(FL) + bin_len(SL),
  SettingsRefStart =  FirstSecondLinesLength + bin_len(ThL) + bin_len(FoL) + bin_len(FiLStart),
  UserRef = #xmppreference{'begin' = bin_len(NewLogin) + bin_len(Dear),
    'end' = bin_len(NewLogin) + bin_len(Dear) + bin_len(User), type = <<"decoration">>, sub_els = [uri(User)]},
  NLR = #xmppreference{'begin' = 0, 'end' = bin_len(NewLogin), type = <<"decoration">>, sub_els = [bold()]},
  CIR = #xmppreference{'begin' = bin_len(FL), 'end' = bin_len(FL) + bin_len(ClientInfo),
    type = <<"decoration">>, sub_els = [bold()]},
  DR = #xmppreference{'begin' = FirstSecondLinesLength,
    'end' = FirstSecondLinesLength + bin_len(ThL), type = <<"decoration">>, sub_els = [bold()]},
  SR = #xmppreference{'begin' = SettingsRefStart,
    'end' = SettingsRefStart + bin_len(FilMiddle) , type = <<"decoration">>, sub_els = [bold()]},
  IPBoldReference = #xmppreference{'begin' = FirstSecondLinesLength + bin_len(ThL) ,
    'end' = FirstSecondLinesLength + bin_len(ThL) + bin_len(FoL), type = <<"decoratio">>, sub_els = [bold()]},
  Text = [#text{lang = <<>>,data = TextStr}],
  ID = create_id(),
  OriginID = #origin_id{id = ID},
  #message{type = chat, from = Server, to = BareJID, id =ID, body = Text, sub_els = [X,NLR,CIR,DR,IPBoldReference,SR,UserRef,OriginID]}.

token_list_stanza(Tokens) ->
  lists:map(fun(N) ->
    {UID,Expire,Device,Client,IP,Last, Desc} = N,
    Desc1 = case Desc of
              null -> <<"">>;
              _ -> Desc
            end,
    #xabbertoken_xtoken{uid = UID, expire = Expire,
      device = Device, client = Client, ip = IP, last_auth = Last, description = Desc1}
                     end,Tokens
  ).

set_default_time(LServer,undefined) ->
  ConfigTime =  gen_mod:get_module_opt(LServer, ?MODULE,
    xabber_token_expiration_time),
  case ConfigTime of
    undefined ->
      31536000;
    _ ->
      ConfigTime
  end;
set_default_time(_LServer,Value)->
  binary_to_integer(Value).

set_default(undefined) ->
  <<>>;
set_default(Value)->
  Value.

make_client(Client) ->
  ClientSize = bit_size(Client),
  case ClientSize of
    0 ->
      <<"Unknow client">>;
    _ ->
      Client
  end.

make_device(Device) ->
  DeviceSize = bit_size(Device),
  case DeviceSize of
    0 ->
      <<"Unknow device">>;
    _ ->
      Device
  end.

update_token_info(LServer, UID, Props) ->
  PreProps = [ atom_to_list(K) ++ "='" ++ binary_to_list(ejabberd_sql:escape(V)) ++ "'" || {K,V} <- Props,
    V =/= undefined],
  SetString = string:join(PreProps, ","),
  Query = "update xabber_token set " ++ SetString ++
    " where token_uid='" ++  binary_to_list(ejabberd_sql:escape(UID)) ++ "' ;",
  case ejabberd_sql:sql_query(LServer, Query) of
    {updated,0} ->
      notfound;
    {updated,_} ->
      ok;
    _ ->
      error
  end.


%%%% SQL Functions

increase_token_count(LServer, LUser, Token) ->
  SJID = jid:to_string(jid:make(LUser,LServer)),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update xabber_token  set count = count + 1 where jid=%(SJID)s and token = %(Token)s")).

select_token(LServer, SJID, Token) ->
  Now = seconds_since_epoch(0),
  Res = case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(token)s,@(count)d"
    " from xabber_token where jid=%(SJID)s and token = %(Token)s and expire > %(Now)d")) of
    {selected, []} ->
      undefined;
    {selected, [<<>>]} ->
      undefined;
    {selected, [Val]} ->
      {ok, Val};
    _ ->
      error
  end,
  Res.

-spec get_resources_by_token_uid(binary(), binary(), binary()) -> list().
get_resources_by_token_uid(User, Server, UID) ->
  lists:filtermap(
    fun({Resource, Info}) ->
      case lists:keyfind(token_uid, 1, Info) of
        {token_uid, UID} -> {true, Resource};
        _ -> false
      end
    end, ejabberd_sm:get_user_info(User, Server)).

get_token_uid(LServer,JID,Token) ->
  SJID = jid:to_string(jid:remove_resource(JID)),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(token_uid)s from xabber_token where jid=%(SJID)s and token=%(Token)s")) of
    {selected,[{TokenUID}]} ->
      TokenUID;
    _ ->
      <<"xtoken">>
  end.

refresh_session_info(JID,Token,IP) ->
  LServer = JID#jid.lserver,
  SJID = jid:to_string(jid:remove_resource(JID)),
  TimeNow = seconds_since_epoch(0),
  case ?SQL_UPSERT(
    LServer,
    "xabber_token",
    ["!token=%(Token)s",
      "!jid=%(SJID)s",
      "ip=%(IP)s",
      "last_usage=%(TimeNow)d"]) of
    ok ->
      ok;
    _ ->
      {error, db_failure}
  end.

issue_token(LServer, SJID, TTLSeconds, Device, Client, UID, IP, Desc) ->
  Token = generate([SJID, TTLSeconds]),
  Expire = seconds_since_epoch(TTLSeconds),
  TimeNow = seconds_since_epoch(0),
  case ?SQL_UPSERT(
    LServer,
    "xabber_token",
    ["!token=%(Token)s",
      "jid=%(SJID)s",
      "device=%(Device)s",
      "client=%(Client)s",
      "token_uid=%(UID)s",
      "ip=%(IP)s",
      "last_usage=%(TimeNow)d",
      "expire=%(Expire)d",
      "description=%(Desc)s"]) of
    ok ->
      {ok,Token,Expire};
    _ ->
      {error, db_failure}
  end.

list_user_tokens(LServer, SJID) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(token_uid)s, @(expire)s, @(device)s, @(client)s, @(ip)s, @(last_usage)s, @(description)s"
    " from xabber_token where jid=%(SJID)s order by last_usage desc")) of
    {selected, []} ->
      empty;
    {selected, [<<>>]} ->
      empty;
    {selected, Tokens} ->
      {ok,Tokens};
    _ ->
      error
  end.

-spec revoke_user_token(binary(), jid(), list()) -> ok | error.
revoke_user_token(_Server, _JID, []) ->
  notfound;
revoke_user_token(Server, JID, UIDs) ->
  #jid{luser = LUser, lserver = LServer} = JID,
  BareJID = jid:to_string(jid:make(LUser,LServer,<<>>)),
  TokenClause = token_uid_clause(UIDs),
%%  Tokens = tokens(LServer, BareJID,TokenUIDs),
 case ejabberd_sql:sql_query(
   Server,
   [<<"delete from xabber_token where jid= '">>, BareJID,<<"' and ">>,TokenClause]) of
   {updated, 0} ->
     notfound;
   {updated,_N} ->
     lists:foreach(fun(N) ->
       ReasonTXT = <<"Token was revoked">>,
       kick_by_tocken_uid(Server,LUser,N,ReasonTXT)
                   end, UIDs),
     ok;
   _ ->
     error
 end.

get_tokens(Server,JID) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(token_uid)s"
    " from xabber_token where jid=%(JID)s")) of
    {selected, []} ->
      [];
    {selected, [<<>>]} ->
      [];
    {selected, Tokens} ->
      Tokens;
    _ ->
      error
  end.

c2s_stream_features(Acc, Host) ->
  case gen_mod:is_loaded(Host, ?MODULE) of
    true ->
      [#xabbertoken_feature{}|Acc];
    false ->
      Acc
  end.

revoke_all(Server,User) ->
  JID = jid:to_string(jid:make(User,Server)),
  Tokens = get_tokens(Server,JID),
  case remove_all_user_tokens(Server,JID) of
    ok ->
      lists:foreach(fun(N) ->
        ReasonTXT = <<"Token was revoked">>,
        {UID} = N,
        kick_by_tocken_uid(Server,User,UID,ReasonTXT) end, Tokens
      ),
      ok;
    _ ->
      error
  end.

revoke_all_except(Server, User, Resource) ->
  JID = jid:make(User,Server),
  JIDs = jid:to_string(JID),
  TokensAll = get_tokens(Server,JIDs),
  SessionToken = case ejabberd_sm:get_user_info(User, Server, Resource) of
                   offline ->
                     <<>>;
                   Info -> proplists:get_value(token_uid, Info, <<>>)
                 end,
  Tokens = TokensAll -- [{SessionToken}],
  UIDs = [U || {U} <- Tokens],
  case revoke_user_token(Server,JID, UIDs) of
    ok ->
      lists:foreach(fun(UID) ->
        ReasonTXT = <<"Token was revoked">>,
        kick_by_tocken_uid(Server,User,UID,ReasonTXT) end, UIDs
      ),
      {ok,[#xabbertoken_revoke{xtokens =  [#xabbertoken_xtoken{uid = I} || I <- UIDs]}]};
    notfound ->
      notfound;
    _ ->
      error
  end.

remove_all_user_tokens(LServer,BareJID) ->
  case ejabberd_sql:sql_query(
    LServer,
    [<<"delete from xabber_token where jid= '">>, BareJID,<<"'">>]) of
    {updated,_N} ->
      ok;
    _ ->
      error
  end.

%% SQL for API
revoke_expired_token(LServer) ->
  Now = integer_to_binary(seconds_since_epoch(0)),
  case ejabberd_sql:sql_query(
    LServer,
    [<<"delete from xabber_token where expire < '">>,Now,<<"'">>]) of
    {updated,_N} ->
      ok;
    _ ->
      error
  end.

revoke_long_time_not_used_token(Days,LServer) ->
  Time = seconds_since_epoch_minus(Days*86400),
  case ejabberd_sql:sql_query(
    LServer,
    [<<"delete from xabber_token where last_usage < '">>,Time,<<"'">>]) of
    {updated,_N} ->
      ok;
    _ ->
      error
  end.

xabber_revoke_token(LServer,Token) ->
  ?DEBUG("Try revoke ~p token ~p",[LServer,Token]),
  case user_token_info(LServer,Token) of
    {ok,[{User,UID}]} ->
      ?DEBUG("Found info ~p ~p",[User,UID]),
      case ejabberd_sql:sql_query(
        LServer,
        ?SQL("delete from xabber_token where token = %(Token)s")) of
        {updated,_N} ->
          ReasonTXT = <<"Token was revoked">>,
          JID=jid:from_string(User),
          LUser = JID#jid.luser,
          kick_by_tocken_uid(LServer,LUser,UID,ReasonTXT,undefined);
        _ ->
          1
      end;
    _ ->
      1
  end.

user_token_info(LServer, Token) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(jid)s,@(token_uid)s"
    " from xabber_token where token=%(Token)s")) of
    {selected, []} ->
      empty;
    {selected, [<<>>]} ->
      empty;
    {selected, Tokens} ->
      {ok,Tokens};
    _ ->
      error
  end.

%%%% END SQL Functions
kick_by_tocken_uid(_Server,_User, undefined,_Reason) ->
  ok;
kick_by_tocken_uid(Server,User,TokenUID,Reason) ->
  NotifyFun = fun(User_,Server_,Resource_,TokenUID_) ->
    From =  jid:from_string(Server_),
    Message = #message{type = headline, from = From, to = jid:make(User_, Server_, Resource_),
      id = randoms:get_string(),
      sub_els = [#xabbertoken_revoke{xtokens = [#xabbertoken_xtoken{uid = TokenUID_}]}]},
    ejabberd_router:route(Message) end,
  kick_by_tocken_uid(Server,User,TokenUID,Reason,NotifyFun).


kick_by_tocken_uid(Server,User,TokenUID,Reason, NotifyFun) ->
  Resources = get_resources_by_token_uid(User,Server,TokenUID),
  lists:foreach(fun(Resource) ->
    case NotifyFun of
      undefined -> ok;
      _ -> NotifyFun(User, Server, Resource,TokenUID)
    end,
  mod_admin_extra:kick_session(User,Server,Resource,Reason)
                end, Resources).

token_uid_clause(UIDs) ->
  Begin = <<"token_uid in (">>,
  Fin = <<") ">>,
  L = [binary_to_list(<<$',U/binary,$'>>) || U <- UIDs, U /= <<>>],
  UIDValues = case string:join(L, ",") of
                [] -> <<"null">>;
                S -> list_to_binary(S)
              end,
  <<Begin/binary,UIDValues/binary,Fin/binary>>.

generate(_Context) -> generate_fragment(?TOKEN_LENGTH).

%%%_* Private functions ================================================
-spec generate_fragment(integer()) -> binary().
generate_fragment(0) -> <<>>;
generate_fragment(N) ->
  Rand = base64:encode(rand_bytes(N)),
  Frag = << <<C>> || <<C>> <= <<Rand:N/bytes>>, is_alphanum(C) >>,
  <<Frag/binary, (generate_fragment(N - byte_size(Frag)))/binary>>.

%% @doc Returns true for alphanumeric ASCII characters, false for all others.
-spec is_alphanum(char()) -> boolean().
is_alphanum(C) when C >= 16#30 andalso C =< 16#39 -> true;
is_alphanum(C) when C >= 16#41 andalso C =< 16#5A -> true;
is_alphanum(C) when C >= 16#61 andalso C =< 16#7A -> true;
is_alphanum(_)                                    -> false.

%% @doc Generate N random bytes, using the crypto:strong_rand_bytes
%%      function if sufficient entropy exists. If not, use crypto:rand_bytes
%%      as a fallback.
-spec rand_bytes(non_neg_integer()) -> binary().
rand_bytes(N) ->
  try
    %% NOTE: Apparently we can't meck away the crypto module,
    %% so we install this proxy to allow for testing the low_entropy
    %% situation.
    ?MODULE:strong_rand_bytes_proxy(N)
  catch
    throw:low_entropy ->
      crypto:strong_rand_bytes(N)
  end.

%% @equiv crypto:strong_rand_bytes(N)
-spec strong_rand_bytes_proxy(non_neg_integer()) -> binary().
strong_rand_bytes_proxy(N) -> crypto:strong_rand_bytes(N).

-spec seconds_since_epoch(integer()) -> non_neg_integer().
seconds_since_epoch(Diff) ->
  {Mega, Secs, _} = os:timestamp(),
  Mega * 1000000 + Secs + Diff.

-spec seconds_since_epoch_minus(integer()) -> non_neg_integer().
seconds_since_epoch_minus(Diff) ->
  {Mega, Secs, _} = os:timestamp(),
  Mega * 1000000 + Secs - Diff.

get_commands_spec() ->
  [
    #ejabberd_commands{name = xabber_revoke_token, tags = [xabber],
      desc = "Delete token",
      longdesc = "Type host and token to delete selected token.",
      module = ?MODULE, function = xabber_revoke_token,
      args_desc = ["Host","Token"],
      args_example = [<<"capulet.lit">>,<<"a123qwertyToken">>],
      args = [{host, binary},{token, binary}],
      result = {res, rescode},
      result_example = 0,
      result_desc = "Returns integer code:\n"
      " - 0: operation succeeded\n"
      " - 1: error: sql query error"},
    #ejabberd_commands{name = xabber_revoke_expired_token, tags = [xabber],
      desc = "Delete expired tokens",
      longdesc = "Type 'your.host' to delete expired tokens from selected host.",
      module = ?MODULE, function = xabber_revoke_expired_token,
      args_desc = ["Host"],
      args_example = [<<"capulet.lit">>],
      args = [{host, binary}],
      result = {res, rescode},
      result_example = 0,
      result_desc = "Returns integer code:\n"
      " - 0: operation succeeded\n"
      " - 1: error: sql query error"},
    #ejabberd_commands{name = xabber_revoke_long_time_unused_token, tags = [xabber],
      desc = "Delete xabber tokens which not used more than DAYS ",
      longdesc = "",
      module = ?MODULE, function = xabber_revoke_long_time_not_used_token,
      args_desc = ["Days to keep unsed token", "Host"],
      args_example = [30, <<"capulet.lit">>],
      args = [{days, integer}, {host, binary}],
      result = {res, rescode}}
  ].


get_time_now() ->
  {{Y,Mo,D}, {H,Mn,S}} = calendar:universal_time(),
  FmtStr = "~2.10.0B/~2.10.0B/~4.10.0B at ~2.10.0B:~2.10.0B:~2.10.0B UTC",
  IsoStr = io_lib:format(FmtStr, [D, Mo, Y, H, Mn, S]),
  list_to_binary(IsoStr).

-spec disco_sm_features({error, stanza_error()} | {result, [binary()]} | empty,
                                             jid(), jid(), binary(), binary()) ->
                                {error, stanza_error()} | {result, [binary()]}.
disco_sm_features({error, Err}, _From, _To, _Node, _Lang) ->
        {error, Err};
disco_sm_features(empty, _From, _To, <<"">>, _Lang) ->
        {result, [?NS_XABBER_TOKEN]};
disco_sm_features({result, Feats}, _From, _To, <<"">>, _Lang) ->
        {result, [?NS_XABBER_TOKEN|Feats]};
disco_sm_features(Acc, _From, _To, _Node, _Lang) ->
        Acc.

-spec create_id() -> binary().
create_id() ->
  A = randoms:get_alphanum_string(10),
  B = randoms:get_alphanum_string(4),
  C = randoms:get_alphanum_string(4),
  D = randoms:get_alphanum_string(4),
  E = randoms:get_alphanum_string(10),
  ID = <<A/binary, "-", B/binary, "-", C/binary, "-", D/binary, "-", E/binary>>,
  list_to_binary(string:to_lower(binary_to_list(ID))).

mod_opt_type(xabber_token_expiration_time) ->
  fun(I) when is_integer(I), I > 0 -> I end;
mod_opt_type(xabber_token_only) ->
  fun (B) when is_boolean(B) -> B end.

mod_options(_Host) -> [
  {xabber_token_expiration_time, 31536000},
  {xabber_token_only, false}
].
