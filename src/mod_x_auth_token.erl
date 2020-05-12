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
-export([check_token/3]).
-export([strong_rand_bytes_proxy/1,disco_sm_features/5, check_session/1]).
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
  kick_by_tocken_uid/5,
  get_token_uid/3,
  update_presence/1, c2s_handle_recv/3, c2s_stream_features/2, sasl_success/2, get_time_now/0, user_ip/1
]).

-export([oauth_token_issued/4, tokens/3, xabber_oauth_token_issued/6, xabber_revoke_token/2]).
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
  ejabberd_hooks:add(oauth_token_issued, Host, ?MODULE, oauth_token_issued, 50),
  ejabberd_hooks:add(xabber_oauth_token_issued, Host, ?MODULE, xabber_oauth_token_issued, 50),
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
  ejabberd_hooks:delete(xabber_oauth_token_issued, Host, ?MODULE, xabber_oauth_token_issued, 50),
  ejabberd_hooks:delete(sasl_success, Host, ?MODULE, sasl_success, 50),
  ejabberd_hooks:delete(c2s_handle_recv, Host, ?MODULE, c2s_handle_recv, 55),
  ejabberd_hooks:delete(c2s_post_auth_features, Host, ?MODULE,
    c2s_stream_features, 50),
  ejabberd_hooks:delete(c2s_self_presence, Host,
    ?MODULE, update_presence, 80),
  ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE, disco_sm_features, 50),
  ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 60),
  ejabberd_hooks:delete(oauth_token_issued, Host, ?MODULE, oauth_token_issued, 50),
  ejabberd_hooks:delete(c2s_session_opened, Host, ?MODULE, check_session, 50),
  gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_XABBER_TOKEN),
  gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_XABBER_TOKEN_QUERY),
  ok.

depends(_Host, _Opts) ->
  [].

oauth_token_issued(User, Server, AccessToken, TTLSeconds) ->
  SJIDNoRes = jid:make(User,Server),
  SJID = jid:to_string(SJIDNoRes),
  UID = list_to_binary(str:to_lower(binary_to_list(randoms:get_alphanum_string(32)))),
  case associate_oauth_token(Server, SJID, TTLSeconds, AccessToken, UID) of
    {ok,AccessToken,_Expire} ->
      M = newtokenoauth(UID,SJIDNoRes),
      ejabberd_router:route(M);
    _ ->
      not_ok
  end.

xabber_oauth_token_issued(User, Server, AccessToken, TTLSeconds, Browser, IP) ->
  SJIDNoRes = jid:make(User,Server),
  SJID = jid:to_string(SJIDNoRes),
  Client = <<"Web Console">>,
  UID = list_to_binary(str:to_lower(binary_to_list(randoms:get_alphanum_string(32)))),
  case associate_oauth_token(Server, SJID, TTLSeconds, AccessToken, UID, Browser, Client, IP) of
    {ok,AccessToken,_Expire} ->
      M = newtokenmsg(Client,Browser,UID,SJIDNoRes,IP),
      ejabberd_router:route(M);
    _ ->
      not_ok
  end.

sasl_success(State, Props) ->
  AuthModule = proplists:get_value(auth_module, Props),
  case AuthModule of
    mod_x_auth_token ->
      Token = proplists:get_value(token, Props),
      State#{token => Token};
    ejabberd_oauth ->
      Token = proplists:get_value(token, Props),
      State#{token => Token};
    _ ->
      State
  end.

c2s_handle_recv(State, _, #iq{type = set, sub_els = [_]} = IQ) ->
  Issue = xmpp:try_subtag(IQ, #xabbertoken_issue{}),
  Bind = xmpp:try_subtag(IQ, #bind{}),
  RevokeAll = xmpp:try_subtag(IQ, #xabbertoken_revoke_all{}),
  #{auth_module := Auth, lang := Lang, lserver := Server, user := User, stream_state := SteamState} = State,
  TokenOnly = gen_mod:get_module_opt(Server, ?MODULE,
    xabber_token_only),
  case Issue of
    #xabbertoken_issue{} when SteamState == wait_for_bind ->
      Token = issue_and_upgrade_to_token_session(IQ,User,Server,State,Issue),
      State#{auth_module => mod_x_auth_token, token => Token};
    _ when Bind =/= false andalso SteamState == wait_for_bind ->
      case Auth of
        mod_x_auth_token ->
          State;
        ejabberd_oauth ->
          #{token := Token} = State,
          case check_token(User, Server, Token) of
            true ->
              State;
            _ ->
              State#{stream_state => disconnected}
          end;
        _ when TokenOnly == true ->
          ?INFO_MSG("You have enabled option xabber_token_only. Disable it in settings, if you want to allow other authorization",[]),
          Txt = <<"Access denied by service policy. Use x-token for auth">>,
          Err = xmpp:make_error(IQ,xmpp:err_not_allowed(Txt,Lang)),
          xmpp_stream_in:send_error(State, IQ, Err),
          State#{stream_state => disconnected};
        _ ->
          State
      end;
    _ when RevokeAll =/= false andalso SteamState == wait_for_bind ->
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
    _ ->
      State
  end;
c2s_handle_recv(State, _, _) ->
  State.

check_session(State) ->
  #{auth_module := Auth} = State,
  case Auth of
    mod_x_auth_token ->
      #{ip := IP, auth_module := Auth, jid := JID, token := Token, sid := SID, resource := StateResource} = State,
      {PAddr, _PPort} = IP,
      Mod = get_mod(),
      IPs = list_to_binary(inet_parse:ntoa(PAddr)),
      #jid{lserver = LServer, luser = LUser, lresource = _LRes} = JID,
      TokenUID = get_token_uid(LServer,JID,Token),
      Reason = <<"You log in with your token from another place">>,
      maybe_kick_by_tocken_uid(LServer,LUser,TokenUID,Reason,StateResource,Mod),
      set_token_uid(LServer,SID,TokenUID, Mod),
      refresh_session_info(JID,Token,IPs);
    _ ->
      ok
  end,
  State.

-spec update_presence({presence(), ejabberd_c2s:state()})
      -> {presence(), ejabberd_c2s:state()}.
update_presence({#presence{type = available} = Pres,
  #{auth_module := mod_x_auth_token, jid := JID, token := Token, sid := SID} = State}) ->
  Mod = get_mod(),
  #jid{lserver = LServer} = JID,
  TokenUID = get_token_uid(LServer,JID,Token),
  set_token_uid(LServer,SID,TokenUID, Mod),
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
  IsExist = ejabberd_auth:user_exists(User, Server),
  case select_token(Server, UserJid, Token) of
    ok when IsExist == true ->
      true;
    _ ->
      false
  end.

issue_and_upgrade_to_token_session(Iq,User,Server,State,#xabbertoken_issue{expire = ExpireRaw, device = DeviceRaw, client = ClientRaw}) ->
  SJIDNoRes = jid:make(User,Server),
  #{ip := IP} = State,
  {PAddr, _PPort} = IP,
  IPs = list_to_binary(inet_parse:ntoa(PAddr)),
  SJID = jid:to_string(SJIDNoRes),
  Expire = set_default_time(Server,ExpireRaw),
  Device = set_default(DeviceRaw),
  Client = set_default(ClientRaw),
  ClientInfo = make_client(Client),
  DeviceInfo = make_device(Device),
  UID = list_to_binary(str:to_lower(binary_to_list(randoms:get_alphanum_string(32)))),
  case issue_token(Server, SJID, Expire, Device, Client, UID, IPs) of
    {ok,Token,ExpireTime} ->
      xmpp_stream_in:send(State,xmpp:make_iq_result(Iq,#xabbertoken_x_token{token = Token, token_uid = UID, expire = integer_to_binary(ExpireTime)})),
      ejabberd_router:route(newtokenmsg(ClientInfo,DeviceInfo,UID,SJIDNoRes,IPs)),
      Token;
    _ ->
      xmpp:make_error(Iq,xmpp:err_bad_request()),
      error
  end.

process_xabber_token(#iq{type = set, from = From, to = To,
  sub_els = [#xabbertoken_issue{expire = ExpireRaw, device = DeviceRaw, client = ClientRaw}]} = Iq) ->
  SJIDNoRes = jid:remove_resource(From),
  SJID = jid:to_string(SJIDNoRes),
  LServer = To#jid.lserver,
  Expire = set_default_time(LServer,ExpireRaw),
  Device = set_default(DeviceRaw),
  Client = set_default(ClientRaw),
  ClientInfo = make_client(Client),
  DeviceInfo = make_device(Device),
  UID = list_to_binary(str:to_lower(binary_to_list(randoms:get_alphanum_string(32)))),
  IP = ejabberd_sm:get_user_ip(From#jid.luser,LServer,From#jid.lresource),
  IPs = case IP of
          undefined ->
            <<"">>;
          _ ->
            {PAddr, _PPort} = IP,
            list_to_binary(inet_parse:ntoa(PAddr))
        end,
  case issue_token(LServer, SJID, Expire,  Device, Client, UID, IPs) of
    {ok,Token,ExpireTime} ->
      ejabberd_router:route(xmpp:make_iq_result(Iq,#xabbertoken_x_token{token = Token, token_uid = UID, expire = integer_to_binary(ExpireTime)})),
      ejabberd_router:route(To,SJIDNoRes,newtokenmsg(ClientInfo,DeviceInfo,UID,jid:remove_resource(From),IPs));
    _ ->
      xmpp:make_error(Iq,xmpp:err_bad_request())
  end;
process_xabber_token(#iq{type = get, from = From, to = To, sub_els = [#xabbertoken_query{token = undefined}]} = Iq) ->
  SJID = jid:to_string(jid:remove_resource(From)),
  LServer = To#jid.lserver,
  case list_user_tokens(LServer, SJID) of
    {ok,Tokens} ->
      TokenList = token_list_stanza(Tokens),
      xmpp:make_iq_result(Iq, TokenList);
    empty ->
      xmpp:make_error(Iq,xmpp:err_item_not_found());
    _ ->
      xmpp:make_error(Iq,xmpp:err_bad_request())
  end;
process_xabber_token(#iq{type = get, from = From, to = To, sub_els = [#xabbertoken_query{token = Token}]} = Iq) ->
  SJID = jid:to_string(jid:remove_resource(From)),
  LServer = To#jid.lserver,
  case token_info(LServer, SJID, Token) of
    {ok,Tokens} ->
      TokenList = token_list_stanza(Tokens),
      xmpp:make_iq_result(Iq, TokenList);
    empty ->
      xmpp:make_error(Iq,xmpp:err_item_not_found());
    _ ->
      xmpp:make_error(Iq,xmpp:err_bad_request())
  end;
process_xabber_token(#iq{type = set, from = From, to = To, sub_els = [#xabbertoken_revoke{token_uid = TokenUID}] = Sub} = Iq) ->
  LServer = To#jid.lserver,
  revoke_user_token(LServer, From, TokenUID),
  Message = #message{type = headline, from = To, to = jid:remove_resource(From), sub_els = Sub , id = randoms:get_string()},
  ejabberd_router:route(Message),
  xmpp:make_iq_result(Iq);
process_xabber_token(#iq{type = set, from = From, to = To, sub_els = [#xabbertoken_revoke_all{}]} = Iq) ->
  LServer = To#jid.lserver,
  LUser = From#jid.luser,
  Resource = From#jid.lresource,
   case revoke_all_except(LServer, LUser, Resource) of
     {ok,Sub} ->
       Message = #message{type = headline, from = To, to = jid:remove_resource(From), sub_els = Sub , id = randoms:get_string()},
       ejabberd_router:route(Message),
       xmpp:make_iq_result(Iq);
     _ ->
       xmpp:make_error(Iq,xmpp:err_bad_request())
   end;
process_xabber_token(Iq) ->
  xmpp:make_error(Iq,xmpp:err_feature_not_implemented()).

%%%%
%%  Internal functions
%%%%

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
  mod_groupchat_messages:binary_length(Bin).

newtokenmsg(ClientInfo,DeviceInfo,UID,BareJID,IP) ->
  User = jid:to_string(BareJID),
  Server = jid:make(BareJID#jid.lserver),
  X = #xabbertoken_x_token{token_uid = UID},
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
  UserRef = #xmppreference{'begin' = bin_len(NewLogin) + bin_len(Dear), 'end' = bin_len(NewLogin) + bin_len(Dear) + bin_len(User), type = <<"decoration">>, sub_els = [uri(User)]},
  NLR = #xmppreference{'begin' = 0, 'end' = bin_len(NewLogin), type = <<"decoration">>, sub_els = [bold()]},
  CIR = #xmppreference{'begin' = bin_len(FL), 'end' = bin_len(FL) + bin_len(ClientInfo), type = <<"decoration">>, sub_els = [bold()]},
  DR = #xmppreference{'begin' = FirstSecondLinesLength, 'end' = FirstSecondLinesLength + bin_len(ThL), type = <<"decoration">>, sub_els = [bold()]},
  SR = #xmppreference{'begin' = SettingsRefStart, 'end' = SettingsRefStart + bin_len(FilMiddle) , type = <<"decoration">>, sub_els = [bold()]},
  IPBoldReference = #xmppreference{'begin' = FirstSecondLinesLength + bin_len(ThL) , 'end' = FirstSecondLinesLength + bin_len(ThL) + bin_len(FoL), type = <<"decoratio">>, sub_els = [bold()]},
  Text = [#text{lang = <<>>,data = TextStr}],
  ID = create_id(),
  OriginID = #origin_id{id = ID},
  #message{type = chat, from = Server, to = BareJID, id =ID, body = Text, sub_els = [X,NLR,CIR,DR,IPBoldReference,SR,UserRef,OriginID]}.

newtokenoauth(UID,JID) ->
  BareJID = jid:remove_resource(JID),
  User = jid:to_string(BareJID),
  Server = jid:make(JID#jid.lserver),
  X = #xabbertoken_x_token{token_uid = UID},
  Time = get_time_now(),
  TextStr = <<"New token issued for ",User/binary,", on ",Time/binary,
    "\nIf this wasn't you, go to Account Settings > Tokens and revoke that token.">>,
  Text = [#text{lang = <<>>,data = TextStr}],
  ID = create_id(),
  OriginID = #origin_id{id = ID},
  #message{type = chat, from = Server, to = BareJID, id =ID, body = Text, sub_els = [X,OriginID]}.

token_list_stanza(Tokens) ->
  Fields = lists:map(fun(N) ->
    {UID,Expire,Device,Client,IP,Last} = N,
    #xabbertoken_field{var = randoms:get_string(), token = UID, expire = Expire, device = Device, client = Client, ip = IP, last = Last} end,
    Tokens
  ),
  #xabbertoken_x_fields{field = Fields}.

get_mod() ->
  Mod = ejabberd_config:get_option(sm_db_type),
  case Mod of
    undefined ->
      mnesia;
    _ ->
      Mod
  end.

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

%%%% SQL Functions
select_token(LServer, SJID, Token) ->
  Now = seconds_since_epoch(0),
  Res = case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(token)s"
    " from xabber_token where jid=%(SJID)s and token = %(Token)s and expire > %(Now)d")) of
    {selected, []} ->
      empty;
    {selected, [<<>>]} ->
      empty;
    {selected, [_Some]} ->
      ok;
    _ ->
      error
  end,
  Res.

set_token_uid(_LServer,SID,TokenUID, mnesia) ->
  UID = case TokenUID of
          _  when is_atom(TokenUID) ->
            TokenUID;
          _ when is_binary(TokenUID) ->
            binary_to_atom(TokenUID, latin1)
        end,
  FN = fun() ->
    [S] = mnesia:wread({session,SID}),
    mnesia:write(S#session{token_uid = UID}) end,
  mnesia:transaction(FN);
set_token_uid(_LServer,SID,TokenUID, xabber) ->
  UID = case TokenUID of
          _  when is_atom(TokenUID) ->
            TokenUID;
          _ when is_binary(TokenUID) ->
            binary_to_atom(TokenUID, latin1)
        end,
  FN = fun() ->
    [S] = mnesia:wread({session,SID}),
    mnesia:write(S#session{token_uid = UID}) end,
  mnesia:transaction(FN);
set_token_uid(LServer,SID,TokenUID, sql) ->
  {Now, Pid} = SID,
  TS = now_to_timestamp(Now),
  PidS = misc:encode_pid(Pid),
  case ?SQL_UPSERT(LServer, "sm",
    ["!usec=%(TS)d",
      "!pid=%(PidS)s",
      "token_uid=%(TokenUID)s"
      ]) of
    ok ->
      ok;
    _Err ->
      {error, db_failure}
  end.

get_resource_using_token_uid(LServer, TokenUID, sql) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(resource)s from sm where token_uid=%(TokenUID)s")) of
    {selected,[]} ->
      ok;
    {selected,[<<>>]} ->
      ok;
    {selected,[null]} ->
      ok;
    {selected,[{R}]} ->
      R;
    _ ->
      ok
  end;
get_resource_using_token_uid(_LServer, TokenUID, xabber) ->
  UID = case TokenUID of
          _  when is_atom(TokenUID) ->
            TokenUID;
          _ when is_binary(TokenUID) ->
            binary_to_atom(TokenUID, latin1)
        end,
  FN = fun()->
    mnesia:match_object(session,
      {session, '_', '_', '_', '_', '_', UID},
      read)
       end,
  {atomic,Sessions} = mnesia:transaction(FN),
  Session = lists:keyfind(session,1,Sessions),
  case Session of
    false ->
      ok;
    _ ->
      {_U,_S,R} = Session#session.usr,
      R
  end;
get_resource_using_token_uid(_LServer, TokenUID, mnesia) ->
  UID = case TokenUID of
          _  when is_atom(TokenUID) ->
            TokenUID;
          _ when is_binary(TokenUID) ->
            binary_to_atom(TokenUID, latin1)
        end,
  FN = fun()->
    mnesia:match_object(session,
      {session, '_', '_', '_', '_', '_', UID},
      read)
       end,
  {atomic,Sessions} = mnesia:transaction(FN),
  Session = lists:keyfind(session,1,Sessions),
  case Session of
    false ->
      ok;
    _ ->
      {_U,_S,R} = Session#session.usr,
      R
  end.


get_token_uid(LServer,JID,Token) ->
  SJID = jid:to_string(jid:remove_resource(JID)),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(token_uid)s from xabber_token where jid=%(SJID)s and token=%(Token)s")) of
    {selected,[]} ->
      <<"xtoken">>;
    {selected,[<<>>]} ->
      <<"xtoken">>;
    {selected,[null]} ->
      <<"xtoken">>;
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

issue_token(LServer, SJID, TTLSeconds, Device, Client, UID, IP) ->
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
      "expire=%(Expire)d"]) of
    ok ->
      {ok,Token,Expire};
    _ ->
      {error, db_failure}
  end.

associate_oauth_token(LServer, SJID, TTLSeconds, Token, UID) ->
  Expire = seconds_since_epoch(TTLSeconds),
  Description = <<"Oauth token">>,
  Device = <<"Web">>,
  TimeNow = seconds_since_epoch(0),
  case ?SQL_UPSERT(
    LServer,
    "xabber_token",
    ["!token=%(Token)s",
      "jid=%(SJID)s",
      "device=%(Device)s",
      "client=%(Description)s",
      "token_uid=%(UID)s",
      "last_usage=%(TimeNow)d",
      "expire=%(Expire)d"]) of
    ok ->
      {ok,Token,Expire};
    _ ->
      {error, db_failure}
  end.

associate_oauth_token(LServer, SJID, TTLSeconds, Token, UID, Device, Client, IP) ->
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
      "expire=%(Expire)d"]) of
    ok ->
      {ok,Token,Expire};
    _ ->
      {error, db_failure}
  end.

user_ip(JID) ->
  {User,Server,Resource} = jid:tolower(JID),
   Session = lists:keyfind(session,1,mnesia:dirty_index_read(session, {User, Server, Resource}, #session.usr)),
  case Session of
    false ->
      <<"undefined">>;
    _ ->
      Info = Session#session.info,
      {Ip, _Port} = proplists:get_value(ip, Info),
      IPS = inet_parse:ntoa(Ip),
      list_to_binary(IPS)
  end.

list_user_tokens(LServer, SJID) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(token_uid)s, @(expire)s, @(device)s, @(client)s, @(ip)s, @(last_usage)s"
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

token_info(LServer, SJID, Token) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(token_uid)s, @(expire)s, @(device)s, @(client)s, @(ip)s, @(last_usage)s"
    " from xabber_token where jid=%(SJID)s and token=%(Token)s")) of
    {selected, []} ->
      empty;
    {selected, [<<>>]} ->
      empty;
    {selected, Tokens} ->
      {ok,Tokens};
    _ ->
      error
  end.

tokens(LServer, SJID,TokenUIDs) ->
  case ejabberd_sql:sql_query(
    LServer,
    [<<"select token from xabber_token where jid = '">>, SJID ,<<"' and ">>, TokenUIDs,<<";">>]) of
    {selected, _T, [<<>>]} ->
      [];
    {selected, _T, Tokens} ->
      Tokens;
    _ ->
      []
  end.

revoke_user_token(Server,JID, UID) ->
  Mod = get_mod(),
  #jid{luser = LUser, lserver = LServer} = JID,
  BareJID = jid:to_string(jid:make(LUser,LServer,<<>>)),
  TokenUIDs = list_to_binary(form_token_uid_list(UID)),
  Tokens = tokens(LServer, BareJID,TokenUIDs),
 case ejabberd_sql:sql_query(
   Server,
   [<<"delete from xabber_token where jid= '">>, BareJID,<<"' and ">>,TokenUIDs]) of
   {updated,_N} ->
     lists:foreach(fun(N) ->
       ReasonTXT = <<"Token was revoked">>,
       kick_by_tocken_uid(Server,LUser,N,ReasonTXT, Mod) end, UID
     ),
     ?DEBUG("All Tokens to revoke ~p",[Tokens]),
     lists:foreach(fun(Tok) ->
       [Token] = Tok,
       ?DEBUG("Token to revoke ~p",[Token]),
       mod_xabber_api:xabber_revoke_user_token(BareJID,Token) end, Tokens),
     ets_cache:clear(oauth_cache),
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
  Mod = get_mod(),
  JID = jid:to_string(jid:make(User,Server)),
  Tokens = get_tokens(Server,JID),
  case remove_all_user_tokens(Server,JID) of
    ok ->
      lists:foreach(fun(N) ->
        ReasonTXT = <<"Token was revoked">>,
        {UID} = N,
        kick_by_tocken_uid(Server,User,UID,ReasonTXT, Mod) end, Tokens
      ),
      mod_xabber_api:xabber_revoke_user_token(JID,<<"all">>),
      ets_cache:clear(oauth_cache),
      ok;
    _ ->
      error
  end.

revoke_all_except(Server, User, Resource) ->
  Mod = get_mod(),
  JID = jid:make(User,Server),
  JIDs = jid:to_string(JID),
  TokensAll = get_tokens(Server,JIDs),
  SessionToken = atom_to_binary(ejabberd_sm:get_user_token(User, Server, Resource), latin1),
  Tokens = TokensAll -- [{SessionToken}],
  UIDs = [U || {U} <- Tokens],
  case revoke_user_token(Server,JID, UIDs) of
    ok ->
      lists:foreach(fun(UID) ->
        ReasonTXT = <<"Token was revoked">>,
        kick_by_tocken_uid(Server,User,UID,ReasonTXT, Mod) end, UIDs
      ),
      {ok,[#xabbertoken_revoke{token_uid = UIDs}]};
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
          Mod = get_mod(),
          JID=jid:from_string(User),
          LUser = JID#jid.luser,
          kick_by_tocken_uid(LServer,LUser,UID,ReasonTXT, Mod),
          ?DEBUG("Revoking and kicking Mod ~p",[Mod]),
          ejabberd_oauth_sql:revoke_token(Token),
          ets_cache:clear(oauth_cache),
          From = jid:make(LServer),
          To = jid:from_string(User),
          Sub = [#xabbertoken_revoke{token_uid = [UID]}],
          Message = #message{type = headline, from = From, to = To, sub_els = Sub , id = randoms:get_string()},
          ejabberd_router:route(Message);
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
kick_by_tocken_uid(_Server,_User, undefined,_Reason, _Mod) ->
  ok;
kick_by_tocken_uid(Server,User,TokenUID,Reason, Mod) ->
  Resource = get_resource_using_token_uid(Server,TokenUID, Mod),
  case Resource of
    _ when is_binary(Resource) == true ->
      mod_admin_extra:kick_session(User,Server,Resource,Reason);
    _ ->
      ok
  end.

maybe_kick_by_tocken_uid(_Server,_User, undefined,_Reason, _StateResource, _Mod) ->
  ok;
maybe_kick_by_tocken_uid(Server,User,TokenUID,Reason, StateResource, Mod) ->
  Resource = get_resource_using_token_uid(Server,TokenUID, Mod),
  case Resource of
    _ when is_binary(Resource) == true andalso StateResource =/= Resource ->
      mod_admin_extra:kick_session(User,Server,Resource,Reason);
    _ ->
      ok
  end.

form_token_uid_list(UIDs) ->
  Length = length(UIDs),
  case Length of
    0 ->
      error;
    1 ->
      [<<"token_uid = '">>] ++ UIDs ++ [<<"'">>];
    _ when Length > 1 ->
      [F|R] = UIDs,
      Rest = lists:map(fun(N) ->
        <<" or token_uid = '", N/binary, "'">>
                end, R),
      [<<"(token_uid = '", F/binary, "'">>] ++ Rest ++ [<<")">>];
    _ ->
      error
  end.

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

now_to_timestamp({MSec, Sec, USec}) ->
  (MSec * 1000000 + Sec) * 1000000 + USec.

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