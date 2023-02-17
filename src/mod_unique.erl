%%%-------------------------------------------------------------------
%%% File    : mod_unique.erl
%%% Author  : Alexander Ivanov <alexander.ivanov@redsolution.ru>
%%% Purpose : XEP-0XXX: Unique Message ID
%%% Created : 29 Mar 2018 by Alexander Ivanov <alexander.ivanov@redsolution.ru>
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

-module(mod_unique).
-author('alexander.ivanov@redsolution.ru').
-compile([{parse_transform, ejabberd_sql_pt}]).

-protocol({xep, '0XXX', '0.1.0'}).

-behaviour(gen_mod).

%% API
-export([
  start/2, stop/1, depends/2, mod_options/1
]).
-export([
  remove_request/2, remove_request/3, get_message/3, get_stanza_id_by_origin_id/3
]).

%% Hooks
-export([
  sent_message_stored/5, user_send_packet/1, disco_sm_features/5
]).

-include("xmpp.hrl").
-include("logger.hrl").
-include("ejabberd_sql_pt.hrl").

-type c2s_state() :: ejabberd_c2s:state().

%%%===================================================================
%%% API
%%%===================================================================

start(Host, _Opts) ->
  ejabberd_hooks:add(disco_local_features, Host, ?MODULE,
    disco_sm_features, 50),
  ejabberd_hooks:add(disco_sm_features, Host, ?MODULE, disco_sm_features, 50),
    ejabberd_hooks:add(sent_message_stored,
        Host, ?MODULE, sent_message_stored, 50),
%%  ejabberd_hooks:add(receive_message_stored,
%%    Host, ?MODULE, receive_message_stored, 88),
    ejabberd_hooks:add(user_send_packet,
        Host, ?MODULE, user_send_packet, 1),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(sent_message_stored,
        Host, ?MODULE, sent_message_stored, 50),
%%  ejabberd_hooks:delete(receive_message_stored,
%%    Host, ?MODULE, receive_message_stored, 88),
    ejabberd_hooks:delete(user_send_packet,
        Host, ?MODULE, user_send_packet, 1),
  ejabberd_hooks:delete(disco_local_features, Host, ?MODULE,
    disco_sm_features, 50),
  ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE, disco_sm_features, 60),
    ok.

depends(_Host, _Opts) ->
    [{mod_mam, hard}].

mod_options(_) -> [].

%%-spec receive_message_stored({ok, message()} | any())
%%      -> {ok, message()} | any().
%%receive_message_stored({ok, #message{ meta = #{sm_copy := true}} = Pkt}) ->
%%  {ok,Pkt};
%%receive_message_stored({ok, #message{to = #jid{luser = LUser, lserver = LServer},meta = #{stanza_id := StanzaID}} = Pkt}) ->
%%  case xmpp:get_subtag(Pkt, #origin_id{}) of
%%    #origin_id{id = OriginID} ->
%%      store_origin_id(LServer, LUser, StanzaID, OriginID);
%%    _ ->
%%      ok
%%  end,
%%  {ok, Pkt};
%%receive_message_stored(Acc) ->
%%  Acc.

sent_message_stored({ok, Pkt}, _LServer, _JID, _StanzaID,
    #delivery_retry{to = To} = _Request) when To /= undefined ->
  {ok, Pkt};
sent_message_stored({ok, Pkt}, LServer, JID, StanzaID, _) ->
  send_received(Pkt, LServer, JID, StanzaID),
  {ok, Pkt};
sent_message_stored(Acc, _LServer, _JID, _StanzaID, _Request) ->
    Acc.

-spec user_send_packet({stanza(), c2s_state()})
      -> {stanza(), c2s_state()}.
user_send_packet({#message{} = Pkt, #{jid := JID} = C2SState} = Acc) ->
    case xmpp:get_subtag(Pkt, #delivery_retry{}) of
        #delivery_retry{to = undefined} ->
            case xmpp:get_subtag(Pkt, #origin_id{}) of
                #origin_id{id = OriginID} ->
                    LUser = JID#jid.luser,
                    LServer = JID#jid.lserver,
                    case get_message(LServer, LUser, OriginID) of
                        #message{} = Found ->
                            send_received(Found, JID, OriginID),
                            {stop, {drop, C2SState}};
                        _ ->
                            Acc
                    end;
                _ ->
                    Acc
            end;
        _ ->
          Acc
    end;
user_send_packet(Acc) ->
    Acc.

%%%===================================================================
%%% Internal functions
%%%===================================================================

send_received(Pkt, _LServer, JID, _StanzaID) ->
  case xmpp:get_subtag(Pkt, #origin_id{}) of
    #origin_id{id = OriginID} ->
      send_received(Pkt, JID, OriginID),
      ok;
    _ ->
      ok
  end.

send_received(
        #message{meta = #{stanza_id := ID, unique_time := TimeStamp}} = Pkt,
        #jid{lserver = LServer} = JID,
        OriginID) ->
    BareJID = jid:remove_resource(JID),
    UniqueReceived = #unique_received{
            origin_id = #origin_id{ id = OriginID },
            stanza_id = #stanza_id{ by = BareJID, id = integer_to_binary(ID) },
            time = #unique_time{ by = BareJID, stamp = misc:usec_to_now(TimeStamp) }},
    NewUniqueReceived = ejabberd_hooks:run_fold(
        unique_received, LServer, UniqueReceived, [Pkt]),
    Confirmation = #message{
        to = JID,
        type = headline,
        sub_els = [NewUniqueReceived]},
    ejabberd_router:route(jlib:make_jid(<<"">>, LServer, <<"">>), JID, Confirmation).

%%store_origin_id(LServer, LUser, StanzaID, OriginID) ->
%%    case ejabberd_sql:sql_query(
%%           LServer,
%%           ?SQL_INSERT(
%%              "origin_id",
%%              ["id=%(OriginID)s",
%%                "username=%(LUser)s",
%%                "server_host=%(LServer)s",
%%               "stanza_id=%(StanzaID)d"])) of
%%	{updated, _} ->
%%	    ok;
%%	Err ->
%%	    Err
%%    end.

get_stanza_id_by_origin_id(LServer,OriginID, LUser) ->
  OriginIDLike = <<"%<origin-id %",
    (ejabberd_sql:escape(ejabberd_sql:escape_like_arg_circumflex(OriginID)))/binary,
    "%/>%">>,
  TS = integer_to_binary(misc:now_to_usec(erlang:now()) - (24 * 3600000000)), %% last 24 hour
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select
    coalesce(min(@(timestamp)d),0)
    from archive
    where username=%(LUser)s and timestamp > %(TS)d
    and xml like %(OriginIDLike)s
    and %(LServer)H")) of
    {selected,[<<>>]} ->
      0;
    {selected,[{StanzaID}]} ->
      StanzaID;
    _ ->
      0
  end.

get_message(LServer, LUser, OriginID) ->
  case get_stanza_id_by_origin_id(LServer,OriginID, LUser) of
    0 ->
      error;
    StanzaID ->
      #message{meta = #{stanza_id => StanzaID, unique_time => StanzaID}}
  end.

remove_request(Pkt,false) -> Pkt;
remove_request(Pkt,_Request) ->
  remove_request(Pkt,_Request, all).

remove_request(Pkt,_Request, To) ->
  FN = fun(_, all) -> false;
    (V1, V2) ->  V1 /= V2 end,
  Els = xmpp:get_els(Pkt),
  NewEls = lists:filter(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if
        (Name == <<"retry">> andalso NS == ?NS_UNIQUE) ->
          try xmpp:decode(El) of
            #delivery_retry{to=V} ->
              FN(V, To)
          catch _:{xmpp_codec, _} ->
            false
          end;
        true ->
          true
      end
    end, Els),
  xmpp:set_els(Pkt, NewEls).

-spec disco_sm_features({error, stanza_error()} | {result, [binary()]} | empty,
		     jid(), jid(), binary(), binary()) ->
			    {error, stanza_error()} | {result, [binary()]}.
disco_sm_features({error, Err}, _From, _To, _Node, _Lang) ->
    {error, Err};
disco_sm_features(empty, _From, _To, <<"">>, _Lang) ->
    {result, [?NS_UNIQUE, ?NS_XABBER_ARCHIVE]};
disco_sm_features({result, Feats}, _From, _To, <<"">>, _Lang) ->
    {result, [?NS_UNIQUE, ?NS_XABBER_ARCHIVE |Feats]};
disco_sm_features(Acc, _From, _To, _Node, _Lang) ->
    Acc.
