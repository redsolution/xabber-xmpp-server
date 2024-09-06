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

%% gen_mod
-export([stop/1, start/2, depends/2, mod_options/1,
  mod_opt_type/1]).
%% Commands
-export([revoke_device/3, delete_long_unused_devices/2]).
%% Hooks
-export([update_presence/1, c2s_handle_recv/3,c2s_stream_features/2,
  disco_sm_features/5, sasl_success/2, remove_user/2, check_session/1,
  process_iq/1, pubsub_publish_item/6, user_send_packet/1,
  c2s_session_resumed/1]).
%% API
-export([
  set_count/4,
  select_secret/3,
  validate_device/4,
  get_user_devices/2
]).

%% Deprecated
-export([check_token/3, check_token/4, select_secrets/2]).

-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-include("ejabberd_commands.hrl").

-define(NODE_DEVICES, <<"urn:xmpp:omemo:2:devices">>).
-define(NODE_BUNDLES, <<"urn:xmpp:omemo:2:bundles">>).

start(Host, _Opts) ->
  ejabberd_commands:register_commands(get_commands_spec()),
  register_hooks(Host),
  register_iq_handlers(Host),
  ok.

stop(Host) ->
  case gen_mod:is_loaded_elsewhere(Host, ?MODULE) of
    false ->
      ejabberd_commands:unregister_commands(get_commands_spec());
    true ->
      ok
  end,
  unregister_hooks(Host),
  unregister_iq_handlers(Host),
  ok.

depends(_Host, _Opts) ->
  [].

mod_opt_type(device_expiration_time) ->
  fun(I) when is_integer(I), I > 0 -> I end;
mod_opt_type(device_ocra_only) ->
  fun (B) when is_boolean(B) -> B end.

mod_options(_Host) -> [
  {device_expiration_time, 31536000},
  {device_ocra_only, false}
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

c2s_handle_recv(#{stream_state := wait_for_bind} = State, _, #iq{type = set} = IQ) ->
  Register = xmpp:try_subtag(IQ, #device_register{}),
  IsBind = xmpp:has_subtag(IQ, #bind{}),
  RevokeAll = xmpp:try_subtag(IQ, #devices_revoke_all{}),
  #{auth_module := Auth, lang := Lang, lserver := Server, user := User} = State,
  DeviceOnly = gen_mod:get_module_opt(Server, ?MODULE, device_ocra_only),
  if
    Register =/= false andalso Auth =/= mod_devices andalso Auth =/= ejabberd_oauth ->
      Device = Register#device_register.device,
      case register_and_upgrade_to_device_session(IQ,User,Server,State, Device) of
        error when DeviceOnly == true -> State#{stream_state => disconnected};
        error -> State;
        DeviceID -> State#{auth_module => mod_devices, device_id => DeviceID}
      end;
    IsBind andalso DeviceOnly andalso Auth =/= mod_devices ->
      ?INFO_MSG("You have enabled option device_ocra_only."
      " Disable it in settings, if you want to allow other authorization",[]),
      Txt = <<"Access denied by service policy. Use DEVICE-OCRA for auth">>,
      Err = xmpp:make_error(IQ,xmpp:err_not_allowed(Txt,Lang)),
      xmpp_stream_in:send_error(State, IQ, Err),
      State#{stream_state => disconnected};
    RevokeAll =/= false ->
      MyDevID = maps:get(device_id, State, <<>>),
      case revoke_all(User, Server, MyDevID) of
        {ok, DevIDList} ->
          Devices = [#devices_device{id = DeviceID} || DeviceID <- DevIDList],
          State1 = State#{stream_state => disconnected},
          xmpp_stream_in:send(State1,
            xmpp:make_iq_result(IQ,#devices_revoke{devices = Devices})),
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
      #{jid := JID, device_id := DeviceID, resource := StateResource} = State,
      IPs = make_ip_string(State),
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

process_iq(#iq{type = set, from = #jid{lserver = S1},
  to = #jid{lserver = S2}} = Iq) when S1 =/= S2 ->
  xmpp:make_error(Iq,xmpp:err_not_allowed());
process_iq(#iq{type = set, from = _From, sub_els = [#device_register{
  device = #devices_device{id = undefined}}]} = Iq) ->
  xmpp:make_error(Iq,xmpp:err_not_allowed());
process_iq(#iq{type = set, from = From, sub_els = [#device_register{
  device = Device}]} = Iq) ->
  {User, Server, _} = jid:tolower(From),
  case check_auth_module(From) of
    true ->
      case update_device_secret(User, Server, Device) of
        not_found ->
          xmpp:make_error(Iq,xmpp:err_item_not_found());
        not_allowed ->
          xmpp:make_error(Iq,xmpp:err_not_allowed());
        error->
          xmpp:make_error(Iq,xmpp:err_internal_server_error());
        NewDevice when Device#devices_device.public_label /= undefined ->
          publish_omemo_devices(From),
          xmpp:make_iq_result(Iq, NewDevice);
        NewDevice ->
          xmpp:make_iq_result(Iq, NewDevice)
      end;
    _ ->
      xmpp:make_error(Iq,xmpp:err_not_allowed())
  end;
process_iq(#iq{type = get, from = From, to = To,
  sub_els = [#devices_query_items{}]} = Iq) ->
  LServer = To#jid.lserver,
  case get_user_devices(LServer, From) of
    {ok, []} ->
      xmpp:make_error(Iq,xmpp:err_item_not_found());
    {ok, Devices} ->
      xmpp:make_iq_result(Iq, #devices_query_items{devices = Devices});
    _ ->
      xmpp:make_error(Iq,xmpp:err_bad_request())
  end;
process_iq(#iq{type = set, sub_els = [#devices_query{
  device = #devices_device{id = undefined}}]} = Iq) ->
  xmpp:make_error(Iq,xmpp:err_bad_request());
process_iq(#iq{type = set, from = From, sub_els = [#devices_query{
  device = #devices_device{info = Info, client = Client,
    public_label = Label, device_type = DType, id = ID}}]} = Iq) ->
  {LUser, LServer, R} = jid:tolower(From),
  OnlineRs = get_devices_resources(LUser, LServer, [ID]),
  case lists:member({ID, R}, OnlineRs) of
    true ->
      Props = [{info,Info}, {client,Client}, {public_label, Label},
        {device_type, DType}],
      case sql_update_device(LServer, From, ID, Props) of
        ok ->
          Label /= undefined andalso publish_omemo_devices(From),
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
  {LUser, LServer, _} = jid:tolower(From),
  DeviceIDs = lists:map(fun(#devices_device{id = ID}) -> ID end, Devices),
  case revoke_devices(LUser, LServer, DeviceIDs, <<"Device was revoked">>) of
    ok ->
      xmpp:make_iq_result(Iq);
    not_found ->
      xmpp:make_error(Iq,xmpp:err_item_not_found());
    _ ->
      xmpp:make_error(Iq,xmpp:err_bad_request())
  end;
process_iq(#iq{type = set, from = From, sub_els = [#devices_revoke_all{}]} = Iq) ->
  case revoke_all(From) of
    {ok, DevIDList} ->
      Devices = [#devices_device{id = DeviceID} || DeviceID <- DevIDList],
      xmpp:make_iq_result(Iq, #devices_revoke{devices = Devices});
    not_found ->
      xmpp:make_error(Iq,xmpp:err_item_not_found());
    _Err->
      xmpp:make_error(Iq,xmpp:err_bad_request())
  end;
process_iq(Iq) ->
  xmpp:make_error(Iq,xmpp:err_feature_not_implemented()).


remove_user(User, Server) ->
  revoke_all(User, Server, <<>>,  <<"User removed">>).

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
  case revoke_devices(LUser, LServer, [DeviceID],
    <<"Device was revoked by admin">>) of
    error -> 1;
    _ -> 0
  end.

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

%%%%
%%  API
%%%%

%%  To support legacy clients.
%%  todo: Remove it when it is no longer needed.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
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
  Now = erlang:system_time(second),
  case ResultList of
    [{ID, NewCount, Expire}] when Expire > Now ->
      {ok, {ID, NewCount}};
    _ -> false
  end.

select_secrets(LServer, JID) when is_tuple(JID)->
  SJID = jid:to_string(jid:remove_resource(JID)),
  select_secrets(LServer, SJID);
select_secrets(LServer, SJID) ->
  sql_select_secrets(LServer, SJID).
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

set_count(User, Server, DeviceID, Count) ->
  sql_update_count(User, Server, DeviceID, Count).

-spec validate_device(binary(), binary(),binary(), integer()) -> {ok, binary()} | expired | failed.
validate_device(ESecret, Validator, ValidationKey, Expire) ->
  Now = erlang:system_time(second),
  validate_device(ESecret, Validator, ValidationKey, Expire, Now).

validate_device(_, _, _, Expire, Now) when Now > Expire ->
  expired;
validate_device(ESecret, Validator, ValidationKey, _, _) ->
  Secret = crypto:exor(ESecret, ValidationKey),
  case crypto:hmac(sha256, ESecret, Secret) of
    Validator ->
      {ok, Secret};
    _ ->
      failed
  end.

-spec get_user_devices(binary(), binary() | jid()) -> {ok, list()} | error | not_found.
get_user_devices(LServer, JID) when is_tuple(JID)->
  SJID= jid:to_string(jid:remove_resource(JID)),
  get_user_devices(LServer, SJID);
get_user_devices(LServer, SJID)->
  sql_select_user_devices(LServer, SJID).

select_secret(LServer, JID, DevID) when is_tuple(JID)->
  SJID = jid:to_string(jid:remove_resource(JID)),
  select_secret(LServer, SJID, DevID);
select_secret(LServer, SJID, DevID) ->
  sql_select_secret(LServer, SJID, DevID).


%%%%
%%  Internal functions
%%%%

check_auth_module(JID) ->
  {User, Server, Resource} = jid:tolower(JID),
  case ejabberd_sm:get_user_info(User, Server, Resource) of
    offline -> false;
    Info ->
      case proplists:get_value(auth_module, Info) of
        mod_devices -> false;
        ejabberd_oauth -> false;
        _ -> true
      end
  end.

register_and_upgrade_to_device_session(Iq, User, Server, State, Device)
  when Device#devices_device.id == undefined ->
  BareJID = jid:make(User, Server),
  IPs = make_ip_string(State),
  SJID = jid:to_string(BareJID),
  [Expire, Info, Client, Label, DType] = parse_raw_data(Server, Device),
  ID = make_device_id(SJID),
  case register_device(Server, SJID, Expire, Info, Client, ID, IPs, Label, DType) of
    {ok, Secret, ValidationKey} ->
      xmpp_stream_in:send(State,xmpp:make_iq_result(Iq,
        #devices_device{secret = Secret, id = ID,
          validation_key = ValidationKey, expire = Expire})),
      Message = new_device_msg(Client, Info, ID, BareJID, IPs),
      send_notification(Server, Message),
      ID;
    _ ->
      xmpp_stream_in:send(State,xmpp:make_error(Iq,xmpp:err_bad_request())),
      error
  end;
register_and_upgrade_to_device_session(Iq, User, Server, State, Device) ->
  {Result, Response} =
    case update_device_secret(User, Server, Device) of
      #devices_device{} = NewDevice ->
        {Device#devices_device.id, xmpp:make_iq_result(Iq, NewDevice)};
      not_found ->
        {error, xmpp:make_error(Iq,xmpp:err_item_not_found())};
      _ ->
        {error, xmpp:make_error(Iq,xmpp:err_internal_server_error())}
    end,
  xmpp_stream_in:send(State, Response),
  Result.

send_notification(Server, Message) ->
  case gen_mod:is_loaded(Server, mod_notify) of
    true ->
      mod_notify:send_notification(Server, Message#message.to,
        jid:make(Server), Message,
        xmpp:get_text(Message#message.body));
    _ ->
      ejabberd_router:route(Message)
  end.

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

make_ip_string(Info) when is_list(Info)  ->
  make_ip_string(maps:from_list(Info));
make_ip_string(Map) ->
  IP = case maps:get(ip, Map, false) of
         {V, _} -> ip_to_binary(V);
         _ -> <<>>
       end,
  case maps:get(forwarded_for, Map, false) of
    {SrcIP, _} ->
      AddrB = ip_to_binary(SrcIP),
      <<AddrB/binary," via ", IP/binary>>;
    _ -> IP
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


set_default(undefined) ->
  <<>>;
set_default(Value)->
  Value.

-spec get_devices_resources(binary(), binary(), list() | all) -> [tuple()].
get_devices_resources(User, Server, DevIDs) ->
  lists:filtermap(
    fun({Resource, Info}) ->
      case lists:keyfind(device_id, 1, Info) of
        {device_id, ID} when DevIDs == all ->
          {true, {ID, Resource}};
        {device_id, ID} ->
          case lists:member(ID, DevIDs) of
            true -> {true, {ID, Resource}};
            _ -> false
          end;
        _ -> false
      end
    end, ejabberd_sm:get_user_info(User, Server)).

update_device_secret(User, Server, Device) ->
  DeviceID = Device#devices_device.id,
  SJID = jid:to_string(jid:make(User,Server)),
  [Expire, Info, Client, Label, DType] = parse_raw_data(Server, Device),
  {NewSecret, NewValidationKey, NewESecret, NewValidator} = make_secret(),
  Props = [{count, <<$0>>},{esecret, base64:encode(NewESecret)}, {info,Info},
    {client,Client}, {validator, base64:encode(NewValidator)},
    {public_label, Label}, {expire, Expire}, {device_type, DType}],
  case sql_update_device(Server, SJID, DeviceID, Props) of
    ok ->
      Device#devices_device{
        secret = NewSecret,
        validation_key = NewValidationKey,
        expire = Expire};
    Err -> Err
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
      sql_update_device(LServer, UserJID, DevID, [{omemo_id, <<>>}]);
    OMEMOId ->
      ok;
    undefined when Action /= delete ->
      sql_update_device(LServer, UserJID, DevID, [{omemo_id, OMEMOId}]);
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

register_hooks(Host) ->
  ejabberd_hooks:add(c2s_self_presence, Host, ?MODULE, update_presence, 80),
  ejabberd_hooks:add(c2s_handle_recv, Host, ?MODULE, c2s_handle_recv, 55),
  ejabberd_hooks:add(c2s_post_auth_features, Host, ?MODULE, c2s_stream_features, 50),
  ejabberd_hooks:add(disco_sm_features, Host, ?MODULE, disco_sm_features, 50),
  ejabberd_hooks:add(sasl_success, Host, ?MODULE, sasl_success, 50),
  ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 60),
  ejabberd_hooks:add(c2s_session_opened, Host, ?MODULE, check_session, 50),
  ejabberd_hooks:add(pubsub_publish_item, Host, ?MODULE, pubsub_publish_item, 80),
  ejabberd_hooks:add(user_send_packet, Host, ?MODULE, user_send_packet, 10),
  ejabberd_hooks:add(c2s_session_resumed, Host, ?MODULE, c2s_session_resumed, 10).

unregister_hooks(Host) ->
  ejabberd_hooks:delete(sasl_success, Host, ?MODULE, sasl_success, 50),
  ejabberd_hooks:delete(c2s_handle_recv, Host, ?MODULE, c2s_handle_recv, 55),
  ejabberd_hooks:delete(c2s_post_auth_features, Host, ?MODULE, c2s_stream_features, 50),
  ejabberd_hooks:delete(c2s_self_presence, Host, ?MODULE, update_presence, 80),
  ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE, disco_sm_features, 50),
  ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 60),
  ejabberd_hooks:delete(c2s_session_opened, Host, ?MODULE, check_session, 50),
  ejabberd_hooks:delete(pubsub_publish_item, Host, ?MODULE, pubsub_publish_item, 80),
  ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, user_send_packet, 10),
  ejabberd_hooks:delete(c2s_session_resumed, Host, ?MODULE, c2s_session_resumed, 10).

register_iq_handlers(Host) ->
  gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_DEVICES, ?MODULE, process_iq),
  gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_DEVICES, ?MODULE, process_iq),
  gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_DEVICES_QUERY, ?MODULE, process_iq),
  gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_DEVICES_QUERY, ?MODULE, process_iq).

unregister_iq_handlers(Host) ->
  gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_DEVICES),
  gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_DEVICES),
  gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_DEVICES_QUERY),
  gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_DEVICES_QUERY).

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


-spec revoke_devices(binary(), binary(), list(), binary()) -> ok | not_found | error.
revoke_devices(_LUser, _LServer, [], _Reason) ->
  not_found;
revoke_devices(LUser, LServer, IDs, Reason) ->
  revoke_devices(false, LUser, LServer, IDs, Reason).

revoke_devices(IsAll, LUser, LServer, IDs, Reason) ->
  IDs1 = case IsAll of
           true -> all;
           _ -> IDs
         end,
  case sql_revoke_devices(LUser, LServer, IDs1) of
    ok ->
      run_hook_revoke_devices(LUser, LServer, IDs),
      kick_devices(LServer, LUser, IDs1, Reason);
    Err ->
      Err
  end.

revoke_all(JID) ->
  {User, Server, Resource} = jid:tolower(JID),
  case ejabberd_sm:get_user_info(User, Server, Resource) of
    offline -> error;
    Info ->
      revoke_all(User, Server,
        proplists:get_value(device_id, Info, <<>>))
  end.

revoke_all(User, Server, MyDevID) ->
  revoke_all(User, Server, MyDevID, <<"Device was revoked">>).

revoke_all(User, Server, MyDevID, Reason) ->
  JIDs = jid:to_string(jid:make(User,Server)),
  DevicesAll = case get_user_devices(Server, JIDs) of
                 {ok, List} ->
                   [X#devices_device.id || X <- List];
                 _ -> []
               end,
  Devices = DevicesAll -- [MyDevID],
  IsAll = MyDevID == <<>>,
  case revoke_devices(IsAll, User, Server, Devices, Reason) of
    ok -> {ok, Devices};
    Err -> Err
  end.

-spec kick_devices(binary(), binary(), list() | all, binary()) -> ok.
kick_devices(Server, User, Devices, Reason) ->
  DevResList = get_devices_resources(User, Server, Devices),
  From =  jid:from_string(Server),
  lists:foreach(fun({ID, Resource}) ->
    JID = jid:make(User, Server, Resource),
    Message = #message{type = headline, from = From, to= JID,
      id = randoms:get_string(),
      sub_els = [#devices_revoke{devices = [#devices_device{id = ID}]}]},
    ejabberd_router:route(Message),
    ejabberd_sm:route(JID, {kick, revoke_device,
      xmpp:serr_not_authorized(Reason, <<"en">>)})
                end, DevResList).

register_device(LServer, SJID, Expire, Info, Client, ID, IP, Label, DType) ->
  {Secret, ValidationKey, ESecret, Validator} = make_secret(),
  DType1 = case DType of
             <<>> -> {legacy, base64:encode(Secret)};
             _ -> DType
           end,
  case sql_register_device(LServer, SJID, base64:encode(ESecret),
    base64:encode(Validator), Expire, Info, Client, ID, IP, Label,
    DType1) of
    ok ->
      {ok, Secret, ValidationKey};
    _ ->
      {error, db_failure}
  end.


make_secret() ->
  Secret = crypto:strong_rand_bytes(64),
  ValidationKey = crypto:strong_rand_bytes(64),
  ESecret = crypto:exor(Secret, ValidationKey),
  Validator = crypto:hmac(sha256, ESecret, Secret),
  {Secret, ValidationKey, ESecret, Validator}.

get_time_now() ->
  {{Y,Mo,D}, {H,Mn,S}} = calendar:universal_time(),
  FmtStr = "~2.10.0B/~2.10.0B/~4.10.0B at ~2.10.0B:~2.10.0B:~2.10.0B UTC",
  IsoStr = io_lib:format(FmtStr, [D, Mo, Y, H, Mn, S]),
  list_to_binary(IsoStr).

group_by([]) -> [];
group_by(KVList) ->
  Fun = fun({K,V}, D) -> dict:append(K, V, D) end,
  dict:to_list(lists:foldr(Fun , dict:new(), KVList)).

parse_raw_data(Server, #devices_device{expire = ERaw, info = IRaw,
  client = CRaw, public_label = LRaw, device_type = TRaw}) ->
  Expire = erlang:system_time(second) + parse_raw_expire(Server, ERaw),
  [Expire | [set_default(V) || V <- [IRaw, CRaw, LRaw, TRaw]]].

parse_raw_expire(Server, Value)->
  ConfigTime =  gen_mod:get_module_opt(Server, ?MODULE,
    device_expiration_time, 31536000),
  if
    Value == undefined -> ConfigTime;
    Value > ConfigTime -> ConfigTime;
    true -> Value
  end.

%%%%
%% SQL Functions
%%%%

sql_update_count(LUser, LServer, _DeviceID, _Count) ->
  _SJID = jid:to_string(jid:make(LUser,LServer)),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update devices set count=%(_Count)d where "
    " jid=%(_SJID)s and device_id = %(_DeviceID)s")).

sql_select_secret(LServer, _qJID, _qDevID) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(esecret)s,@(count)d,@(expire)d,@(validator)s"
    " from devices where jid=%(_qJID)s "
    " and device_id=%(_qDevID)s")) of
    {selected, [Val]} -> Val;
    {selected, []} -> {error, not_found};
    _ -> {error, db_error}
  end.

sql_select_secrets(LServer, _SJID) ->
  %%  To support legacy clients.
  %%  todo: Remove it when it is no longer needed.
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(esecret)s,@(count)d,@(device_id)s,@(expire)d"
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
    " where jid=%(_SJID)s and omemo_id != '' ")) of
    {selected, List} -> List;
    _ -> []
  end.

sql_refresh_session_info(JID,_DeviceID,_IP) ->
  LServer = JID#jid.lserver,
  _SJID = jid:to_string(jid:remove_resource(JID)),
  _TimeNow = erlang:system_time(second),
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

sql_register_device(LServer, _qJID, _, _qValidator, _qExpire,
    _qInfo, _qClient, _qID, _qIP, _qLabel, {legacy, Secret}) ->
  %%  To support legacy clients.
  %%  todo: Remove it when it is no longer needed.
  _qESecret = Secret,
  _qDType = <<>>,
  _qTimeNow = erlang:system_time(second),
  case ?SQL_UPSERT(
    LServer,
    "devices",
    ["!device_id=%(_qID)s",
      "!jid=%(_qJID)s",
      "info=%(_qInfo)s",
      "client=%(_qClient)s",
      "esecret=%(_qESecret)s",
      "validator=%(_qValidator)s",
      "ip=%(_qIP)s",
      "last_usage=%(_qTimeNow)d",
      "expire=%(_qExpire)d",
      "public_label=%(_qLabel)s",
      "device_type=%(_qDType)s"]) of
    ok -> ok;
    Err ->
      Err
  end;
sql_register_device(LServer, _qJID, _qESecret, _qValidator, _qExpire,
    _qInfo, _qClient, _qID, _qIP, _qLabel, _qDType) ->
  _qTimeNow = erlang:system_time(second),
  case ?SQL_UPSERT(
    LServer,
    "devices",
    ["!device_id=%(_qID)s",
      "!jid=%(_qJID)s",
      "info=%(_qInfo)s",
      "client=%(_qClient)s",
      "esecret=%(_qESecret)s",
      "validator=%(_qValidator)s",
      "ip=%(_qIP)s",
      "last_usage=%(_qTimeNow)d",
      "expire=%(_qExpire)d",
      "public_label=%(_qLabel)s",
      "device_type=%(_qDType)s"]) of
    ok -> ok;
    Err ->
      Err
  end.

sql_update_device(_LServer, _JID, <<>>, _Props) ->
  not_found;
sql_update_device(LServer, JID, ID, Props) when is_record(JID, jid) ->
  SJID = jid:to_string(jid:remove_resource(JID)),
  sql_update_device(LServer, SJID, ID, Props);
sql_update_device(LServer, SJID, ID, Props) ->
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

sql_select_user_device(LServer, _SJID, _DeviceID) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(device_id)s, @(expire)d, @(info)s, @(client)s,"
    " @(ip)s, @(last_usage)s, @(public_label)s, @(omemo_id)s, @(device_type)s "
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
    ?SQL("select @(device_id)s, @(expire)d, @(info)s, @(client)s,"
    " @(ip)s, @(last_usage)s, @(public_label)s, @(omemo_id)s, @(device_type)s "
    " from devices where jid=%(_SJID)s order by last_usage desc")) of
    {selected, Result} ->
      {ok, to_devices(Result)};
    _ ->
      error
  end.

sql_revoke_devices(LUser, LServer, IDs) ->
  BareJID = <<LUser/binary,"@",LServer/binary>>,
  IDClause = case IDs of
               all -> <<"1=1">>;
               _ -> device_id_clause(IDs)
             end,
 case ejabberd_sql:sql_query(
   LServer,
   [<<"delete from devices where jid= '">>, BareJID,
     <<"' and ">>, IDClause]) of
   {updated, 0} ->
     not_found;
   {updated,_N} ->
     ok;
   _ ->
     error
 end.

device_id_clause(IDs) ->
  Begin = <<"device_id in (">>,
  Fin = <<") ">>,
  L = [binary_to_list(<<$',U/binary,$'>>) || U <- IDs, U /= <<>>],
  IDValues = case string:join(L, ",") of
               [] -> <<"null">>;
               S -> list_to_binary(S)
             end,
  <<Begin/binary,IDValues/binary,Fin/binary>>.

to_devices(QueryResult) ->
  lists:map(fun(Values) ->
    CheckedValues = check_values(Values) ,
    [ID, Expire, Info, Client, IP, Last, Label, OMEMOId, DType] = CheckedValues,
    #devices_device{id = ID, expire = Expire, info = Info, client = Client,
      ip = IP, last_auth = Last, public_label = Label, omemo_id = OMEMOId,
      device_type = DType}
            end, QueryResult).

check_values(Tuple) ->
  lists:map(
    fun(null) -> undefined;
      (<<>>) -> undefined;
      (V) -> V
    end, tuple_to_list(Tuple)).

%% SQL for commands

sql_select_unused(Days, LServer) ->
  _qTime = erlang:system_time(second) - (Days*86400),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(jid)s,@(device_id)s"
    " from devices where last_usage < %(_qTime)d")) of
    {selected, UserDev} ->
      UserDev;
    _ ->
      error
  end.

sql_delete_unused(Days,LServer) ->
  _qTime = erlang:system_time(second) - (Days*86400),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from devices where last_usage < %(_qTime)d")) of
    {updated,_N} ->
      ok;
    _ ->
      error
  end.
