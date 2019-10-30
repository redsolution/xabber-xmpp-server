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
  remove_request/2, get_message/3, store_origin_id/4, receive_message_stored/1
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
  ejabberd_hooks:add(receive_message_stored,
    Host, ?MODULE, receive_message_stored, 88),
    ejabberd_hooks:add(user_send_packet,
        Host, ?MODULE, user_send_packet, 1),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(sent_message_stored,
        Host, ?MODULE, sent_message_stored, 50),
  ejabberd_hooks:delete(receive_message_stored,
    Host, ?MODULE, receive_message_stored, 88),
    ejabberd_hooks:delete(user_send_packet,
        Host, ?MODULE, user_send_packet, 1),
  ejabberd_hooks:delete(disco_local_features, Host, ?MODULE,
    disco_sm_features, 50),
  ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE, disco_sm_features, 60),
    ok.

depends(_Host, _Opts) ->
    [{mod_mam, hard}].

mod_options(_) -> [].

-spec receive_message_stored({ok, message()} | any())
      -> {ok, message()} | any().
receive_message_stored({ok, #message{ meta = #{sm_copy := true, mam_archived := true}} = Pkt}) ->
  {ok,Pkt};
receive_message_stored({ok, #message{to = #jid{luser = LUser, lserver = LServer},meta = #{stanza_id := StanzaID}} = Pkt}) ->
  case xmpp:get_subtag(Pkt, #origin_id{}) of
    #origin_id{id = OriginID} ->
      store_origin_id(LServer, LUser, StanzaID, OriginID);
    _ ->
      ok
  end,
  {ok, Pkt};
receive_message_stored(Acc) ->
  Acc.

sent_message_stored({ok, Pkt}, LServer, JID, StanzaID, Request) ->
    case Request of
      #unique_request{to = To} ->
        case To of
          undefined ->
            check_origin_id(Pkt, LServer, JID, StanzaID);
          _ ->
            Pkt2 = add_request(Pkt,Request),
            {ok, Pkt2}
        end;
      _ ->
        {ok, Pkt}
    end;
sent_message_stored(Acc, _LServer, _JID, _StanzaID, _Request) ->
    Acc.

-spec user_send_packet({stanza(), c2s_state()})
      -> {stanza(), c2s_state()}.
user_send_packet({#message{} = Pkt, #{jid := JID} = C2SState} = Acc) ->
    case xmpp:get_subtag(Pkt, #unique_request{}) of
        #unique_request{retry = <<"true">>} ->
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
add_request(Pkt,Request) ->
  Els = xmpp:get_els(Pkt),
  NewEls = [Request|Els],
  xmpp:set_els(Pkt,NewEls).

check_origin_id(Pkt, LServer, JID, StanzaID) ->
  case xmpp:get_subtag(Pkt, #origin_id{}) of
    #origin_id{id = OriginID} ->
      LUser = JID#jid.luser,
      case store_origin_id(LServer, LUser, StanzaID, OriginID) of
        ok ->
          send_received(Pkt, JID, OriginID),
          {ok, Pkt};
        Err ->
          Err
      end;
    _ ->
      {ok, Pkt}
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

store_origin_id(LServer, LUser, StanzaID, OriginID) ->
    case ejabberd_sql:sql_query(
           LServer,
           ?SQL_INSERT(
              "origin_id",
              ["id=%(OriginID)s",
                "username=%(LUser)s",
                "server_host=%(LServer)s",
               "stanza_id=%(StanzaID)d"])) of
	{updated, _} ->
	    ok;
	Err ->
	    Err
    end.

-spec get_columns_and_from() ->
    {binary(), binary()}.
get_columns_and_from() ->
  case ejabberd_sql:use_new_schema() of
    true ->
      {<<" origin_id.stanza_id">>,
        <<" FROM origin_id"
        " INNER JOIN archive"
        " ON origin_id.stanza_id = archive.timestamp and origin_id.server_host = archive.server_host">>} ;
    false ->
      {<<" origin_id.stanza_id">>,
        <<" FROM origin_id"
        " INNER JOIN archive"
        " ON origin_id.stanza_id = archive.timestamp">>}
  end.

make_message([BinaryStanzaId, BinaryPreviousId]) ->
    StanzaId = binary_to_integer(BinaryStanzaId),
    PreviousId = case BinaryPreviousId of
                     null ->
                         null;
                     _ ->
                         binary_to_integer(BinaryPreviousId)
                 end,
    #message{
        meta = #{
            stanza_id => StanzaId,
            previous_id => PreviousId,
            unique_time => StanzaId}}.

get_message(LServer, LUser, OriginID) ->
    {_ODBCType, Escape} = mod_mam_sql:get_odbctype_and_escape(LServer),
    {Columns, From} = mod_previous:get_archive_columns_and_from(get_columns_and_from()),
    R =   case ejabberd_sql:use_new_schema() of
            true ->
              SServer = Escape(LServer),
              ejabberd_sql:sql_query(
                LServer,
                [<<"SELECT">>, Columns, From,
                  <<" WHERE origin_id.id = '">>, Escape(OriginID), <<"'">>,
                  <<" AND archive.username = '">>, Escape(LUser), <<"' and archive.server_host = '">>,SServer,<<"'">>]);
            false ->
              ejabberd_sql:sql_query(
                LServer,
                [<<"SELECT">>, Columns, From,
                  <<" WHERE origin_id.id = '">>, Escape(OriginID), <<"'">>,
                  <<" AND archive.username = '">>, Escape(LUser), <<"'">>])
          end,
    case R of
	{selected, _, [Row]} ->
            make_message(Row);
	_ ->
	    error
    end.

remove_request(Pkt,false) ->
  Pkt;
remove_request(Pkt,_Request) ->
  Els = xmpp:get_els(Pkt),
  NewEls = lists:filter(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if
        (Name == <<"request">> andalso NS == <<"http://xabber.com/protocol/delivery">>) ->
          try xmpp:decode(El) of
            #unique_request{} ->
              false
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
    {result, [?NS_UNIQUE]};
disco_sm_features({result, Feats}, _From, _To, <<"">>, _Lang) ->
    {result, [?NS_UNIQUE|Feats]};
disco_sm_features(Acc, _From, _To, _Node, _Lang) ->
    Acc.
