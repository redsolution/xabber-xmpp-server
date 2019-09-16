%%%-------------------------------------------------------------------
%%% File    : mod_previous.erl
%%% Author  : Alexander Ivanov <alexander.ivanov@redsolution.ru>
%%% Purpose : XEP-0YYY: Previous Message ID
%%% Created : 11 Apr 2018 by Alexander Ivanov <alexander.ivanov@redsolution.ru>
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

-module(mod_previous).
-author('alexander.ivanov@redsolution.ru').
-compile([{parse_transform, ejabberd_sql_pt}]).

-protocol({xep, '0YYY', '0.1.0'}).

-behaviour(gen_mod).

%% API
-export([
  start/2, stop/1, depends/2, mod_options/1,
  create_previous_id/1
]).

%% Hooks
-export([
    user_send_packet/1, filter_packet/1, disco_sm_features/5,
    get_archive_columns_and_from/1,
    get_previous_id/5, save_previous_id/4, unique_received/2,
    receive_message_stored/1
]).

-include("xmpp.hrl").
-include("logger.hrl").
-include("ejabberd_sql_pt.hrl").

-type c2s_state() :: ejabberd_c2s:state().

%%%===================================================================
%%% API
%%%===================================================================

start(Host, _Opts) ->
    ejabberd_hooks:add(user_send_packet,
        Host, ?MODULE, user_send_packet, 2),
    ejabberd_hooks:add(filter_packet,
        ?MODULE, filter_packet, 2),
    ejabberd_hooks:add(disco_sm_features,
        Host, ?MODULE, disco_sm_features, 50),
    ejabberd_hooks:add(get_previous_id,
        Host, ?MODULE, get_previous_id, 50),
    ejabberd_hooks:add(save_previous_id,
        Host, ?MODULE, save_previous_id, 50),
    ejabberd_hooks:add(unique_received,
        Host, ?MODULE, unique_received, 50),
    ejabberd_hooks:add(receive_message_stored,
        Host, ?MODULE, receive_message_stored, 50),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(user_send_packet,
        Host, ?MODULE, user_send_packet, 2),
    ejabberd_hooks:delete(filter_packet,
        ?MODULE, filter_packet, 2),
    ejabberd_hooks:delete(disco_sm_features,
        Host, ?MODULE, disco_sm_features, 50),
    ejabberd_hooks:delete(get_previous_id,
        Host, ?MODULE, get_previous_id, 50),
    ejabberd_hooks:delete(save_previous_id,
        Host, ?MODULE, save_previous_id, 50),
    ejabberd_hooks:delete(unique_received,
        Host, ?MODULE, unique_received, 50),
    ejabberd_hooks:delete(receive_message_stored,
        Host, ?MODULE, receive_message_stored, 50),
    ok.

depends(_Host, _Opts) ->
    [{mod_unique, hard}].

mod_options(_) -> [].

-spec create_previous_id(null | integer() | binary())
      -> previous_id().
create_previous_id(null) ->
    #previous_id{};
create_previous_id(PreviousId) when is_integer(PreviousId) ->
    create_previous_id(integer_to_binary(PreviousId));
create_previous_id(PreviousId) ->
    #previous_id{id = PreviousId}.

-spec user_send_packet({stanza(), c2s_state()})
      -> {stanza(), c2s_state()}.
user_send_packet({Pkt, C2SState}) ->
    {strip_previous_id(Pkt), C2SState};
user_send_packet(Acc) ->
    Acc.

-spec filter_packet(stanza()) -> stanza().
filter_packet(Pkt) ->
    strip_previous_id(Pkt).

-spec get_archive_columns_and_from({binary(), binary()}) ->
    {binary(), binary()}.
get_archive_columns_and_from({OriginColumns, OriginFrom}) ->
  case ejabberd_sql:use_new_schema() of
    true ->
      {[OriginColumns, <<", previous_id.id AS previous_id">>],
        [OriginFrom, <<" LEFT OUTER JOIN previous_id ON"
        " previous_id.stanza_id = archive.timestamp and previous_id.server_host = archive.server_host ">>]};
    _ ->
      {[OriginColumns, <<", previous_id.id AS previous_id">>],
        [OriginFrom, <<" LEFT OUTER JOIN previous_id ON"
        " previous_id.stanza_id = archive.timestamp">>]}
  end.

-spec get_previous_id(unknown, binary(), {binary(), binary()},
    chat | groupchat, jid()) -> error | null | binary().
get_previous_id(unknown, LServer, {LUser, LHost}, Type, Peer) ->
    {SUser, BarePeer} = mod_mam_sql:get_user_and_bare_peer(
            {LUser, LHost}, Type, Peer),
    case ejabberd_sql:sql_query(
	   LServer,
	   ?SQL("SELECT @(timestamp)d"
                " FROM archive"
                " WHERE username=%(SUser)s"
                " AND bare_peer=%(BarePeer)s AND %(LServer)H"
                " ORDER BY timestamp DESC"
                " LIMIT 1")) of
	{selected, []} ->
            null;
	{selected, [{StanzaId}]} ->
            StanzaId;
	_ ->
            error
    end.

-spec save_previous_id({ok, message()}, binary(),
    binary(), null | binary()) -> {ok, message()} | any().
save_previous_id({ok, OriginPkt}, _LServer, _StanzaId, null) ->
    Pkt = xmpp:put_meta(OriginPkt, previous_id, null),
    {ok, Pkt};
save_previous_id({ok, OriginPkt}, LServer, StanzaId, PreviousId) ->
    case ejabberd_sql:sql_query(
           LServer,
           ?SQL_INSERT(
              "previous_id",
              ["stanza_id=%(StanzaId)d",
                "server_host=%(LServer)s",
               "id=%(PreviousId)d"])) of
	{updated, _} ->
            Pkt = xmpp:put_meta(OriginPkt, previous_id, PreviousId),
	    {ok, Pkt};
	Err ->
	    Err
    end.

-spec receive_message_stored({ok, message()} | any())
        -> {ok, message()} | any().
receive_message_stored({ok, #message{meta = #{previous_id := PreviousId}} = Pkt}) ->
    Previous = create_previous_id(PreviousId),
    NewEls = [Previous | xmpp:get_els(Pkt)],
    {ok, xmpp:set_els(Pkt, NewEls)};
receive_message_stored(Acc) ->
    Acc.

-spec unique_received(message(), message()) -> message().
unique_received(UniqueReceived,
        #message{meta = #{previous_id := PreviousId}} = _OriginPkt) ->
    Previous = create_previous_id(PreviousId),
    UniqueReceived#unique_received{previous_id = Previous}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

strip_previous_id(Pkt) ->
    xmpp:remove_subtag(Pkt, #previous_id{}).

-spec disco_sm_features({error, stanza_error()} | {result, [binary()]} | empty,
		     jid(), jid(), binary(), binary()) ->
			    {error, stanza_error()} | {result, [binary()]}.
disco_sm_features({error, Err}, _From, _To, _Node, _Lang) ->
    {error, Err};
disco_sm_features(empty, _From, _To, <<"">>, _Lang) ->
    {result, [?NS_PREVIOUS]};
disco_sm_features({result, Feats}, _From, _To, <<"">>, _Lang) ->
    {result, [?NS_PREVIOUS|Feats]};
disco_sm_features(Acc, _From, _To, _Node, _Lang) ->
    Acc.
