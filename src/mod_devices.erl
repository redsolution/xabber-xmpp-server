%%%-------------------------------------------------------------------
%%% File    : mod_devices.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : XEP Devices
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

-module(mod_devices).
-author('ilya.kalashnikov@redsolution.com').
-behavior(gen_mod).
%% API
-compile([{parse_transform, ejabberd_sql_pt}]).
-export([check_token/3, set_count/4]).

%% gen_mod
-export([
  stop/1,
  start/2,
  depends/2,
  mod_options/1,
  mod_opt_type/1
]).
%% Commands
-export([
  revoke_device/3,
  delete_expired_devices/1,
  revoke_long_unused_devices/2
]).
%% Hoks
-export([
  update_presence/1,
  c2s_handle_recv/3,
  c2s_stream_features/2,
  disco_sm_features/5,
  sasl_success/2,
  remove_user/2,
  check_session/1,
  process_iq/1
]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-include("ejabberd_sm.hrl").
-include("ejabberd_commands.hrl").


start(Host, _Opts) ->
  ejabberd_commands:register_commands(get_commands_spec()),
  ejabberd_hooks:add(c2s_self_presence, Host, ?MODULE, update_presence, 80),
  ejabberd_hooks:add(c2s_handle_recv, Host, ?MODULE, c2s_handle_recv, 55),
  ejabberd_hooks:add(c2s_post_auth_features, Host, ?MODULE, c2s_stream_features, 50),
  ejabberd_hooks:add(disco_sm_features, Host, ?MODULE, disco_sm_features, 50),
  ejabberd_hooks:add(sasl_success, Host, ?MODULE, sasl_success, 50),
  ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 60),
  ejabberd_hooks:add(c2s_session_opened, Host, ?MODULE, check_session, 50),
  gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_DEVICES, ?MODULE, process_iq),
  gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_DEVICES_QUERY, ?MODULE, process_iq),
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
  ejabberd_hooks:delete(c2s_post_auth_features, Host, ?MODULE, c2s_stream_features, 50),
  ejabberd_hooks:delete(c2s_self_presence, Host, ?MODULE, update_presence, 80),
  ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE, disco_sm_features, 50),
  ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 60),
  ejabberd_hooks:delete(c2s_session_opened, Host, ?MODULE, check_session, 50),
  gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_DEVICES),
  gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_DEVICES_QUERY),
  ok.

depends(_Host, _Opts) ->
  [].

mod_opt_type(device_expiration_time) ->
  fun(I) when is_integer(I), I > 0 -> I end;
mod_opt_type(hotp_only) ->
  fun (B) when is_boolean(B) -> B end.

mod_options(_Host) -> [
  {device_expiration_time, 31536000},
  {hotp_only, false}
].

%%%%
%%  Hooks
%%%%

c2s_stream_features(Acc, Host) ->
  case gen_mod:is_loaded(Host, ?MODULE) of
    true ->
      [#devices_feature{}|Acc];
    false ->
      Acc
  end.

-spec disco_sm_features({error, stanza_error()} | {result, [binary()]} | empty,
    jid(), jid(), binary(), binary()) ->
  {error, stanza_error()} | {result, [binary()]}.
disco_sm_features({error, Err}, _From, _To, _Node, _Lang) ->
  {error, Err};
disco_sm_features(empty, _From, _To, <<"">>, _Lang) ->
  {result, [?NS_DEVICES]};
disco_sm_features({result, Feats}, _From, _To, <<"">>, _Lang) ->
  {result, [?NS_DEVICES|Feats]};
disco_sm_features(Acc, _From, _To, _Node, _Lang) ->
  Acc.

sasl_success(State, Props) ->
  case proplists:get_value(auth_module, Props) of
    mod_devices ->
      DeviceID = proplists:get_value(device_id, Props),
      State#{device_id => DeviceID};
    _ ->
      State
  end.

c2s_handle_recv(#{stream_state := wait_for_bind} = State, _, #iq{type = set, sub_els = [_]} = IQ) ->
  Register = xmpp:try_subtag(IQ, #device_register{}),
  Bind = xmpp:try_subtag(IQ, #bind{}),
  RevokeAll = xmpp:try_subtag(IQ, #devices_revoke_all{}),
  #{auth_module := Auth, lang := Lang, lserver := Server, user := User} = State,
  HOTPOnly = gen_mod:get_module_opt(Server, ?MODULE, hotp_only),
  if
    Register =/= false andalso Auth =/= mod_devices ->
      case register_and_upgrade_to_hotp_session(IQ,User,Server,State, Register) of
        error when HOTPOnly == true -> State#{stream_state => disconnected};
        error -> State;
        DeviceID -> State#{auth_module => mod_devices, device_id => DeviceID}
      end;
    Bind =/= false ->
      case Auth of
        mod_devices ->
          State;
        _ when HOTPOnly == true ->
          ?INFO_MSG("You have enabled option hotp_only. Disable it in settings, if you want to allow other authorization",[]),
          Txt = <<"Access denied by service policy. Use HOTP for auth">>,
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
    mod_devices ->
      #{ip := IP, jid := JID, device_id := DeviceID, resource := StateResource} = State,
      {PAddr, _PPort} = IP,
      IPs = ip_to_binary(PAddr),
      #jid{lserver = LServer, luser = LUser, lresource = _LRes} = JID,
      ejabberd_sm:set_user_info(LUser, LServer, StateResource, device_id, DeviceID),
      sql_refresh_session_info(JID,DeviceID,IPs);
    _ ->
      ok
  end,
  State.

-spec update_presence({presence(), ejabberd_c2s:state()})
      -> {presence(), ejabberd_c2s:state()}.
update_presence({#presence{type = available} = Pres,
  #{auth_module := mod_devices, jid := JID, device_id := DeviceID} = State}) ->
  #jid{lserver = LServer, luser = LUser, resource = Resource} = JID,
  ejabberd_sm:set_user_info(LUser, LServer, Resource, device_id, DeviceID),
  {Pres, State};
update_presence(Acc) ->
  Acc.

process_iq(#iq{type = set, from = From, to = To,
%%  sub_els = [#device_register{expire = ExpireRaw, info = InfoRaw, client = ClientRaw,
%%    description = DescRaw}]} = Iq) ->
  sub_els = [#device_register{device = #devices_device{id = undefined,
    expire = TTLRaw, info = InfoRaw, client = ClientRaw, description = DescRaw}}]} = Iq) ->
  UserBareJID = jid:remove_resource(From),
  SJID = jid:to_string(UserBareJID),
  LServer = To#jid.lserver,
  TTL = set_default_ttl(LServer, TTLRaw),
  Info = set_default(InfoRaw),
  Client = set_default(ClientRaw),
  Desc = set_default(DescRaw),
  ID = list_to_binary(str:to_lower(binary_to_list(randoms:get_alphanum_string(32)))),
  IP = ejabberd_sm:get_user_ip(From#jid.luser,LServer,From#jid.lresource),
  IPs = case IP of
          {PAddr, _PPort} -> ip_to_binary(PAddr);
          _ -> <<"">>
        end,
  case sql_register_device(LServer, SJID, TTL, Info, Client, ID, IPs, Desc) of
    {ok,Secret,ExpireTime} ->
      ejabberd_router:route(xmpp:make_iq_result(Iq,
        #devices_device{secret = Secret, id = ID, expire = integer_to_binary(ExpireTime)})),
      ejabberd_router:route(To, UserBareJID, new_device_msg(Client,Info, ID,UserBareJID,IPs)),
      ignore;
    _ ->
      xmpp:make_error(Iq,xmpp:err_bad_request())
  end;
process_iq(#iq{type = set, from = From, to = To,
  sub_els = [#device_register{device = #devices_device{id = DeviceID,
    expire = TTLRaw, info = Info, client = Client, description = Desc} = Device}]} = Iq) ->
  Resource = From#jid.lresource,
  OnlineResources = get_resources_by_device_id(From#jid.luser, From#jid.lserver, DeviceID),
  case lists:member(Resource, OnlineResources) of
    true ->
      Server = To#jid.lserver,
      Secret = make_secret(),
      Expire = integer_to_binary(seconds_since_epoch(set_default_ttl(Server, TTLRaw))),
      Props = [{count, <<$0>>},{secret,Secret}, {info,Info}, {client,Client}, {description,Desc}, {expire, Expire}],
      case update_device(Server, From, DeviceID, Props ) of
        ok ->
          xmpp:make_iq_result(Iq, Device#devices_device{secret = Secret,expire = Expire});
        notfound ->
          xmpp:make_error(Iq,xmpp:err_item_not_found());
        _ ->
          xmpp:make_error(Iq,xmpp:err_bad_request())
      end;
    _->
      xmpp:make_error(Iq,xmpp:err_not_allowed())
  end;
process_iq(#iq{type = get, from = From, to = To, sub_els = [#devices_query_items{}]} = Iq) ->
  SJID = jid:to_string(jid:remove_resource(From)),
  LServer = To#jid.lserver,
  case sql_select_user_devices(LServer, SJID) of
    {ok,Devices} ->
      DeviceList = device_list_stanza(Devices),
      xmpp:make_iq_result(Iq, #devices_query_items{devices = DeviceList});
    empty ->
      xmpp:make_error(Iq,xmpp:err_item_not_found());
    _ ->
      xmpp:make_error(Iq,xmpp:err_bad_request())
  end;
process_iq(#iq{type = set, sub_els = [#devices_query{device = #devices_device{id = undefined}}]} = Iq) ->
  xmpp:make_error(Iq,xmpp:err_bad_request());
process_iq(#iq{type = set, from = From, to = To, sub_els = [
  #devices_query{device = #devices_device{info = Info, client = Client, description = Desc, id = ID}}]} = Iq) ->
  LServer = To#jid.lserver,
  Resource = From#jid.lresource,
  OnlineResources = get_resources_by_device_id(From#jid.luser, From#jid.lserver, ID),
  case lists:member(Resource, OnlineResources) of
    true ->
      case  update_device(LServer, From, ID, [{info,Info}, {client,Client}, {description,Desc}]) of
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
process_iq(#iq{type = set, from = From,
  sub_els = [#devices_revoke{devices = Devices}]} = Iq) ->
  LServer = From#jid.lserver,
  LUser = From#jid.luser,
  DeviceIDs = lists:map(fun(#devices_device{id = ID}) -> ID end, Devices),
  case sql_revoke_devices(LUser, LServer, DeviceIDs) of
    ok ->
      ReasonTXT = <<"Device was revoked">>,
      lists:foreach(fun(N) -> kick_by_device_id(LServer,LUser,N,ReasonTXT) end, DeviceIDs),
      xmpp:make_iq_result(Iq);
    notfound ->
      xmpp:make_error(Iq,xmpp:err_item_not_found());
    _ ->
      xmpp:make_error(Iq,xmpp:err_bad_request())
  end;
process_iq(#iq{type = set, from = From, to = To, sub_els = [#devices_revoke_all{}]} = Iq) ->
  LServer = To#jid.lserver,
  LUser = From#jid.luser,
  Resource = From#jid.lresource,
  case revoke_all_except(LServer, LUser, Resource) of
    ok ->
      xmpp:make_iq_result(Iq);
    notfound ->
      xmpp:make_error(Iq,xmpp:err_item_not_found());
    _ ->
      xmpp:make_error(Iq,xmpp:err_bad_request())
  end;
process_iq(Iq) ->
  xmpp:make_error(Iq,xmpp:err_feature_not_implemented()).


remove_user(User, Server) ->
  revoke_all(Server,User).

%%%%
%%  Commands
%%%%

delete_expired_devices(Host) ->
  case sql_delete_expired_devices(Host) of
    ok-> 0;
    _-> 1
  end.

revoke_long_unused_devices(Days,Host) ->
  case is_integer(Days) of
    true ->
      case sql_revoke_long_unused_devices(integer_to_binary(Days),Host) of
        ok-> 0;
        _-> 1
      end;
    _ ->
     1
  end.

revoke_device(LServer, LUser, DeviceID) ->
  SJID = jid:to_string(jid:make({LUser,LServer})),
  case sql_delete_device(LServer,SJID,DeviceID) of
    ok->
      ReasonTXT = <<"Token was revoked">>,
      kick_by_device_id(LServer,LUser,DeviceID,ReasonTXT);
    _ ->
      1
  end.

%%%%
%%  API
%%%%

check_token(User, Server, Token) ->
  case ejabberd_auth:user_exists(User, Server) of
    true ->
      check_token_2(User, Server, Token);
    _ ->
      false
  end.

check_token_2(User, Server, Token) ->
  SJID = jid:to_string(jid:make(User,Server,<<>>)),
  Secrets = sql_select_secrets(Server, SJID),
  ResultList = lists:filtermap(fun({Secret, Count, ID, Expire})->
    Options = [{last,Count}, {trials,3}, {return_interval, true}],
    IsValid = hotp:valid_hotp(Token, Secret, Options),
    case IsValid of
      {true, Interval} -> {true, {ID, Interval, Expire}};
      _ -> false
     end end, Secrets),
  case ResultList of
    [{ID, NewCount, Expire}] ->
      Now = seconds_since_epoch(0),
      if
        Expire > Now ->
          {ok, {ID, NewCount}};
        true ->
          sql_delete_device(Server,SJID,ID),
          expared
      end;
    _ -> false
  end.

register_and_upgrade_to_hotp_session(Iq,User,Server,State,#device_register{device = #devices_device{
  id = undefined, expire = TTLRaw, info = InfoRaw, client = ClientRaw, description = DescRaw}}) ->
  SJIDNoRes = jid:make(User,Server),
  #{ip := IP} = State,
  {PAddr, _PPort} = IP,
  IPs = ip_to_binary(PAddr),
  SJID = jid:to_string(SJIDNoRes),
  TTL = set_default_ttl(Server, TTLRaw),
  Info = set_default(InfoRaw),
  Client = set_default(ClientRaw),
  Desc = set_default(DescRaw),
  ID = list_to_binary(str:to_lower(binary_to_list(randoms:get_alphanum_string(32)))),
  case sql_register_device(Server, SJID, TTL, Info, Client, ID, IPs, Desc) of
    {ok,Secret,ExpireTime} ->
      xmpp_stream_in:send(State,xmpp:make_iq_result(Iq,
        #devices_device{secret = Secret, id = ID, expire = integer_to_binary(ExpireTime)})),
      ejabberd_router:route(new_device_msg(Client,Info, ID,SJIDNoRes,IPs)),
      ID;
    _ ->
      xmpp_stream_in:send(State,xmpp:make_error(Iq,xmpp:err_bad_request())),
      error
  end;
register_and_upgrade_to_hotp_session(Iq,User,Server,State,#device_register{device = #devices_device{
  id = DeviceID, expire = TTLRaw, info = Info, client = Client, description = Desc} = Device}) ->
  SJID = jid:to_string(jid:make(User,Server)),
  Secret = make_secret(),
  Expire = integer_to_binary(seconds_since_epoch(set_default_ttl(Server, TTLRaw))),
  Props = [{count, <<$0>>},{secret,Secret}, {info,Info}, {client,Client}, {description,Desc}, {expire, Expire}],
  case update_device(Server, SJID, DeviceID, Props ) of
    ok ->
      xmpp_stream_in:send(State,xmpp:make_iq_result(Iq,
        Device#devices_device{secret = Secret,expire = Expire})),
      DeviceID;
    notfound ->
      xmpp_stream_in:send(State,xmpp:make_error(Iq,xmpp:err_item_not_found())),
      error;
    _ ->
      xmpp_stream_in:send(State,xmpp:make_error(Iq,xmpp:err_bad_request())),
      error
  end.

set_count(User, Server, DeviceID, Count) ->
  sql_update_count(User, Server, DeviceID, Count).



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

bin_len(Binary) ->
  B1 = binary:replace(Binary,<<"&">>,<<"&amp;">>,[global]),
  B2 = binary:replace(B1,<<">">>,<<"&gt;">>,[global]),
  B3 = binary:replace(B2,<<"<">>,<<"&lt;">>,[global]),
  B4 = binary:replace(B3,<<"\"">>,<<"&quot;">>,[global]),
  B5 = binary:replace(B4,<<"\'">>,<<"&apos;">>,[global]),
  string:len(unicode:characters_to_list(B5)).

new_device_msg(<<>>, Info, DeviceID, BareJID, IP) ->
  new_device_msg(<<"Unknow client">>, Info, DeviceID, BareJID, IP);
new_device_msg(Client, <<>>, DeviceID ,BareJID, IP) ->
  new_device_msg(Client, <<"Unknow device">>, DeviceID, BareJID, IP);
new_device_msg(Client,Info, DeviceID,BareJID,IP) ->
  User = jid:to_string(BareJID),
  Server = jid:make(BareJID#jid.lserver),
  X = #devices_device{id = DeviceID},
  Time = get_time_now(),
  NewLogin = <<"New login">>,
  Dear = <<". Dear ">>,
  Detected = <<", we detected a new login into your account from a new device on ">>,
  FL = <<NewLogin/binary, Dear/binary, User/binary, Detected/binary, Time/binary, "\n\n">>,
  SL = <<Client/binary, "\n">>,
  ThL = <<Info/binary,"\n">>,
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
  CIR = #xmppreference{'begin' = bin_len(FL), 'end' = bin_len(FL) + bin_len(Info),
    type = <<"decoration">>, sub_els = [bold()]},
  DR = #xmppreference{'begin' = FirstSecondLinesLength,
    'end' = FirstSecondLinesLength + bin_len(ThL), type = <<"decoration">>, sub_els = [bold()]},
  SR = #xmppreference{'begin' = SettingsRefStart,
    'end' = SettingsRefStart + bin_len(FilMiddle) , type = <<"decoration">>, sub_els = [bold()]},
  IPBoldReference = #xmppreference{'begin' = FirstSecondLinesLength + bin_len(ThL) ,
    'end' = FirstSecondLinesLength + bin_len(ThL) + bin_len(FoL), type = <<"decoratio">>, sub_els = [bold()]},
  Text = [#text{lang = <<>>,data = TextStr}],
  ID = randoms:get_string(),
  OriginID = #origin_id{id = ID},
  #message{type = chat, from = Server, to = BareJID, id =ID, body = Text,
    sub_els = [X,NLR,CIR,DR,IPBoldReference,SR,UserRef,OriginID]}.

device_list_stanza(Devices) ->
  lists:map(fun(Device) ->
    CheckedValues = check_values(Device) ,
    [ID, Expire, Info, Client, IP, Last, Desc] = CheckedValues,
    #devices_device{id = ID, expire = Expire,
      info = Info, client = Client, ip = IP, last_auth = Last, description = Desc}
                     end, Devices).

check_values(Tuple) ->
  List = [element(I,Tuple) || I <- lists:seq(1,tuple_size(Tuple))],
  lists:map(
    fun(null) -> undefined;
      (<<>>) -> undefined;
      (V) -> V
    end, List).


set_default_ttl(LServer,undefined) ->
  ConfigTime =  gen_mod:get_module_opt(LServer, ?MODULE,
    device_expiration_time),
  case ConfigTime of
    undefined ->
      31536000;
    _ ->
      ConfigTime
  end;
set_default_ttl(_LServer,Value)->
  binary_to_integer(Value).

set_default(undefined) ->
  <<>>;
set_default(Value)->
  Value.

-spec get_resources_by_device_id(binary(), binary(), binary()) -> list().
get_resources_by_device_id(User, Server, ID) ->
  lists:filtermap(
    fun({Resource, Info}) ->
      case lists:keyfind(device_id, 1, Info) of
        {device_id, ID} -> {true, Resource};
        _ -> false
      end
    end, ejabberd_sm:get_user_info(User, Server)).

update_device(LServer, JID, ID, Props) when is_record(JID, jid) ->
  SJID = jid:to_string(jid:remove_resource(JID)),
  update_device(LServer, SJID, ID, Props);
update_device(LServer, SJID, ID, Props) ->
  PreProps = [ atom_to_list(K) ++ "=" ++ prepare_value(V) || {K,V} <- Props,
    V =/= undefined],
  SetString = string:join(PreProps, ","),
  EJID = "'" ++ binary_to_list(ejabberd_sql:escape(SJID)) ++ "'",
  EID = "'" ++ binary_to_list(ejabberd_sql:escape(ID)) ++ "'",
  Query = "update devices set " ++ SetString ++
    " where jid=" ++ EJID ++ " and device_id=" ++  EID  ++ ";",
  case ejabberd_sql:sql_query(LServer, Query) of
    {updated,0} ->
      notfound;
    {updated,_} ->
      ok;
    _ ->
      error
  end.

prepare_value(V) when is_binary(V) ->
  "'" ++ binary_to_list(ejabberd_sql:escape(V)) ++ "'";
prepare_value(V) when is_integer(V) ->
  integer_to_list(V);
prepare_value(_V) ->
  "''".

%%update_device_info(LServer, ID, Props) ->
%%  PreProps = [ atom_to_list(K) ++ "='" ++ binary_to_list(ejabberd_sql:escape(V)) ++ "'" || {K,V} <- Props,
%%    V =/= undefined],
%%  SetString = string:join(PreProps, ","),
%%  Query = "update devices set " ++ SetString ++
%%    " where device_id='" ++  binary_to_list(ejabberd_sql:escape(ID)) ++ "' ;",
%%  case ejabberd_sql:sql_query(LServer, Query) of
%%    {updated,0} ->
%%      notfound;
%%    {updated,_} ->
%%      ok;
%%    _ ->
%%      error
%%  end.

%%%% SQL Functions

sql_update_count(LUser, LServer, _DeviceID, _Count) ->
  _SJID = jid:to_string(jid:make(LUser,LServer)),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update devices set count=%(_Count)d where jid=%(_SJID)s and device_id = %(_DeviceID)s")).

sql_select_secrets(LServer, _SJID) ->
 case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(secret)s,@(count)d,@(device_id)s,@(expire)d"
    " from devices where jid=%(_SJID)s")) of
    {selected, Val} ->
      Val;
    _ ->
      []
  end.

sql_refresh_session_info(JID,_DeviceID,_IP) ->
  LServer = JID#jid.lserver,
  _SJID = jid:to_string(jid:remove_resource(JID)),
  _TimeNow = seconds_since_epoch(0),
  case ?SQL_UPSERT(
    LServer,
    "devices",
    ["!device_id=%(_DeviceID)s",
      "!jid=%(_SJID)s",
      "ip=%(_IP)s",
      "last_usage=%(_TimeNow)d"]) of
    ok ->
      ok;
    _ ->
      {error, db_failure}
  end.

sql_register_device(LServer, _SJID, TTLSeconds, _Info, _Client, _ID, _IP, _Desc) ->
  _Secret = make_secret(),
  _Expire = seconds_since_epoch(TTLSeconds),
  _TimeNow = seconds_since_epoch(0),
  case ?SQL_UPSERT(
    LServer,
    "devices",
    ["!device_id=%(_ID)s",
      "!jid=%(_SJID)s",
      "info=%(_Info)s",
      "client=%(_Client)s",
      "secret=%(_Secret)s",
      "ip=%(_IP)s",
      "last_usage=%(_TimeNow)d",
      "expire=%(_Expire)d",
      "description=%(_Desc)s"]) of
    ok ->
      {ok,_Secret,_Expire};
    _ ->
      {error, db_failure}
  end.

sql_select_user_devices(LServer, _SJID) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(device_id)s, @(expire)s, @(info)s, @(client)s, @(ip)s, @(last_usage)s, @(description)s"
    " from devices where jid=%(_SJID)s and expire!=0 order by last_usage desc")) of
    {selected, []} ->
      empty;
    {selected, [<<>>]} ->
      empty;
    {selected, Devices} ->
      {ok,Devices};
    _ ->
      error
  end.

-spec sql_revoke_devices(binary(), binary(), list()) -> ok | error.
sql_revoke_devices(_LUser, _LServer, []) ->
  notfound;
sql_revoke_devices(LUser, LServer, IDs) ->
  BareJID = jid:to_string(jid:make(LUser,LServer,<<>>)),
  IDClause = device_id_clause(IDs),
 case ejabberd_sql:sql_query(
   LServer,
   [<<"update devices set expire=0 where jid= '">>, BareJID,<<"' and ">>, IDClause]) of
   {updated, 0} ->
     notfound;
   {updated,_N} ->
     ok;
   _ ->
     error
 end.

sql_get_device_ids(Server,_JID) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(device_id)s"
    " from devices where jid=%(_JID)s")) of
    {selected, Devices} ->
      [ID || {ID} <- Devices];
    _ ->
      error
  end.

sql_revoke_all_devices(LServer,BareJID) ->
  case ejabberd_sql:sql_query(
    LServer,
    [<<"update devices set expire=0 where jid= '">>, BareJID,<<"'">>]) of
    {updated,_N} ->
      ok;
    _ ->
      error
  end.

sql_delete_device(Server,_SJID,_ID) ->
 case ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from devices where jid=%(_SJID)s and device_id=%(_ID)s")) of
   {updated, 0} -> notfound;
   {updated,_N} -> ok;
   _ -> error
 end.

%% SQL for API
sql_delete_expired_devices(LServer) ->
  Now = integer_to_binary(seconds_since_epoch(0)),
  case ejabberd_sql:sql_query(
    LServer,
    [<<"delete from devices where expire > 0 and expire < '">>,Now,<<"'">>]) of
    {updated,_N} ->
      ok;
    _ ->
      error
  end.

sql_revoke_long_unused_devices(Days,LServer) ->
  Time = seconds_since_epoch_minus(Days*86400),
  case ejabberd_sql:sql_query(
    LServer,
    [<<"delete from devices where last_usage < '">>,Time,<<"'">>]) of
    {updated,_N} ->
      ok;
    _ ->
      error
  end.

%%%% END SQL Functions
revoke_all(Server,User) ->
  JID = jid:to_string(jid:make(User,Server)),
  Devices = sql_get_device_ids(Server,JID),
  case sql_revoke_all_devices(Server,JID) of
    ok ->
      lists:foreach(fun(ID) ->
        ReasonTXT = <<"Device was revoked">>,
        kick_by_device_id(Server,User,ID,ReasonTXT) end, Devices
      ),
      ok;
    _ ->
      error
  end.

revoke_all_except(Server, User, Resource) ->
  JID = jid:make(User,Server),
  JIDs = jid:to_string(JID),
  DevicesAll = sql_get_device_ids(Server,JIDs),
  SessionDeviceID = case ejabberd_sm:get_user_info(User, Server, Resource) of
                      offline ->
                        <<>>;
                      Info -> proplists:get_value(device_id, Info, <<>>)
                    end,
  Devices = DevicesAll -- [SessionDeviceID],
  case sql_revoke_devices(User, Server, Devices) of
    ok ->
      ReasonTXT = <<"Device was revoked">>,
      lists:foreach(fun(N) -> kick_by_device_id(Server,User,N,ReasonTXT) end, Devices);
    V ->
     V
  end.

kick_by_device_id(_Server,_User, undefined,_Reason) ->
  ok;
kick_by_device_id(Server,User, DeviceID,Reason) ->
  Resources = get_resources_by_device_id(User,Server, DeviceID),
  From =  jid:from_string(Server),
  Message = #message{type = headline, from = From,
    sub_els = [#devices_revoke{devices = [#devices_device{id = DeviceID}]}]},
  lists:foreach(fun(Resource) ->
    ejabberd_router:route(Message#message{id = randoms:get_string(), to = jid:make(User, Server, Resource)}),
    mod_admin_extra:kick_session(User,Server,Resource,Reason)
                end, Resources).

device_id_clause(IDs) ->
  Begin = <<"device_id in (">>,
  Fin = <<") ">>,
  L = [binary_to_list(<<$',U/binary,$'>>) || U <- IDs, U /= <<>>],
  IDValues = case string:join(L, ",") of
                [] -> <<"null">>;
                S -> list_to_binary(S)
              end,
  <<Begin/binary,IDValues/binary,Fin/binary>>.

make_secret() ->
  base64:encode(crypto:strong_rand_bytes(20)).

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
    #ejabberd_commands{name = revoke_device, tags = [xabber],
      desc = "Revoke device",
      longdesc = "Type username, host and device id to revoke selected device.",
      module = ?MODULE, function = revoke_device,
      args_desc = ["UserName","Host","DeviceID"],
      args_example = [<<"juliet">>,<<"capulet.lit">>,<<"a123qwertyid">>],
      args = [{username, binary}, {host, binary},{device, binary}],
      result = {res, rescode},
      result_example = 0,
      result_desc = "Returns integer code:\n"
      " - 0: operation succeeded\n"
      " - 1: error: sql query error"},
    #ejabberd_commands{name = delete_expired_devices, tags = [xabber],
      desc = "Delete expired devices",
      longdesc = "Type 'your.host' to delete expired devices from selected host.",
      module = ?MODULE, function = delete_expired_devices,
      args_desc = ["Host"],
      args_example = [<<"capulet.lit">>],
      args = [{host, binary}],
      result = {res, rescode},
      result_example = 0,
      result_desc = "Returns integer code:\n"
      " - 0: operation succeeded\n"
      " - 1: error: sql query error"},
    #ejabberd_commands{name = revoke_long_unused_devices, tags = [xabber],
      desc = "Delete devices which not used more than DAYS ",
      longdesc = "",
      module = ?MODULE, function = revoke_long_unused_devices,
      args_desc = ["Days to keep unsed device", "Host"],
      args_example = [30, <<"capulet.lit">>],
      args = [{days, integer}, {host, binary}],
      result = {res, rescode}}
  ].


get_time_now() ->
  {{Y,Mo,D}, {H,Mn,S}} = calendar:universal_time(),
  FmtStr = "~2.10.0B/~2.10.0B/~4.10.0B at ~2.10.0B:~2.10.0B:~2.10.0B UTC",
  IsoStr = io_lib:format(FmtStr, [D, Mo, Y, H, Mn, S]),
  list_to_binary(IsoStr).
