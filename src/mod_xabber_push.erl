%%%----------------------------------------------------------------------
%%% File    : mod_push.erl
%%% Author  : Holger Weiss <holger@zedat.fu-berlin.de>
%%% Purpose : Push Notifications (XEP-0357)
%%% Created : 15 Jul 2017 by Holger Weiss <holger@zedat.fu-berlin.de>
%%%
%%%
%%% ejabberd, Copyright (C) 2017-2018 ProcessOne
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

-module(mod_xabber_push).
-author('holger@zedat.fu-berlin.de').
-protocol({xep, 357, '0.2'}).

-behaviour(gen_mod).

%% gen_mod callbacks.
-export([start/2, stop/1, reload/3, mod_opt_type/1, mod_options/1, depends/2]).

%% ejabberd_hooks callbacks.
-export([disco_sm_features/5, c2s_session_pending/1, c2s_copy_session/2,
	 c2s_handle_cast/2, c2s_stanza/3, mam_message/6, offline_message/1,
  xabber_push_notification/4, remove_user/2, revoke_devices/3]).

%% gen_iq_handler callback.
-export([process_iq/1]).

%% ejabberd command.
-export([get_commands_spec/0, delete_old_sessions/1]).

%% API.
-export([get_jwk/3]).

%% For IQ callbacks
-export([delete_session/3]).

-include("ejabberd.hrl").
-include("ejabberd_commands.hrl").
-include("logger.hrl").
-include("xmpp.hrl").

-define(PUSH_CACHE, push_cache).

-type c2s_state() :: ejabberd_c2s:state().
-type timestamp() :: erlang:timestamp().
-type xabber_push_session() :: {timestamp(), ljid(), binary(), xdata(), binary(), binary()}.
-type err_reason() :: notfound | db_failure.

-callback init(binary(), gen_mod:opts())
	  -> any().
-callback store_session(binary(), binary(), timestamp(), jid(), binary(),
			xdata())
	  -> {ok, xabber_push_session()} | {error, err_reason()}.
-callback store_session(binary(), binary(), timestamp(), jid(), binary(),
		xdata(), binary(), binary(), any())
			-> {ok, xabber_push_session()} | {error, err_reason()}.
-callback lookup_session(binary(), binary(), jid(), binary())
	  -> {ok, xabber_push_session()} | {error, err_reason()}.
-callback lookup_session(binary(), binary(), timestamp())
	  -> {ok, xabber_push_session()} | {error, err_reason()}.
-callback lookup_sessions(binary(), binary(), jid())
	  -> {ok, [xabber_push_session()]} | {error, err_reason()}.
-callback lookup_sessions(binary(), binary())
	  -> {ok, [xabber_push_session()]} | {error, err_reason()}.
-callback lookup_sessions(binary())
	  -> {ok, [xabber_push_session()]} | {error, err_reason()}.
-callback lookup_device_sessions(binary(), binary(), list())
			-> {ok, [xabber_push_session()]} | {error, err_reason()}.
-callback delete_session(binary(), binary(), timestamp())
	  -> ok | {error, err_reason()}.
-callback delete_old_sessions(binary() | global, erlang:timestamp())
	  -> ok | {error, err_reason()}.
-callback use_cache(binary())
	  -> boolean().
-callback cache_nodes(binary())
	  -> [node()].

-optional_callbacks([use_cache/1, cache_nodes/1]).

%%--------------------------------------------------------------------
%% gen_mod callbacks.
%%--------------------------------------------------------------------
-spec start(binary(), gen_mod:opts()) -> ok.
start(Host, Opts) ->
    Mod = gen_mod:db_mod(Host, Opts, ?MODULE),
    Mod:init(Host, Opts),
    init_cache(Mod, Host, Opts),
    register_iq_handlers(Host),
    register_hooks(Host),
    ejabberd_commands:register_commands(get_commands_spec()).

-spec stop(binary()) -> ok.
stop(Host) ->
    unregister_hooks(Host),
    unregister_iq_handlers(Host),
    case gen_mod:is_loaded_elsewhere(Host, ?MODULE) of
        false ->
            ejabberd_commands:unregister_commands(get_commands_spec());
        true ->
            ok
    end.

-spec reload(binary(), gen_mod:opts(), gen_mod:opts()) -> ok.
reload(Host, NewOpts, OldOpts) ->
    NewMod = gen_mod:db_mod(Host, NewOpts, ?MODULE),
    OldMod = gen_mod:db_mod(Host, OldOpts, ?MODULE),
    if NewMod /= OldMod ->
	    NewMod:init(Host, NewOpts);
       true ->
	    ok
    end.

-spec depends(binary(), gen_mod:opts()) -> [{module(), hard | soft}].
depends(_Host, _Opts) ->
    [].

-spec mod_opt_type(atom()) -> fun((term()) -> term()) | [atom()].
mod_opt_type(include_sender) ->
    fun (B) when is_boolean(B) -> B end;
mod_opt_type(include_body) ->
    fun (B) when is_boolean(B) -> B;
        (S) -> iolist_to_binary(S)
    end;
mod_opt_type(db_type) ->
    fun(T) -> ejabberd_config:v_db(?MODULE, T) end;
mod_opt_type(O) when O == cache_life_time; O == cache_size ->
    fun(I) when is_integer(I), I > 0 -> I;
       (infinity) -> infinity
    end;
mod_opt_type(O) when O == use_cache; O == cache_missed ->
    fun (B) when is_boolean(B) -> B end.

-spec mod_options(binary()) -> [{atom(), any()}].
mod_options(Host) ->
    [{include_sender, false},
     {include_body, false},
     {db_type, ejabberd_config:default_db(Host, ?MODULE)},
     {use_cache, ejabberd_config:use_cache(Host)},
     {cache_size, ejabberd_config:cache_size(Host)},
     {cache_missed, ejabberd_config:cache_missed(Host)},
     {cache_life_time, ejabberd_config:cache_life_time(Host)}].

%%--------------------------------------------------------------------
%% ejabberd command callback.
%%--------------------------------------------------------------------
-spec get_commands_spec() -> [ejabberd_commands()].
get_commands_spec() ->
    [#ejabberd_commands{name = delete_old_push_sessions, tags = [purge],
			desc = "Remove push sessions older than DAYS",
			module = ?MODULE, function = delete_old_sessions,
			args = [{days, integer}],
			result = {res, rescode}}].

-spec delete_old_sessions(non_neg_integer()) -> ok | any().
delete_old_sessions(Days) ->
    CurrentTime = p1_time_compat:system_time(micro_seconds),
    Diff = Days * 24 * 60 * 60 * 1000000,
    TimeStamp = misc:usec_to_now(CurrentTime - Diff),
    DBTypes = lists:usort(
		lists:map(
		  fun(Host) ->
			  case gen_mod:get_module_opt(Host, ?MODULE, db_type) of
			      sql -> {sql, Host};
			      Other -> {Other, global}
			  end
		  end, ?MYHOSTS)),
    Results = lists:map(
		fun({DBType, Host}) ->
			Mod = gen_mod:db_mod(DBType, ?MODULE),
			Mod:delete_old_sessions(Host, TimeStamp)
		end, DBTypes),
    ets_cache:clear(?PUSH_CACHE, ejabberd_cluster:get_nodes()),
    case lists:filter(fun(Res) -> Res /= ok end, Results) of
	[] ->
	    ?INFO_MSG("Deleted push sessions older than ~B days", [Days]),
	    ok;
	[NotOk | _] ->
	    ?ERROR_MSG("Error while deleting old push sessions: ~p", [NotOk]),
	    NotOk
    end.

%%--------------------------------------------------------------------
%% Register/unregister hooks.
%%--------------------------------------------------------------------
-spec register_hooks(binary()) -> ok.
register_hooks(Host) ->
    ejabberd_hooks:add(revoke_devices, Host, ?MODULE, revoke_devices, 80),
	  ejabberd_hooks:add(xabber_push_notification, Host, ?MODULE,
			xabber_push_notification, 60),
    ejabberd_hooks:add(disco_sm_features, Host, ?MODULE,
		       disco_sm_features, 50),
    ejabberd_hooks:add(c2s_session_pending, Host, ?MODULE,
		       c2s_session_pending, 50),
    ejabberd_hooks:add(c2s_copy_session, Host, ?MODULE,
		       c2s_copy_session, 50),
    ejabberd_hooks:add(c2s_handle_cast, Host, ?MODULE,
		       c2s_handle_cast, 50),
    ejabberd_hooks:add(c2s_handle_send, Host, ?MODULE,
		       c2s_stanza, 50),
    ejabberd_hooks:add(store_mam_message, Host, ?MODULE,
		       mam_message, 50),
    ejabberd_hooks:add(store_offline_message, Host, ?MODULE,
		       offline_message, 50),
    ejabberd_hooks:add(remove_user, Host, ?MODULE,
		       remove_user, 50).

-spec unregister_hooks(binary()) -> ok.
unregister_hooks(Host) ->
    ejabberd_hooks:delete(revoke_devices, Host, ?MODULE, revoke_devices, 80),
	  ejabberd_hooks:delete(xabber_push_notification, Host, ?MODULE,
		xabber_push_notification, 60),
    ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE,
			  disco_sm_features, 50),
    ejabberd_hooks:delete(c2s_session_pending, Host, ?MODULE,
			  c2s_session_pending, 50),
    ejabberd_hooks:delete(c2s_copy_session, Host, ?MODULE,
			  c2s_copy_session, 50),
    ejabberd_hooks:delete(c2s_handle_cast, Host, ?MODULE,
			  c2s_handle_cast, 50),
    ejabberd_hooks:delete(c2s_handle_send, Host, ?MODULE,
			  c2s_stanza, 50),
    ejabberd_hooks:delete(store_mam_message, Host, ?MODULE,
			  mam_message, 50),
    ejabberd_hooks:delete(store_offline_message, Host, ?MODULE,
			  offline_message, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE,
			  remove_user, 50).

%%--------------------------------------------------------------------
%% Service discovery.
%%--------------------------------------------------------------------
-spec disco_sm_features(empty | {result, [binary()]} | {error, stanza_error()},
			jid(), jid(), binary(), binary())
      -> {result, [binary()]} | {error, stanza_error()}.
disco_sm_features(empty, From, To, Node, Lang) ->
    disco_sm_features({result, []}, From, To, Node, Lang);
disco_sm_features({result, OtherFeatures},
		  #jid{luser = U, lserver = S},
		  #jid{luser = U, lserver = S}, <<"">>, _Lang) ->
    {result, [?NS_XABBER_PUSH, ?NS_PUSH_0] ++ OtherFeatures};
disco_sm_features(Acc, _From, _To, _Node, _Lang) ->
    Acc.

%%--------------------------------------------------------------------
%% IQ handlers.
%%--------------------------------------------------------------------
-spec register_iq_handlers(binary()) -> ok.
register_iq_handlers(Host) ->
  gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_XABBER_PUSH,
    ?MODULE, process_iq),
  case gen_mod:is_loaded(Host, mod_push) of
    false ->
      gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_PUSH_0,
        ?MODULE, process_iq);
    _ ->
      ok
  end.

-spec unregister_iq_handlers(binary()) -> ok.
unregister_iq_handlers(Host) ->
  gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_XABBER_PUSH),
  gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_PUSH_0).

-spec process_iq(iq()) -> iq().
process_iq(#iq{type = get, lang = Lang} = IQ) ->
    Txt = <<"Value 'get' of 'type' attribute is not allowed">>,
    xmpp:make_error(IQ, xmpp:err_not_allowed(Txt, Lang));
process_iq(#iq{lang = Lang, sub_els = [#xabber_push_enable{node = <<>>}]} = IQ) ->
    Txt = <<"Enabling push without 'node' attribute is not supported">>,
    xmpp:make_error(IQ, xmpp:err_feature_not_implemented(Txt, Lang));
process_iq(#iq{from = #jid{lserver = LServer}, to = #jid{lserver = LServer},
    sub_els = [#xabber_push_enable{}]} = IQ) ->
  #iq{from = JID, lang = Lang, sub_els = [
    #xabber_push_enable{jid = PushJID, node = Node, xdata = XData,
      push_security = Security}]} = IQ,
  Result = case Security of
             #xabber_push_security{cipher = Cipher,
               encryption_key = #xabber_encryption_key{data = Key}}
               when Cipher /= <<>> orelse Key /=<<>> ->
               ?INFO_MSG("Push with encryption enabled for ~p",[jid:to_string(JID)]),
               enable(JID, PushJID, Node, XData, Cipher, Key);
             #xabber_push_security{} ->
               {error, bad_request};
             _ ->
               enable(JID, PushJID, Node, XData)
           end,
  case Result of
    {ok, TS, DeviceID, EKey} ->
      El = case mod_http_iq:get_url(LServer) of
             undefined -> undefined;
             URL ->
               JWT = make_jwt(LServer, JID, TS, EKey, DeviceID),
               make_enable_result(URL,JWT)
           end,
      xmpp:make_iq_result(IQ,El);
    {error, bad_request} ->
      xmpp:make_error(IQ, xmpp:err_bad_request());
    {error, db_failure} ->
      Txt = <<"Database failure">>,
      xmpp:make_error(IQ, xmpp:err_internal_server_error(Txt, Lang));
    {error, notfound} ->
      Txt = <<"User session not found">>,
      xmpp:make_error(IQ, xmpp:err_item_not_found(Txt, Lang))
  end;
process_iq(#iq{from = #jid{lserver = LServer} = JID,
  to = #jid{lserver = LServer}, lang = Lang,
  sub_els = [#xabber_push_disable{jid = PushJID, node = Node}]} = IQ) ->
  case disable(JID, PushJID, Node) of
    ok ->
      xmpp:make_iq_result(IQ);
    {error, db_failure} ->
      Txt = <<"Database failure">>,
      xmpp:make_error(IQ, xmpp:err_internal_server_error(Txt, Lang));
    {error, notfound} ->
      Txt = <<"Push record not found">>,
      xmpp:make_error(IQ, xmpp:err_item_not_found(Txt, Lang))
  end;
%% Legacy
process_iq(#iq{sub_els = [#push_enable{jid = J,  node = N, xdata = X}]} = IQ) ->
  XPE = #xabber_push_enable{jid = J, node = N, xdata = X},
  process_iq(IQ#iq{sub_els = [XPE]});
process_iq(#iq{sub_els = [#push_disable{jid = J, node = N}]} = IQ) ->
  XPD = #xabber_push_disable{jid = J, node = N},
  process_iq(IQ#iq{sub_els = [XPD]});
process_iq(IQ) ->
  xmpp:make_error(IQ, xmpp:err_not_allowed()).

-spec enable(jid(), jid(), binary(), xdata()) -> ok | {error, err_reason()}.
enable(#jid{luser = LUser, lserver = LServer, lresource = LResource} = JID,
       PushJID, Node, XData) ->
    case ejabberd_sm:get_session_sid(LUser, LServer, LResource) of
	{TS, PID} ->
	    case store_session(LUser, LServer, TS, PushJID, Node, XData) of
		{ok, _} ->
		    ?INFO_MSG("Enabling push notifications for ~s",
			      [jid:encode(JID)]),
		    ejabberd_c2s:cast(PID, push_enable);
		{error, _} = Err ->
		    ?ERROR_MSG("Cannot enable push for ~s: database error",
			       [jid:encode(JID)]),
		    Err
	    end;
	none ->
	    ?WARNING_MSG("Cannot enable push for ~s: session not found",
			 [jid:encode(JID)]),
	    {error, notfound}
    end.

enable(#jid{luser = LUser, lserver = LServer, lresource = LResource} = JID,
		PushJID, Node, XData,Cipher,EncryptionKey) ->
	case ejabberd_sm:get_session_sid(LUser, LServer, LResource) of
		{TS, PID} ->
			DeviceID = case ejabberd_sm:get_user_info(LUser, LServer, LResource) of
									 [_H|Info] ->
										 proplists:get_value(device_id, Info, undefined);
									 _ -> undefined
								 end,
			case store_session(LUser, LServer, TS, PushJID, Node, XData,Cipher,EncryptionKey, DeviceID) of
				{ok, _} ->
					?INFO_MSG("Enabling push notifications for ~s",
						[jid:encode(JID)]),
					ejabberd_c2s:cast(PID, push_enable),
					{ok, TS, DeviceID, EncryptionKey};
				{error, _} = Err ->
					?ERROR_MSG("Cannot enable push for ~s: database error",
						[jid:encode(JID)]),
					Err
			end;
		none ->
			?WARNING_MSG("Cannot enable push for ~s: session not found",
				[jid:encode(JID)]),
			{error, notfound}
	end.

-spec disable(jid(), jid(), binary() | undefined) -> ok | {error, err_reason()}.
disable(#jid{luser = LUser, lserver = LServer, lresource = LResource} = JID,
       PushJID, Node) ->
    case ejabberd_sm:get_session_sid(LUser, LServer, LResource) of
	{_TS, PID} ->
	    ?INFO_MSG("Disabling push notifications for ~s",
		      [jid:encode(JID)]),
	    ejabberd_c2s:cast(PID, push_disable);
	none ->
	    ?WARNING_MSG("Session not found while disabling push for ~s",
			 [jid:encode(JID)])
    end,
    if Node /= <<>> ->
	   delete_session(LUser, LServer, PushJID, Node);
       true ->
	   delete_sessions(LUser, LServer, PushJID)
    end.

%%--------------------------------------------------------------------
%% Hook callbacks.
%%--------------------------------------------------------------------
revoke_devices(LUser, LServer, DevIDList) ->
	?INFO_MSG("Disabling push notifications for ~s@~s on devices:~p",[LUser, LServer, DevIDList]),
	Mod = gen_mod:db_mod(LServer, ?MODULE),
  LookupResult = Mod:lookup_device_sessions(LUser, LServer, DevIDList),
  Sessions = case LookupResult of
                {ok, Ss} -> Ss;
                _ -> []
              end,
  Devices = [#devices_device{id = DeviceID} || DeviceID <- DevIDList],
  lists:foreach(
    fun({TS, PushLJID, Node, XData, Cipher, Key}) ->
      Callback = iq_callback(LUser, LServer, TS),
      From =  jid:from_string(LServer),
      Message = #message{type = headline, from = From,
        sub_els = [#devices_revoke{devices = Devices}]},
      do_notify(<<"message">>, LServer, PushLJID, Node, XData, [Message], Callback, Cipher, Key)
    end, Sessions),
	LookupFun = fun() -> LookupResult end,
	delete_sessions(LUser, LServer, LookupFun, Mod).

-spec c2s_stanza(c2s_state(), xmpp_element() | xmlel(), term()) -> c2s_state().
c2s_stanza(State, #stream_error{}, _SendResult) ->
  State;
c2s_stanza(#{push_enabled := true, mgmt_state := pending} = State, Pkt, _SendResult) ->
  ?DEBUG("Notifying client of stanza", []),
  case xmpp:is_stanza(Pkt) of
    true -> notify(State, Pkt);
    _ -> ok
  end,
  State;
c2s_stanza(State, _Pkt, _SendResult) ->
  State.

-spec mam_message(message() | drop, binary(), binary(), jid(),
		  chat | groupchat, recv | send) -> message().
mam_message(Pkt, _LUser, _LServer, _Peer, _Type, _Dir) ->
    Pkt.

-spec offline_message(message()) -> message().
offline_message(#message{meta = #{mam_archived := true}} = Pkt) ->
    Pkt; % Push notification was triggered via MAM.
offline_message(#message{to = #jid{luser = LUser, lserver = LServer}} = Pkt) ->
    case lookup_sessions(LUser, LServer) of
	{ok, [_|_] = Clients} ->
	    ?DEBUG("Notifying ~s@~s of offline message", [LUser, LServer]),
	    notify(LUser, LServer, Clients, Pkt);
	_ ->
	    ok
    end,
    Pkt.

-spec c2s_session_pending(c2s_state()) -> c2s_state().
c2s_session_pending(#{push_enabled := true, mgmt_queue := Queue} = State) ->
    case p1_queue:len(Queue) of
	Len when Len > 0 ->
	    ?DEBUG("Notifying client of unacknowledged stanza(s)", []),
	    Pkt = mod_stream_mgmt:queue_find(fun is_message_with_body/1, Queue),
	    notify(State, Pkt),
	    State;
	0 ->
	    State
    end;
c2s_session_pending(State) ->
    State.

-spec c2s_copy_session(c2s_state(), c2s_state()) -> c2s_state().
c2s_copy_session(State, #{push_enabled := true}) ->
    State#{push_enabled => true};
c2s_copy_session(State, _) ->
    State.

-spec c2s_handle_cast(c2s_state(), any()) -> c2s_state() | {stop, c2s_state()}.
c2s_handle_cast(State, push_enable) ->
    {stop, State#{push_enabled => true}};
c2s_handle_cast(State, push_disable) ->
    {stop, maps:remove(push_enabled, State)};
c2s_handle_cast(State, _Msg) ->
    State.

-spec remove_user(binary(), binary()) -> ok | {error, err_reason()}.
remove_user(LUser, LServer) ->
    ?INFO_MSG("Removing any push sessions of ~s@~s", [LUser, LServer]),
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    LookupFun = fun() -> Mod:lookup_sessions(LUser, LServer) end,
    delete_sessions(LUser, LServer, LookupFun, Mod).

%%--------------------------------------------------------------------
%% API.
%%--------------------------------------------------------------------
get_jwk(LUser, LServer, DeviceID) ->
  Mod = gen_mod:db_mod(LServer, ?MODULE),
  LookupResult = Mod:lookup_device_sessions(LUser, LServer, [DeviceID]),
  case LookupResult of
    {ok, [{TS, _, _, _, _, EKey}]} ->
      make_jwk(TS, base64:decode(EKey), DeviceID);
    _ -> undefined
  end.

%%--------------------------------------------------------------------
%% Generate push notifications.
%%--------------------------------------------------------------------
-spec notify(c2s_state(), xmpp_element() | xmlel() | none) -> ok.
notify(_, none) -> ok;
notify(#{jid := #jid{luser = LUser, lserver = LServer}, sid := {TS, _}}, Pkt) ->
  case is_muted(LUser, LServer, Pkt) of
    false ->
      case lookup_session(LUser, LServer, TS) of
        {ok, Client} ->
          notify(LUser, LServer, [Client], Pkt);
        _Err ->
          ?ERROR_MSG("Error to notify ~p~n",[LUser])
      end;
    _ ->
      ok
  end.

-spec notify(binary(), binary(), [xabber_push_session()],
    xmpp_element() | xmlel() | none) -> ok.
notify(LUser, LServer, Clients, Pkt) ->
    lists:foreach(
      fun({TS, PushLJID, Node, XData, Cipher, Key}) ->
        Callback = iq_callback(LUser, LServer, TS),
        notify(LServer, PushLJID, Node, XData, Pkt, Callback, Cipher, Key)
      end, Clients).

-spec notify(binary(), ljid(), binary(), xdata(),
    xmpp_element(), binary(), binary() | xmlel() | none,
    fun((iq() | timeout) -> any())) -> ok.
notify(_S, _PushSrv, _Node, _XData, #message{body = []}, _HR, <<>>, <<>>) ->
  ok;
notify(_S, _PushSrv, _Node, _XData, #message{type = Type}, _Cbk, _C, _K) when Type /= chat->
  ok;
notify(LServer, PushSrv, Node, XData, #message{sub_els = [#carbons_received{} = Received]},
    Callback, Cipher, Key) ->
  Fwd = Received#carbons_received.forwarded,
  SubEls = Fwd#forwarded.sub_els,
  notify(LServer, PushSrv, Node, XData, hd(SubEls), Callback, Cipher, Key);
notify(LServer, PushSrv, Node, XData, #message{body = []} = Pkt,
    Callback, Cipher, Key) ->
  case xmpp:get_subtag(Pkt, #message_displayed{}) of
    false ->
      case xmpp:get_subtag(Pkt, #jingle_propose{}) of
        false -> ok;
        _ ->
          do_notify(<<"call">>, LServer, PushSrv, Node, XData, [Pkt],
            Callback, Cipher, Key)
      end;
    D ->
      do_notify(<<"displayed">>, LServer, PushSrv, Node, XData, [D],
        Callback, Cipher, Key)
  end;
notify(LServer, PushSrv, Node, XData, #message{}, Callback, <<>>, <<>>) ->
  do_notify(<<"message">>, LServer, PushSrv, Node, XData,
    [], Callback, <<>>, <<>>) ;
notify(LServer, PushLJID, Node, XData, #message{} = Pkt,
    Callback, Cipher, Key) ->
  {PType, Payload} = case xmpp:get_subtag(Pkt, #jingle_propose{}) of
                       false ->
                         {<<"message">>, [get_stanza_id(Pkt)]};
                       _ ->
                         {<<"call">>, [Pkt]}
                     end,
  do_notify(PType, LServer, PushLJID, Node, XData,
    Payload, Callback, Cipher, Key);
notify(LServer, PushSrv, Node, XData, #presence{type = subscribe} = Pkt,
    Callback, Cipher, Key) ->
  do_notify(<<"subscribe">>, LServer, PushSrv, Node, XData, [Pkt],
    Callback, Cipher, Key);
notify(_, _, _, _, _, _, _, _) ->
  ok.

do_notify(PushType, LServer, PushLJID, Node, XData, PayloadList,
    Callback, Cipher, Key) ->
  From = jid:make(LServer),
  SubEls = if
             PayloadList == [undefined] orelse PayloadList == [] -> [];
             Cipher == <<>> orelse Key == <<>> -> [];
             true ->
               [make_encryption(PayloadList, Cipher, Key),
                 make_new_form(PushType)]
           end,
  Item = #ps_item{sub_els = [#xabber_push_notification{sub_els = SubEls}]},
  PubSub = #pubsub{publish = #ps_publish{node = Node, items = [Item]},
    publish_options = XData},
  IQ = #iq{type = set,
    from = From,
    to = jid:make(PushLJID),
    id = randoms:get_string(),
    sub_els = [PubSub]},
  ejabberd_router:route_iq(IQ, Callback),true.


%%--------------------------------------------------------------------
%% Miscellaneous.
%%--------------------------------------------------------------------
-spec is_message_with_body(stanza()) -> boolean().
is_message_with_body(#message{} = Msg) ->
    get_body_text(Msg) /= none;
is_message_with_body(_Stanza) ->
    false.

%%--------------------------------------------------------------------
%% Internal functions.
%%--------------------------------------------------------------------
-spec store_session(binary(), binary(), timestamp(), jid(), binary(), xdata())
      -> {ok, xabber_push_session()} | {error, err_reason()}.
store_session(LUser, LServer, TS, PushJID, Node, XData) ->
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    delete_session(LUser, LServer, PushJID, Node),
    case use_cache(Mod, LServer) of
	true ->
	    ets_cache:delete(?PUSH_CACHE, {LUser, LServer},
			     cache_nodes(Mod, LServer)),
	    ets_cache:update(
		?PUSH_CACHE,
		{LUser, LServer, TS}, {ok, {TS, PushJID, Node, XData}},
		fun() ->
			Mod:store_session(LUser, LServer, TS, PushJID, Node,
					  XData)
		end, cache_nodes(Mod, LServer));
	false ->
	    Mod:store_session(LUser, LServer, TS, PushJID, Node, XData)
    end.

-spec store_session(binary(), binary(), timestamp(), jid(), binary(), xdata(),binary(),binary(),any())
			-> {ok, xabber_push_session()} | {error, err_reason()}.
store_session(LUser, LServer, TS, PushJID, Node, XData, Cipher, EncryptionKey, DeviceID) ->
	Mod = gen_mod:db_mod(LServer, ?MODULE),
	Cache = use_cache(Mod, LServer),
	delete_session(LUser, LServer, PushJID, Node),
	case Cache of
		true ->
			ets_cache:delete(?PUSH_CACHE, {LUser, LServer},
				cache_nodes(Mod, LServer)),
			ets_cache:update(
				?PUSH_CACHE,
				{LUser, LServer, TS}, {ok, {TS, PushJID, Node, XData}},
				fun() ->
					Mod:store_session(LUser, LServer, TS, PushJID, Node,
						XData, Cipher, EncryptionKey, DeviceID)
				end, cache_nodes(Mod, LServer));
		false ->
			Mod:store_session(LUser, LServer, TS, PushJID, Node, XData, Cipher, EncryptionKey, DeviceID)
	end.

-spec lookup_session(binary(), binary(), timestamp())
      -> {ok, xabber_push_session()} | error | {error, err_reason()}.
lookup_session(LUser, LServer, TS) ->
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    case use_cache(Mod, LServer) of
	true ->
	    ets_cache:lookup(
	      ?PUSH_CACHE, {LUser, LServer, TS},
	      fun() -> Mod:lookup_session(LUser, LServer, TS) end);
	false ->
	    Mod:lookup_session(LUser, LServer, TS)
    end.

-spec lookup_sessions(binary(), binary()) -> {ok, [xabber_push_session()]} | {error, err_reason()}.
lookup_sessions(LUser, LServer) ->
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    case use_cache(Mod, LServer) of
	true ->
	    ets_cache:lookup(
	      ?PUSH_CACHE, {LUser, LServer},
	      fun() -> Mod:lookup_sessions(LUser, LServer) end);
	false ->
	    Mod:lookup_sessions(LUser, LServer)
    end.

-spec delete_session(binary(), binary(), timestamp()) -> ok | {error, db_failure}.
delete_session(LUser, LServer, TS) ->
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    case Mod:delete_session(LUser, LServer, TS) of
	ok ->
	    case use_cache(Mod, LServer) of
		true ->
		    ets_cache:delete(?PUSH_CACHE, {LUser, LServer},
				     cache_nodes(Mod, LServer)),
		    ets_cache:delete(?PUSH_CACHE, {LUser, LServer, TS},
				     cache_nodes(Mod, LServer));
		false ->
		    ok
	    end;
	{error, _} = Err ->
	    Err
    end.

-spec delete_session(binary(), binary(), jid(), binary()) -> ok | {error, err_reason()}.
delete_session(LUser, LServer, PushJID, Node) ->
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    case Mod:lookup_session(LUser, LServer, PushJID, Node) of
	{ok, {TS, _, _, _, _, _}} ->
	    delete_session(LUser, LServer, TS);
	error ->
	    {error, notfound};
	{error, _} = Err ->
	    Err
    end.

-spec delete_sessions(binary(), binary(), jid()) -> ok | {error, err_reason()}.
delete_sessions(LUser, LServer, PushJID) ->
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    LookupFun = fun() -> Mod:lookup_sessions(LUser, LServer, PushJID) end,
    delete_sessions(LUser, LServer, LookupFun, Mod).

-spec delete_sessions(binary(), binary(), fun(() -> any()), module())
      -> ok | {error, err_reason()}.
delete_sessions(LUser, LServer, LookupFun, Mod) ->
    case LookupFun() of
	{ok, []} ->
	    {error, notfound};
	{ok, Clients} ->
	    case use_cache(Mod, LServer) of
		true ->
		    ets_cache:delete(?PUSH_CACHE, {LUser, LServer},
				     cache_nodes(Mod, LServer));
		false ->
		    ok
	    end,
	    lists:foreach(
	      fun({TS, _, _, _,_,_}) ->
		      ok = Mod:delete_session(LUser, LServer, TS),
		      case use_cache(Mod, LServer) of
			  true ->
			      ets_cache:delete(?PUSH_CACHE,
					       {LUser, LServer, TS},
					       cache_nodes(Mod, LServer));
			  false ->
			      ok
		      end
	      end, Clients);
	{error, _} = Err ->
	    Err
    end.

-spec drop_online_sessions(binary(), binary(), [xabber_push_session()])
      -> [xabber_push_session()].
drop_online_sessions(LUser, LServer, Clients) ->
    SessIDs = ejabberd_sm:get_session_sids(LUser, LServer),
    [Client || {TS, _, _, _, _, _} = Client <- Clients,
	       lists:keyfind(TS, 1, SessIDs) == false].

get_stanza_id(#message{to = To, meta = #{stanza_id := TS}}) ->
  #stanza_id{id = integer_to_binary(TS), by = jid:remove_resource(To)};
get_stanza_id(_Pkt) -> undefined.

-spec get_body_text(message()) -> binary() | none.
get_body_text(#message{body = Body} = Msg) ->
    case xmpp:get_text(Body) of
	Text when byte_size(Text) > 0 ->
	    Text;
	<<>> ->
	    case body_is_encrypted(Msg) of
		true ->
		    <<"(encrypted)">>;
		false ->
		    none
	    end
    end.

-spec body_is_encrypted(message()) -> boolean().
body_is_encrypted(#message{sub_els = SubEls}) ->
    lists:keyfind(<<"encrypted">>, #xmlel.name, SubEls) /= false.

%%--------------------------------------------------------------------
%% Caching.
%%--------------------------------------------------------------------
-spec init_cache(module(), binary(), gen_mod:opts()) -> ok.
init_cache(Mod, Host, Opts) ->
    case use_cache(Mod, Host) of
	true ->
	    CacheOpts = cache_opts(Opts),
	    ets_cache:new(?PUSH_CACHE, CacheOpts);
	false ->
	    ets_cache:delete(?PUSH_CACHE)
    end.

-spec cache_opts(gen_mod:opts()) -> [proplists:property()].
cache_opts(Opts) ->
    MaxSize = gen_mod:get_opt(cache_size, Opts),
    CacheMissed = gen_mod:get_opt(cache_missed, Opts),
    LifeTime = case gen_mod:get_opt(cache_life_time, Opts) of
		   infinity -> infinity;
		   I -> timer:seconds(I)
	       end,
    [{max_size, MaxSize}, {cache_missed, CacheMissed}, {life_time, LifeTime}].

-spec use_cache(module(), binary()) -> boolean().
use_cache(Mod, Host) ->
    case erlang:function_exported(Mod, use_cache, 1) of
	true -> Mod:use_cache(Host);
	false -> gen_mod:get_module_opt(Host, ?MODULE, use_cache)
    end.

-spec cache_nodes(module(), binary()) -> [node()].
cache_nodes(Mod, Host) ->
    case erlang:function_exported(Mod, cache_nodes, 1) of
	true -> Mod:cache_nodes(Host);
	false -> ejabberd_cluster:get_nodes()
    end.

make_encryption(Values, Cipher, KeyBase) ->
	Key = base64:decode(KeyBase),
	{Length, Encrypted} = case Cipher of
													<<"urn:xmpp:ciphers:blowfish-cbc">> ->
														encrypt(blowfish_cbc, Key, make_string(Values));
													_ ->
														encrypt(aes_cbc256, Key, make_string(Values))
												end,
	#encrypted{'iv-length' = Length, data = Encrypted}.

encrypt(Mode, Key, Value) ->
  Length = case Mode of
             blowfish_cbc -> 8;
             aes_cbc256 -> 16
           end,
  Padding = size(Value) rem 16,
  Bits = (16-Padding)*8,
  IV = crypto:strong_rand_bytes(Length),
  CipherText = crypto:block_encrypt(Mode,Key,IV,<<Value/binary,0:Bits>>),
  Secret = <<IV/binary, CipherText/binary>>,
  {Length, Secret}.

make_string(Values) ->
	list_to_binary(lists:map(fun(X) -> fxml:element_to_binary(xmpp:encode(X)) end, Values)).

xabber_push_notification(PType, LUser, LServer, Payload) ->
  Clients = case lookup_sessions(LUser, LServer) of
              {ok, [_|_] = Clients1} ->
                if
                  PType == <<"call">> orelse PType == <<"data">> ->
                    Clients1;
                  true ->
                    drop_online_sessions(LUser, LServer, Clients1)
                end;
              _ -> []
            end,
  lists:foreach(
    fun({TS, PushLJID, Node, XData, Cipher, Key}) ->
      Callback = iq_callback(LUser, LServer, TS),
      do_notify(PType, LServer, PushLJID, Node, XData, [Payload], Callback, Cipher, Key)
    end, Clients).

iq_callback(LUser, LServer, TS) ->
  fun
    (#iq{type = result}) -> ok;
    (#iq{type = error} = IQ) ->
      Err = get_error(IQ),
      ?ERROR_MSG(
        "Error sending push notification for user ~s@~s: ~s",
        [LUser, LServer, Err]),
      spawn(?MODULE, delete_session, [LUser, LServer, TS]);
    (timeout) -> ok % Hmm.
  end.

make_new_form(<<"outgoing">>) ->
  ExtraFields = [#xdata_field{var = <<"outgoing">>, values = [<<"true">>]}],
  make_new_form(<<"message">>, ExtraFields);
make_new_form(PType) ->
  make_new_form(PType, []).

make_new_form(PType, ExtraFields) ->
  Fields = [
    #xdata_field{var = <<"FORM_TYPE">>, type = hidden, values = [?NS_XABBER_PUSH_INFO]},
    #xdata_field{var = <<"type">>, values = [PType]}
    ] ++ ExtraFields,
  #xdata{type = result, fields = Fields}.

make_enable_result(URL, JWT) ->
  Fields = [
    #xdata_field{var = <<"FORM_TYPE">>, type = hidden, values = [?NS_XABBER_PUSH]},
    #xdata_field{var = <<"url">>, values = [URL]},
    #xdata_field{var = <<"jwt">>, values = [JWT]}
    ],
  #xdata{type = result, fields = Fields}.

is_muted(LUser, LServer, Pkt) ->
  From = xmpp:get_from(Pkt),
  Conversation = jid:to_string(jid:remove_resource(From)),
  mod_sync:is_muted(LUser, LServer, Conversation).

-spec get_error(stanza()) -> binary().
get_error(Pkt) ->
  case xmpp:get_error(Pkt) of
    #stanza_error{} = Err ->
      format_stanza_error(Err);
    undefined ->
      <<"unrecognized error">>
  end.

-spec format_stanza_error(stanza_error()) -> binary().
format_stanza_error(#stanza_error{reason = Reason, text = Txt}) ->
  Slogan = case Reason of
             undefined -> <<"no reason">>;
             #gone{} -> <<"gone">>;
             #redirect{} -> <<"redirect">>;
             _ -> erlang:atom_to_binary(Reason, latin1)
           end,
  case xmpp:get_text(Txt) of
    <<"">> ->
      Slogan;
    Data ->
      <<Data/binary, " (", Slogan/binary, ")">>
  end.

make_jwt(Server, JID, TS, EKey, DeviceID)->
  Sub = jid:to_string(jid:replace_resource(JID, DeviceID)),
  Exp = erlang:system_time(second) + (30*24*60*60) + randoms:uniform(24*60*60),
  JWK = make_jwk(TS, EKey, DeviceID),
  JWS = #{<<"alg">> => <<"HS256">>},
  JWT = #{<<"iss">> => Server, <<"sub">> => Sub, <<"exp">> => Exp},
  Signed = jose_jwt:sign(JWK, JWS, JWT),
  {_ , Compact} = jose_jws:compact(Signed),
  Compact.

make_jwk(TS, EKey, DeviceID)->
  BTS = integer_to_binary(misc:now_to_usec(TS)),
  Data = <<BTS/binary,EKey/binary,DeviceID/binary>>,
  Secret = crypto:hash(sha256, Data),
  #{<<"kty">> => <<"oct">>,
    <<"k">> => base64url:encode(Secret)}.
