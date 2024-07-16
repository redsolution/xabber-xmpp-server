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
-compile([{parse_transform, ejabberd_sql_pt}]).
%% API
-export([check_token/3, check_token/4,
  set_count/4, select_secret/3, select_secrets/2]).

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
  delete_long_unused_devices/2
]).
%% Hooks
-export([
  update_presence/1,
  c2s_handle_recv/3,
  c2s_stream_features/2,
  disco_sm_features/5,
  sasl_success/2,
  remove_user/2,
  check_session/1,
  process_iq/1,
  pubsub_publish_item/6,
  user_send_packet/1,
  c2s_session_resumed/1
]).
%% API
-export([
  get_device_info/1,
  get_user_devices/2
]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-include("ejabberd_sm.hrl").
-include("ejabberd_commands.hrl").

-define(NODE_DEVICES, <<"urn:xmpp:omemo:2:devices">>).
-define(NODE_BUNDLES, <<"urn:xmpp:omemo:2:bundles">>).

start(Host, _Opts) ->
  ejabberd_commands:register_commands(get_commands_spec()),
  ejabberd_hooks:add(c2s_self_presence, Host, ?MODULE, update_presence, 80),
  ejabberd_hooks:add(c2s_handle_recv, Host, ?MODULE, c2s_handle_recv, 55),
  ejabberd_hooks:add(c2s_post_auth_features, Host, ?MODULE, c2s_stream_features, 50),
  ejabberd_hooks:add(disco_sm_features, Host, ?MODULE, disco_sm_features, 50),
  ejabberd_hooks:add(sasl_success, Host, ?MODULE, sasl_success, 50),
  ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 60),
  ejabberd_hooks:add(c2s_session_opened, Host, ?MODULE, check_session, 50),
  ejabberd_hooks:add(pubsub_publish_item, Host, ?MODULE, pubsub_publish_item, 80),
  ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 10),
  ejabberd_hooks:add(c2s_session_resumed, Host, ?MODULE, c2s_session_resumed, 10),
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
  ejabberd_hooks:delete(pubsub_publish_item, Host, ?MODULE, pubsub_publish_item, 80),
  ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 10),
  ejabberd_hooks:delete(c2s_session_resumed, Host, ?MODULE, c2s_session_resumed, 10),
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
        {ok, DevIDList} ->
          Devices = [#devices_device{id = DeviceID} || DeviceID <- DevIDList],
          State1 = State#{stream_state => disconnected},
          xmpp_stream_in:send(State1,xmpp:make_iq_result(IQ,#devices_revoke{devices = Devices})),
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
      #{ip := {PeerIP, _}, jid := JID, device_id := DeviceID, resource := StateResource} = State,
      IPs = make_ip_string(State, PeerIP),
      #jid{lserver = LServer, luser = LUser, lresource = _LRes} = JID,
      ejabberd_sm:set_user_info(LUser, LServer, StateResource, device_id, DeviceID),
      sql_refresh_session_info(JID,DeviceID,IPs);
    _ ->
      ok
  end,
  State.

pubsub_publish_item(_LServer, ?NODE_BUNDLES,
    #jid{luser = LUser, lserver = LServer} = From,
    #jid{luser = LUser, lserver = LServer}, _ItemId, _Payload) ->
  publish_omemo_devices(From);
pubsub_publish_item(_, _, _, _, _, _)->
  ok.

user_send_packet({#iq{type = set,
  from = #jid{luser = LUser, lserver = LServer} = From,
  to = #jid{luser = LUser, lserver = LServer, lresource = <<>>},
  sub_els = [SubEl]} = Iq, C2SState} = Acc) ->
  case process_packet_payload(From, SubEl) of
    ok ->
      Acc;
    _ ->
      Err = xmpp:err_policy_violation(),
      ejabberd_router:route_error(Iq, Err),
      {stop, {drop, C2SState}}
  end;
user_send_packet(Acc) ->
  Acc.

-spec update_presence({presence(), ejabberd_c2s:state()})
      -> {presence(), ejabberd_c2s:state()}.
update_presence({#presence{type = available} = Pres,
  #{auth_module := mod_devices, jid := JID, device_id := DeviceID} = State}) ->
  #jid{lserver = LServer, luser = LUser, resource = Resource} = JID,
  ejabberd_sm:set_user_info(LUser, LServer, Resource, device_id, DeviceID),
  {Pres, State};
update_presence(Acc) ->
  Acc.

c2s_session_resumed(#{user := U, server := S, resource := R,
  device_id := DeviceID} = State) ->
  ejabberd_sm:set_user_info(U, S, R, device_id, DeviceID),
  State;
c2s_session_resumed(State) ->
  State.

process_iq(#iq{type = set, from = #jid{lserver = S1}, to = #jid{lserver = S2}} = Iq) when S1 =/= S2 ->
  xmpp:make_error(Iq,xmpp:err_not_allowed());
process_iq(#iq{type = set, from = From, to = #jid{lserver = Server},
  sub_els = [#device_register{device = #devices_device{id = undefined,
    expire = TTLRaw, info = InfoRaw, client = ClientRaw, public_label = LabelRaw}}]} = Iq) ->
  UserBareJID = jid:remove_resource(From),
  SJID = jid:to_string(UserBareJID),
  {LUser, LServer, LResource} = jid:tolower(From),
  TTL = set_default_ttl(LServer, TTLRaw),
  Info = set_default(InfoRaw),
  Client = set_default(ClientRaw),
  Label = set_default(LabelRaw),
  ID = make_device_id(SJID),
  SsInfo = ejabberd_sm:get_user_info(LUser, LServer, LResource),
  PeerIP =  case proplists:get_value(ip, SsInfo) of
              {V, _} -> V;
              _ -> <<>>
            end,
  IPs = make_ip_string(maps:from_list(SsInfo), PeerIP),
  case sql_register_device(LServer, SJID, TTL, Info, Client, ID, IPs, Label) of
    {ok,Secret,ExpireTime} ->
      ejabberd_router:route(xmpp:make_iq_result(Iq,
        #devices_device{secret = Secret, id = ID, expire = integer_to_binary(ExpireTime)})),
      Message = new_device_msg(Client, Info, ID, UserBareJID, IPs),
      send_notification(Server, Message),
      ignore;
    _ ->
      xmpp:make_error(Iq,xmpp:err_bad_request())
  end;
process_iq(#iq{type = set, from = From,
  sub_els = [#device_register{device = Device}]} = Iq) ->
  {User, Server, Resource} = jid:tolower(From),
  IsAllowed = case ejabberd_sm:get_user_info(User, Server, Resource) of
                [_|Info] ->
                  case proplists:get_value(auth_module, Info) of
                    mod_devices -> false;
                    _ -> true
                  end;
                _ -> false
              end,
  if
    IsAllowed ->
      case update_device_secret(User, Server, Device) of
        not_found ->
          xmpp:make_error(Iq,xmpp:err_item_not_found());
        error->
          xmpp:make_error(Iq,xmpp:err_bad_request());
        NewDevice when Device#devices_device.public_label /= undefined ->
          publish_omemo_devices(From),
          xmpp:make_iq_result(Iq, NewDevice);
        NewDevice ->
          xmpp:make_iq_result(Iq, NewDevice)
      end;
    true ->
      xmpp:make_error(Iq,xmpp:err_not_allowed())
  end;
process_iq(#iq{type = get, from = From, to = To, sub_els = [#devices_query_items{}]} = Iq) ->
  LServer = To#jid.lserver,
  case get_user_devices(LServer, From) of
    {ok, []} ->
      xmpp:make_error(Iq,xmpp:err_item_not_found());
    {ok, Devices} ->
      xmpp:make_iq_result(Iq, #devices_query_items{devices = Devices});
    _ ->
      xmpp:make_error(Iq,xmpp:err_bad_request())
  end;
process_iq(#iq{type = set, sub_els = [#devices_query{device = #devices_device{id = undefined}}]} = Iq) ->
  xmpp:make_error(Iq,xmpp:err_bad_request());
process_iq(#iq{type = set, from = From, to = To, sub_els = [
  #devices_query{device = #devices_device{info = Info, client = Client,
    public_label = Label, id = ID}}]} = Iq) ->
  LServer = To#jid.lserver,
  Resource = From#jid.lresource,
  OnlineResources = get_resources_by_device_id(From#jid.luser, From#jid.lserver, ID),
  case lists:member(Resource, OnlineResources) of
    true ->
      case update_device(LServer, From, ID, [{info,Info}, {client,Client}, {public_label, Label}]) of
        ok when Label /= undefined ->
          publish_omemo_devices(From),
          xmpp:make_iq_result(Iq);
        ok ->
          xmpp:make_iq_result(Iq);
        not_found ->
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
  case revoke_devices(LUser, LServer, DeviceIDs) of
    ok ->
      ReasonTXT = <<"Device was revoked">>,
      lists:foreach(fun(N) -> kick_by_device_id(LServer,LUser,N,ReasonTXT) end, DeviceIDs),
      xmpp:make_iq_result(Iq);
    not_found ->
      xmpp:make_error(Iq,xmpp:err_item_not_found());
    _ ->
      xmpp:make_error(Iq,xmpp:err_bad_request())
  end;
process_iq(#iq{type = set, from = From, to = To, sub_els = [#devices_revoke_all{}]} = Iq) ->
  LServer = To#jid.lserver,
  LUser = From#jid.luser,
  Resource = From#jid.lresource,
  case revoke_all_except(LServer, LUser, Resource) of
    {ok, DevIDList} ->
      Devices = [#devices_device{id = DeviceID} || DeviceID <- DevIDList],
      xmpp:make_iq_result(Iq, #devices_revoke{devices = Devices});
    not_found ->
      xmpp:make_error(Iq,xmpp:err_item_not_found());
    _ ->
      xmpp:make_error(Iq,xmpp:err_bad_request())
  end;
process_iq(Iq) ->
  xmpp:make_error(Iq,xmpp:err_feature_not_implemented()).


remove_user(User, Server) ->
  JID = jid:to_string(jid:make(User,Server)),
  Devices = sql_get_device_ids(Server,JID),
  sql_delete_all_devices(Server,JID),
  run_hook_revoke_devices(User, Server, Devices),
  lists:foreach(fun(D) ->
    kick_by_device_id(Server, User, D, <<"User removed">>)
                end, Devices).

%%%%
%%  Commands
%%%%

delete_long_unused_devices(Days,Host) when is_integer(Days) ->
  case sql_select_unused(Days, Host) of
    [] -> 0;
    error -> 1;
    L ->
      sql_delete_unused(Days, Host),
      run_hook_revoke_devices(L),
      0
  end;
delete_long_unused_devices(_Days, _Host) ->
  1.

revoke_device(LServer, LUser, DeviceID) ->
  case sql_revoke_devices(LUser, LServer, [DeviceID]) of
    error -> 1;
    not_found ->
      0;
    _ ->
      run_hook_revoke_devices(LUser, LServer,[DeviceID]),
      ReasonTXT = <<"Token was revoked">>,
      kick_by_device_id(LServer,LUser,DeviceID,ReasonTXT),
      0
  end.

%%%%
%%  API
%%%%

check_token(User, Server, Token) ->
  UserExists = ejabberd_auth:user_exists(User, Server),
  check_token(UserExists, User, Server, Token).

check_token(false, _User, _Server, _Token) ->
  false;
check_token(true, User, Server, Token) ->
  SJID = jid:to_string(jid:make(User,Server,<<>>)),
  Secrets = select_secrets(Server, SJID),
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
  id = undefined, expire = TTLRaw, info = InfoRaw, client = ClientRaw, public_label = LabelRaw}}) ->
  BareJID = jid:make(User,Server),
  #{ip := IP} = State,
  {PAddr, _PPort} = IP,
  IPs = make_ip_string(State, PAddr),
  SJID = jid:to_string(BareJID),
  TTL = set_default_ttl(Server, TTLRaw),
  Info = set_default(InfoRaw),
  Client = set_default(ClientRaw),
  Label = set_default(LabelRaw),
  ID = make_device_id(SJID),
  case sql_register_device(Server, SJID, TTL, Info, Client, ID, IPs, Label) of
    {ok,Secret,ExpireTime} ->
      xmpp_stream_in:send(State,xmpp:make_iq_result(Iq,
        #devices_device{secret = Secret, id = ID, expire = integer_to_binary(ExpireTime)})),
      Message = new_device_msg(Client, Info, ID, BareJID, IPs),
      send_notification(Server, Message),
      ID;
    _ ->
      xmpp_stream_in:send(State,xmpp:make_error(Iq,xmpp:err_bad_request())),
      error
  end;
register_and_upgrade_to_hotp_session(Iq,User,Server,State,
    #device_register{device = #devices_device{id = DeviceID} = Device}) ->
  case update_device_secret(User, Server, Device) of
    not_found ->
      xmpp_stream_in:send(State,xmpp:make_error(Iq,xmpp:err_item_not_found())),
      error;
    error->
      xmpp_stream_in:send(State,xmpp:make_error(Iq,xmpp:err_bad_request())),
      error;
    NewDevice ->
      xmpp_stream_in:send(State,xmpp:make_iq_result(Iq,NewDevice)),
      DeviceID
  end.

set_count(User, Server, DeviceID, Count) ->
  sql_update_count(User, Server, DeviceID, Count).



%%%%
%%  Internal functions
%%%%

send_notification(Server, Message) ->
  case gen_mod:is_loaded(Server, mod_notify) of
    true ->
      mod_notify:send_notification(Server, Message#message.to,
        jid:make(Server), Message,
        xmpp:get_text(Message#message.body));
    _ ->
      ejabberd_router:route(Message)
  end.

select_secrets(LServer, JID) when is_tuple(JID)->
  SJID = jid:to_string(jid:remove_resource(JID)),
  select_secrets(LServer, SJID);
select_secrets(LServer, SJID) ->
  sql_select_secrets(LServer, SJID).

select_secret(LServer, JID, DevID) when is_tuple(JID)->
  SJID = jid:to_string(jid:remove_resource(JID)),
  select_secret(LServer, SJID, DevID);
select_secret(LServer, SJID, DevID) ->
  sql_select_secret(LServer, SJID, DevID).

make_device_id(SJID) ->
  DevID = integer_to_binary(crypto:rand_uniform(1,16777216)),
  DevIDPadded = <<(binary:copy(<<"0">>, 8 - byte_size(DevID)))/binary, DevID/binary>>,
  UserID = str:sha(SJID),
  <<DevIDPadded/binary,UserID:24/binary>>.

ip_to_binary(IP) ->
  IPStr = inet_parse:ntoa(IP),
  case string:prefix(IPStr, "::ffff:") of
    nomatch -> list_to_binary(IPStr);
    V -> list_to_binary(V)
  end.

make_ip_string(Map, PeerIP) when is_tuple(PeerIP) ->
  make_ip_string(Map, ip_to_binary(PeerIP));
make_ip_string(Map, PeerIP) ->
  case maps:get(forwarded_for, Map, false) of
    {SrcIP, _} ->
      AddrB = ip_to_binary(SrcIP),
      <<AddrB/binary," via ",PeerIP/binary>>;
    _ -> PeerIP
  end.

bold() ->
  #xmlel{
    name = <<"bold">>,
    attrs = [{<<"xmlns">>, ?NS_XABBER_MARKUP}]
  }.

mention(User) ->
  XMPP = <<"xmpp:",User/binary>>,
  #xabber_groupchat_mention{cdata = XMPP}.

new_device_msg(<<>>, Info, DeviceID, BareJID, IP) ->
  new_device_msg(<<"Unknown client">>, Info, DeviceID, BareJID, IP);
new_device_msg(Client, <<>>, DeviceID ,BareJID, IP) ->
  new_device_msg(Client, <<"Unknown device">>, DeviceID, BareJID, IP);
new_device_msg(Client, Info, DeviceID, BareJID, IP) ->
  User = jid:to_string(BareJID),
  LServer = BareJID#jid.lserver,
  X = #devices_device{id = DeviceID},
  Time = get_time_now(),
  Device = <<Client/binary, "\n", Info/binary,"\n", IP/binary>>,
  Parts = [{bold, <<"New login">>}, <<" to server ">>, {bold, LServer},
    <<":\nWe detected a new login into your account ">>, {mention, User},
    <<" from a new device on ">>, Time, <<"\n\n">>, {bold, Device},
    <<"\n\nIf it wasn't you, go to ">>, {bold, <<"Settings -> Devices">>},
    <<" and terminate suspicious sessions.">>],
  {TextStr, Refs} = make_text_with_refs(Parts),
  Text = [#text{lang = <<>>,data = TextStr}],
  ID = randoms:get_string(),
  OriginID = #origin_id{id = ID},
  #message{type = chat, from = jid:make(LServer), to = BareJID, id =ID, body = Text,
    sub_els = [X, OriginID] ++ Refs}.

make_text_with_refs(Parts) ->
  make_text_with_refs(Parts, {<<>>, []}).

make_text_with_refs([], Acc) -> Acc;
make_text_with_refs([H | T], {BString, Refs}) ->
  case H of
    {RType, Text} ->
      Begin = misc:escaped_text_len(BString),
      End =  Begin + misc:escaped_text_len(Text),
      Els = case RType of
              bold -> [bold()];
              mention -> [mention(Text)];
              _ -> []
            end,
      NewRefs = Refs ++ [#xmppreference{type = <<"decoration">>,
        'begin' = Begin, 'end' = End, sub_els = Els}],
      make_text_with_refs(T, {<<BString/binary, Text/binary>>, NewRefs});
    Text ->
      make_text_with_refs(T, {<<BString/binary, Text/binary>>, Refs})
  end.



set_default_ttl(LServer, undefined) ->
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

update_device(_LServer, _JID, <<>>, _Props) ->
  not_found;
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
      not_found;
    {updated,_} ->
      ok;
    _ ->
      error
  end.

update_device_secret(User, Server, Device) ->
  #devices_device{id = DeviceID, secret = Secret,
    expire = TTLRaw, info = Info, client = Client, public_label = Label} = Device,
  SJID = jid:to_string(jid:make(User,Server)),
  case select_secret(Server, SJID, DeviceID) of
    {Secret, _, _} ->
      NewSecret = make_secret(),
      Expire = integer_to_binary(seconds_since_epoch(set_default_ttl(Server, TTLRaw))),
      Props = [{count, <<$0>>},{secret,NewSecret}, {info,Info},
        {client,Client}, {public_label, Label}, {expire, Expire}],
      case update_device(Server, SJID, DeviceID, Props ) of
        ok ->  Device#devices_device{secret = NewSecret, expire = Expire};
        Error -> Error
      end;
    _ -> not_found
  end.


prepare_value(V) when is_binary(V) ->
  "'" ++ binary_to_list(ejabberd_sql:escape(V)) ++ "'";
prepare_value(V) when is_integer(V) ->
  integer_to_list(V);
prepare_value(_V) ->
  "''".

process_packet_payload(User, El) ->
  try xmpp:decode(El) of
    #pubsub{publish = #ps_publish{node = ?NODE_DEVICES}} ->
      not_allowed;
    #pubsub{retract = #ps_retract{node = ?NODE_DEVICES}} ->
      not_allowed;
    #pubsub{publish = #ps_publish{node = ?NODE_BUNDLES,
      items = [#ps_item{id = ItemId}]}} ->
      chang_omemo_device(User, ItemId, update);
    #pubsub{retract = #ps_retract{node = ?NODE_BUNDLES,
      items = [#ps_item{id = ItemId}] }} ->
      chang_omemo_device(User, ItemId, delete),
      publish_omemo_devices(User);
    _ ->
      ok
  catch _:{xmpp_codec, _Reason} ->
    ok
  end.

chang_omemo_device(UserJID, OMEMOId, Action) ->
  {DevID, CurOMEMOId} =
    case  get_device_info(UserJID) of
      #devices_device{id = ID, omemo_id = OID} ->
        {ID, OID};
      _ -> {<<>>, <<>>}
    end,
  LServer = UserJID#jid.lserver,
  case CurOMEMOId of
    OMEMOId when Action == delete ->
      update_device(LServer, UserJID, DevID, [{omemo_id, <<>>}]);
    OMEMOId ->
      ok;
    undefined when Action /= delete ->
      update_device(LServer, UserJID, DevID, [{omemo_id, OMEMOId}]);
    _ ->
      not_allowd
  end.

-spec get_device_info(jid()) -> tuple() | atom().
get_device_info(User) ->
  {LUser, LServer, Res} = jid:tolower(User),
  DeviceId =
    case ejabberd_sm:get_user_info(LUser, LServer, Res) of
      offline -> <<>>;
      Info -> proplists:get_value(device_id, Info, <<>>)
    end,
  get_device_info(User, DeviceId).

-spec get_device_info(jid() | binary(), binary()) -> tuple() | atom().
get_device_info(_User, <<>>) ->
  not_found;
get_device_info(User, DeviceId) ->
  {LServer, SJID} =
    if
      is_binary(User) ->
        JID = jid:from_string(User),
        {JID#jid.lserver, User};
      true ->
        {User#jid.lserver,
          jid:to_string(jid:remove_resource(User))}
    end,
  sql_select_user_device(LServer, SJID, DeviceId).

-spec get_user_devices(binary(), binary() | jid()) -> {ok, list()} | error | not_found.
get_user_devices(LServer, JID) when is_tuple(JID)->
  SJID= jid:to_string(jid:remove_resource(JID)),
  get_user_devices(LServer, SJID);
get_user_devices(LServer, SJID)->
  sql_select_user_devices(LServer, SJID).

publish_omemo_devices(UserJID) ->
  LServer = UserJID#jid.lserver,
  SJID = jid:to_string(jid:remove_resource(UserJID)),
  Devices = lists:map(
    fun({ID, Label}) ->
      LabelAttr = case Label of
                    <<>> -> [];
                    _ -> [{<<"label">>, Label}]
                  end,
      #xmlel{name = <<"device">>,
        attrs = [{<<"id">>, ID}] ++ LabelAttr}
    end, select_omemo_devices(LServer, SJID)),
  IQ = #iq{from = UserJID,
    to = jid:remove_resource(UserJID),
    id = randoms:get_string(),
    type = set,
    meta = #{}},
  Item = #ps_item{
    id = <<"current">>,
    sub_els = [
      #xmlel{name = <<"devices">>,
      attrs = [{<<"xmlns">>, <<"urn:xmpp:omemo:2">>}],
      children = Devices}]},
  Payload = #pubsub{publish = #ps_publish{node = ?NODE_DEVICES, items = [Item]}},
  mod_pubsub:iq_sm(IQ#iq{sub_els = [Payload]}),
  ok.

select_omemo_devices(LServer, SJID) ->
  sql_select_omemo_devices(LServer, SJID).

%%%% SQL Functions

sql_update_count(LUser, LServer, _DeviceID, _Count) ->
  _SJID = jid:to_string(jid:make(LUser,LServer)),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update devices set count=%(_Count)d where "
    " jid=%(_SJID)s and device_id = %(_DeviceID)s")).

sql_select_secret(LServer, _SJID, _DevID) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(secret)s,@(count)d,@(expire)d"
    " from devices where jid=%(_SJID)s "
    " and device_id=%(_DevID)s")) of
    {selected, [Val]} -> Val;
    {selected, []} -> {error, not_found};
    _ -> {error, db_error}
  end.

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

sql_select_omemo_devices(LServer, _SJID) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(omemo_id)s,@(public_label)s from devices "
    " where jid=%(_SJID)s and expire > 0 and omemo_id != '' ")) of
    {selected, List} -> List;
    _ -> []
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

sql_register_device(LServer, _SJID, TTLSeconds, _Info, _Client, _ID, _IP, _Label) ->
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
      "public_label=%(_Label)s"]) of
    ok ->
      {ok,_Secret,_Expire};
    _ ->
      {error, db_failure}
  end.

sql_select_user_device(LServer, _SJID, _DeviceID) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(device_id)s, @(expire)s, @(info)s, @(client)s,"
    " @(ip)s, @(last_usage)s, @(public_label)s, @(omemo_id)s"
    " from devices where jid=%(_SJID)s and device_id=%(_DeviceID)s")) of
    {selected, []} ->
      not_found;
    {selected, Result} ->
      hd(to_devices(Result));
    _ ->
      error
  end.

sql_select_user_devices(LServer, _SJID) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(device_id)s, @(expire)s, @(info)s, @(client)s,"
    " @(ip)s, @(last_usage)s, @(public_label)s, @(omemo_id)s"
    " from devices where jid=%(_SJID)s and expire!=0 order by last_usage desc")) of
    {selected, Result} ->
      {ok, to_devices(Result)};
    _ ->
      error
  end.

sql_revoke_devices(LUser, LServer, IDs) ->
  BareJID = <<LUser/binary,"@",LServer/binary>>,
  IDClause = device_id_clause(IDs),
 case ejabberd_sql:sql_query(
   LServer,
   [<<"update devices set expire=0 where jid= '">>, BareJID,
     <<"' and ">>, IDClause]) of
   {updated, 0} ->
     not_found;
   {updated,_N} ->
     ok;
   _ ->
     error
 end.

sql_get_device_ids(Server,_JID) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(device_id)s"
    " from devices where jid=%(_JID)s and expire > 0")) of
    {selected, Devices} ->
      [ID || {ID} <- Devices];
    _ ->
      error
  end.

sql_revoke_all_devices(LServer,BareJID) ->
  case ejabberd_sql:sql_query(
    LServer,
    [<<"update devices set expire=0 where jid= '">>, BareJID,<<"'">>]) of
    {updated,_N} -> ok;
    _ -> error
  end.

sql_delete_all_devices(LServer,_SJID) ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from devices where jid=%(_SJID)s")).

sql_delete_device(Server,_SJID,_ID) ->
 case ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from devices where jid=%(_SJID)s and device_id=%(_ID)s")) of
   {updated, 0} -> not_found;
   {updated,_N} -> ok;
   _ -> error
 end.

to_devices(QueryResult) ->
  lists:map(fun(Values) ->
    CheckedValues = check_values(Values) ,
    [ID, Expire, Info, Client, IP, Last, Label, OMEMOId] = CheckedValues,
    #devices_device{id = ID, expire = Expire, info = Info, client = Client,
      ip = IP, last_auth = Last, public_label = Label, omemo_id = OMEMOId}
            end, QueryResult).

check_values(Tuple) ->
  lists:map(
    fun(null) -> undefined;
      (<<>>) -> undefined;
      (V) -> V
    end, tuple_to_list(Tuple)).

%% SQL for API

sql_select_unused(Days, LServer) ->
  _Time = seconds_since_epoch_minus(Days*86400),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(jid)s,@(device_id)s"
    " from devices where last_usage < %(_Time)d")) of
    {selected, UserDev} ->
      UserDev;
    _ ->
      error
  end.

sql_delete_unused(Days,LServer) ->
  Time = integer_to_binary(seconds_since_epoch_minus(Days*86400)),
  case ejabberd_sql:sql_query(
    LServer,
    [<<"delete from devices where last_usage < '">>,Time,<<"'">>]) of
    {updated,_N} ->
      ok;
    _ ->
      error
  end.

%%%% END SQL Functions


run_hook_revoke_devices(KVList) ->
  lists:foreach(fun({SJID, IDs}) ->
    #jid{luser=LUser, lserver=LServer} = jid:from_string(SJID),
    run_hook_revoke_devices(LUser, LServer, IDs)
                end, group_by(KVList)),
  ok.

run_hook_revoke_devices(LUser, LServer, IDs) ->
  ejabberd_hooks:run(revoke_devices, LServer, [LUser, LServer, IDs]),
  publish_omemo_devices(jid:make(LUser, LServer)),
  ok.


-spec revoke_devices(binary(), binary(), list()) -> ok | not_found | error.
revoke_devices(_LUser, _LServer, []) ->
  not_found;
revoke_devices(LUser, LServer, IDs) ->
  case sql_revoke_devices(LUser, LServer, IDs) of
    ok ->
      run_hook_revoke_devices(LUser, LServer, IDs),
      ok;
    Err ->
      Err
  end.

revoke_all(Server,User) ->
  JID = jid:to_string(jid:make(User,Server)),
  Devices = sql_get_device_ids(Server,JID),
  Result = case sql_revoke_all_devices(Server,JID) of
             ok -> {ok, Devices};
             R -> R
           end,
  run_hook_revoke_devices(User, Server, Devices),
  lists:foreach(fun(ID) ->
    ReasonTXT = <<"Device was revoked">>,
    kick_by_device_id(Server,User,ID,ReasonTXT) end, Devices
  ),
  Result.

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
  case revoke_devices(User, Server, Devices) of
    ok ->
      ReasonTXT = <<"Device was revoked">>,
      lists:foreach(fun(N) -> kick_by_device_id(Server,User,N,ReasonTXT) end, Devices),
      {ok, Devices};
    V ->
     V
  end.

kick_by_device_id(_Server,_User, undefined,_Reason) ->
  ok;
kick_by_device_id(Server, User, DeviceID, Reason) ->
  Resources = get_resources_by_device_id(User,Server, DeviceID),
  From =  jid:from_string(Server),
  Message = #message{type = headline, from = From,
    sub_els = [#devices_revoke{devices = [#devices_device{id = DeviceID}]}]},
  lists:foreach(fun(Resource) ->
    JID = jid:make(User, Server, Resource),
    ejabberd_router:route(Message#message{id = randoms:get_string(), to = JID}),
    ejabberd_sm:route(JID, {kick, revoke_device, xmpp:serr_not_authorized(Reason, <<"en">>)})
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

get_time_now() ->
  {{Y,Mo,D}, {H,Mn,S}} = calendar:universal_time(),
  FmtStr = "~2.10.0B/~2.10.0B/~4.10.0B at ~2.10.0B:~2.10.0B:~2.10.0B UTC",
  IsoStr = io_lib:format(FmtStr, [D, Mo, Y, H, Mn, S]),
  list_to_binary(IsoStr).

group_by([])->    [];
group_by(KVList) ->
  Fun = fun({K,V}, D) -> dict:append(K, V, D) end,
  dict:to_list(lists:foldr(Fun , dict:new(), KVList)).

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
    #ejabberd_commands{name = delete_long_unused_devices, tags = [xabber],
      desc = "Delete devices which not used more than DAYS ",
      longdesc = "",
      module = ?MODULE, function = delete_long_unused_devices,
      args_desc = ["Days to keep unsed device", "Host"],
      args_example = [30, <<"capulet.lit">>],
      args = [{days, integer}, {host, binary}],
      result = {res, rescode}}
  ].
