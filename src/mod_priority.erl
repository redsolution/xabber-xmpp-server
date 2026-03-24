%%%-------------------------------------------------------------------
%%% File    : mod_priority.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : XEP Priority messages
%%% Created : 27 Sep 2025 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%%
%%%
%%% xabberserver, Copyright (C) 2007-2025  Redsolution
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
-module(mod_priority).
-author('ilya.kalashnikov@redsolution.com').
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").


%% API
-export([start/2, stop/1, reload/3, mod_opt_type/1, mod_options/1, depends/2]).
-export([store_packet/6, store_packet/2, c2s_self_presence/1, process_iq/1, disco_features/5,
  remove_user/2, retract_message/3, retract_all_messages/3]).
-export([decode_iq_subel/1]).

-define(NS_HI_PRI, <<"https://xabber.com/protocol/priority">>).

-record(priority_messages,
{
  us = {<<"">>, <<"">>}             :: {binary(), binary()} | '_',
  peer = <<"">>                     :: binary() | '_',
  id = <<"">>                       :: binary() | '_',
  devices = []                      :: [binary()] | '_',
  expires = erlang:system_time(seconds) + 3600 :: non_neg_integer| '_'
}
).


start(Host, _Opts) ->
  ejabberd_mnesia:create(?MODULE, priority_messages,
    [{disc_copies, [node()]},
      {type, bag},
      {attributes,
        record_info(fields, priority_messages)}]),
  ejabberd_hooks:add(store_mam_message, Host, ?MODULE,
    store_packet, 50),
  ejabberd_hooks:add(c2s_self_presence, Host, ?MODULE, c2s_self_presence, 10),
  ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 50),
  ejabberd_hooks:add(retract_message, Host, ?MODULE, retract_message, 50),
  ejabberd_hooks:add(retract_all_messages, Host, ?MODULE, retract_all_messages, 50),
  ejabberd_hooks:add(disco_local_features, Host, ?MODULE, disco_features, 50),
  gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_HI_PRI,
    ?MODULE, process_iq),
  ok.

stop(Host) ->
  ejabberd_hooks:delete(store_mam_message, Host,
    ?MODULE, store_packet, 50),
  ejabberd_hooks:delete(c2s_self_presence, Host, ?MODULE, c2s_self_presence, 10),
  ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 50),
  ejabberd_hooks:delete(retract_message, Host, ?MODULE, retract_message, 50),
  ejabberd_hooks:delete(retract_all_messages, Host, ?MODULE, retract_all_messages, 50),
  ejabberd_hooks:delete(disco_local_features, Host, ?MODULE, disco_features, 50),
  gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_HI_PRI),
  ok.

reload(Host, NewOpts, OldOpts) ->
  NewMod = gen_mod:db_mod(Host, NewOpts, ?MODULE),
  OldMod = gen_mod:db_mod(Host, OldOpts, ?MODULE),
  if NewMod /= OldMod ->
    NewMod:init(Host, NewOpts);
    true ->
      ok
  end.

depends(_Host, _Opts) ->
  [].

mod_opt_type(default_ttl) ->
  fun (T) when is_integer(T), T > 0 -> T end;
mod_opt_type(max_ttl) ->
  fun (T) when is_integer(T), T > 0 -> T end;
mod_opt_type(max_messages) ->
  fun (T) when is_integer(T), T > 0 -> T end.

mod_options(_Host) ->
  [{default_ttl, 3600}, %% one hour
    {max_ttl, 3600 * 24 * 7},
    {max_messages, 20}].

-spec disco_features({error, stanza_error()} | {result, [binary()]} | empty,
    jid(), jid(), binary(), binary()) ->
  {error, stanza_error()} | {result, [binary()]}.
disco_features({error, Err}, _From, _To, _Node, _Lang) ->
  {error, Err};
disco_features(empty, _From, _To, <<"">>, _Lang) ->
  {result, [?NS_HI_PRI]};
disco_features({result, Feats}, _From, _To, <<"">>, _Lang) ->
  {result, [?NS_HI_PRI|Feats]};
disco_features(Acc, _From, _To, _Node, _Lang) ->
  Acc.

-spec remove_user(binary(), binary()) -> ok.
remove_user(User, Server) ->
  LUser = jid:nodeprep(User),
  LServer = jid:nameprep(Server),
  remove_all_messages({LUser, LServer}),
  ok.

retract_message(User, Server, SID) ->
  remove_message({User, Server}, SID),
  ok.

retract_all_messages(User, Server, Peer) ->
  remove_all_messages({User, Server}, jid:to_string(Peer)),
  ok.

c2s_self_presence({_, #{pres_last := _}} = Acc) ->
  %% This is just a presence update, nothing to do
  Acc;
c2s_self_presence({#presence{from = From, type = available}, State} = Acc) ->
  DevID = maps:get(device_id, State, <<>>),
  route_priority_messages(From, DevID),
  Acc;
c2s_self_presence(Acc) ->
  Acc.

-spec store_packet(message() | drop, binary(), binary(), jid(),
    chat | groupchat, recv | send) -> message().


store_packet(Pkt, LUser, LServer, _Peer, chat, recv) ->
  spawn(?MODULE, store_packet, [{LUser, LServer}, Pkt]),
  Pkt;
store_packet(Pkt, LUser, LServer, #jid{luser = LUser, lserver = LServer},
    chat, send) ->
  spawn(?MODULE, store_packet, [{LUser, LServer}, Pkt]),
  Pkt;
store_packet(Pkt, _LUser, _LServer, _Peer, _Type, _Dir) ->
  Pkt.

store_packet(US, Pkt) ->
  case is_priority_msg(Pkt) of
    {true, TTL} ->
      #message{from = From, meta = #{stanza_id := ID}} = Pkt,
      Peer = jid:remove_resource(From),
      store_packet_if_allowed(US, Peer, ID, TTL);
    _ ->
      ok
  end.

process_iq(#iq{from = #jid{luser = U1, lserver = S1},
  to = #jid{luser = U2, lserver = S2}} = Iq) when {U1, S1} /= {U2, S2}->
  xmpp:make_error(Iq, xmpp:err_not_allowed());
process_iq(#iq{type = set, from = From, sub_els = [Query]} = Iq) ->
  DevID = proplists:get_value(<<"device">>, Query#xmlel.attrs),
  {LUser, LServer, _} = jid:tolower(From),
  IDs = [SID#stanza_id.id || SID <- Query#xmlel.children],
  mark_messages(DevID, {LUser, LServer}, IDs),
  xmpp:make_iq_result(Iq);
process_iq(Iq) ->
  xmpp:make_error(Iq, xmpp:err_bad_request()).


%% Internal

store_packet_if_allowed({U,S}, #jid{luser = U, lserver = S} = Peer,
    ID, TTL) ->
  store_packet({U,S}, jid:to_string(Peer), ID, TTL);
store_packet_if_allowed({U,S}, #jid{luser = <<>>, lserver = S} = Peer,
    ID, TTL) ->
  store_packet({U,S}, jid:to_string(Peer), ID, TTL);
store_packet_if_allowed({U,S}, Peer, ID, TTL) ->
  case check_subscription(U, S, Peer) of
    true ->
      store_packet({U,S}, jid:to_string(Peer), ID, TTL);
    _ ->
      {error, not_allowed}
  end.

store_packet({U,S}, Peer, ID, undefined) ->
  TTL = gen_mod:get_module_opt(S, ?MODULE, default_ttl),
  store_packet({U,S}, Peer, ID, TTL);
store_packet(US, Peer, ID, TTL) when is_integer(ID) ->
  store_packet(US, Peer, integer_to_binary(ID), TTL);
store_packet({U,S}, Peer, ID, TTL) ->
  MAX_TTL = gen_mod:get_module_opt(S, ?MODULE, max_ttl),
  MAX_MSGS = gen_mod:get_module_opt(S, ?MODULE, max_messages),
  TTL1 = if
           TTL > MAX_TTL -> MAX_TTL;
           true -> TTL
         end,
  Expires = erlang:system_time(second) + TTL1,
  R = #priority_messages{us = {U,S}, peer = Peer,
      id = ID, expires = Expires},
  IsMyself = (jid:make(U,S) == jid:from_string(Peer)),
  FN = fun()->
    if
      IsMyself ->
        mnesia:write(R);
      true ->
        MatchHead = #priority_messages{us={U,S},
          peer='$1', _ = '_'},
        Guards = [{'==', '$1', Peer}],
        Count = length(mnesia:select(priority_messages,
          [{MatchHead, Guards, [1]}])),
        if
          Count < MAX_MSGS ->
            mnesia:write(R);
          true ->
            ok
        end
    end
       end,
  mnesia:transaction(FN).

route_priority_messages(UserJID, DevID) ->
  Messages = get_messages(UserJID,DevID),
  lists:foreach(fun(M) ->
    El = #xmlel{name = <<"priority-message">>,
      attrs = [{<<"xmlns">>, ?NS_HI_PRI}],
      children = [xmpp:encode(M)]},
    Msg = #message{from = jid:remove_resource(UserJID),
      to = UserJID, type = headline, sub_els = [El]},
    ejabberd_router:route(Msg)
                end, Messages),
  ok.

get_messages(JID, DevID) ->
  {U, S, _} = jid:tolower(JID),
  Now = erlang:system_time(seconds),
  Messages = mnesia:dirty_read(priority_messages, {U, S}),
  Expired = [M || M <- Messages, M#priority_messages.expires < Now],
  Messages1 = Messages -- Expired,
  NotReceived = [M || M <- Messages1,
    not lists:member(DevID, M#priority_messages.devices)] ,
  IDs = [ID || #priority_messages{id = ID} <- NotReceived],
  remove_messages(Expired),
  select_from_archive(S, JID, IDs).

select_from_archive(_Server, _JID, []) ->
  [];
select_from_archive(Server, JID, IDs) ->
  Mod = gen_mod:db_mod(Server, 'mod_mam'),
  {Messages, _, _}  =  Mod:select(Server, JID, JID,
    [{'ids',IDs}], undefined, chat),
  Messages1 = [ M || {_,_, M} <- Messages],
  Messages1.


remove_messages(Msgs) ->
  FN = fun()->
    lists:foreach(fun(O) ->
      mnesia:delete_object(O) end, Msgs)
       end,
  mnesia:transaction(FN).

remove_all_messages(US) ->
  mnesia:dirty_delete(priority_messages, US).


remove_message(US, SID) ->
  MatchHead = #priority_messages{us=US, peer='_', id='$1', _ = '_'},
  select_and_remove(MatchHead, SID).

remove_all_messages(US, Peer) ->
  MatchHead = #priority_messages{us=US, peer='$1', _ = '_'},
  select_and_remove(MatchHead, Peer).

select_and_remove(MatchHead, Pattern) ->
  FN = fun()->
    Guards = [{'==', '$1', Pattern}],
    Msgs = mnesia:select(priority_messages,[{MatchHead, Guards, ['$_']}]),
    lists:foreach(fun(O) ->
      mnesia:delete_object(O) end, Msgs)
       end,
  mnesia:transaction(FN).



mark_messages(undefined, _US, _IDs) ->
  ok;
mark_messages(DevId, US, IDs) ->
  FN = fun()->
    MatchHead = #priority_messages{us=US, peer='_', id='$1', _ = '_'},
    Guards = lists:map(fun(V) -> {'==', '$1', V} end, IDs),
    CombinedGuard = case Guards of
                      [] -> []; % No guards if list is empty
                      [H] -> H; % Single guard
                      _ -> lists:foldl(fun(G, Acc) ->
                        {'orelse', G, Acc} end, hd(Guards), tl(Guards))
                    end,
    Msgs = mnesia:select(priority_messages,[{MatchHead, [CombinedGuard], ['$_']}]),
    lists:foreach(
      fun(O) ->
        Devices = lists:usort([DevId|O#priority_messages.devices]),
        mnesia:delete_object(O),
        mnesia:write(O#priority_messages{devices = Devices})
      end, Msgs)
       end,
  mnesia:transaction(FN).

is_priority_msg(Pkt) ->
  Els = xmpp:get_els(Pkt),
  lists:foldl(
    fun(El, Acc) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"high-priority">> andalso NS == ?NS_HI_PRI) ->
        TTL = case proplists:get_value(<<"seconds">>,
          El#xmlel.attrs) of
                undefined -> undefined;
                B -> binary_to_integer(B)
              end,
        {true, TTL};
        true ->
          Acc
      end
    end, false, Els).

check_subscription(LUser, LServer, JID) ->
  {Sub, _, _} = ejabberd_hooks:run_fold(roster_get_jid_info, LServer,
    {none, none, []}, [LUser, LServer, JID]),
  case Sub of
    both -> true;
    from -> true;
    _ -> false
  end.

-spec decode_iq_subel(xmpp_element() | xmlel()) -> xmpp_element() | xmlel().
%% Tell gen_iq_handler not to auto-decode IQ payload
decode_iq_subel(El) ->
  Els = xmpp:get_els(El),
  SIDs = lists:filtermap(
    fun(ID) ->
      Name = xmpp:get_name(ID),
      NS = xmpp:get_ns(ID),
      if Name == <<"stanza-id">> andalso NS == ?NS_SID_0 ->
        SID = xmpp:decode(ID),
        {true, SID};
        true ->
          false
      end
    end, Els),
  El#xmlel{children = SIDs}.
