%%%----------------------------------------------------------------------
%%% File    : mod_push_mnesia.erl
%%% Author  : Holger Weiss <holger@zedat.fu-berlin.de>
%%% Purpose : Mnesia backend for Push Notifications (XEP-0357)
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

-module(mod_xabber_push_mnesia).
-author('holger@zedat.fu-berlin.de').

-behaviour(mod_xabber_push).

%% API
-export([init/2, store_session/6, lookup_session/4, lookup_session/3, store_session/9,
	 lookup_sessions/3, lookup_sessions/2, lookup_sessions/1, lookup_device_sessions/3,
	 delete_session/3, delete_old_sessions/2, transform/1]).

-include_lib("stdlib/include/ms_transform.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("mod_xabber_push.hrl").

%%%-------------------------------------------------------------------
%%% API
%%%-------------------------------------------------------------------
init(_Host, _Opts) ->
		update_table(),
    ejabberd_mnesia:create(?MODULE, xabber_push_session,
			   [{disc_only_copies, [node()]},
			    {type, bag},
			    {attributes, record_info(fields, xabber_push_session)}]).

store_session(LUser, LServer, TS, PushJID, Node, XData, EncryptionType, EncriptionKey, DeviceID) ->
	US = {LUser, LServer},
	PushLJID = jid:tolower(PushJID),
	MaxSessions = ejabberd_sm:get_max_user_sessions(LUser, LServer),
	F = fun() ->
		if is_integer(MaxSessions) ->
			enforce_max_sessions(US, MaxSessions - 1);
			MaxSessions == infinity ->
				ok
		end,
		mnesia:write(#xabber_push_session{us = US,
			timestamp = TS,
			service = PushLJID,
			node = Node,
			xml = encode_xdata(XData),
			encryption_key = base64:encode(EncriptionKey),
			encryption_type = EncryptionType,
			device_id = DeviceID
			})
			end,
	case mnesia:transaction(F) of
		{atomic, ok} ->
			{ok, {TS, PushLJID, Node, XData}};
		{aborted, E} ->
			?ERROR_MSG("Cannot store push session for ~s@~s: ~p",
				[LUser, LServer, E]),
			{error, db_failure}
	end.

store_session(LUser, LServer, TS, PushJID, Node, XData) ->
    US = {LUser, LServer},
    PushLJID = jid:tolower(PushJID),
    MaxSessions = ejabberd_sm:get_max_user_sessions(LUser, LServer),
    F = fun() ->
		if is_integer(MaxSessions) ->
			enforce_max_sessions(US, MaxSessions - 1);
		   MaxSessions == infinity ->
			ok
		end,
		mnesia:write(#xabber_push_session{us = US,
					   timestamp = TS,
					   service = PushLJID,
					   node = Node,
					   xml = encode_xdata(XData)})
	end,
    case mnesia:transaction(F) of
	{atomic, ok} ->
	    {ok, {TS, PushLJID, Node, XData}};
	{aborted, E} ->
	    ?ERROR_MSG("Cannot store push session for ~s@~s: ~p",
		       [LUser, LServer, E]),
	    {error, db_failure}
    end.

lookup_session(LUser, LServer, PushJID, Node) ->
    PushLJID = jid:tolower(PushJID),
    MatchSpec = ets:fun2ms(
		  fun(#xabber_push_session{us = {U, S}, service = P, node = N} = Rec)
			when U == LUser,
			     S == LServer,
			     P == PushLJID,
			     N == Node ->
			  Rec
		  end),
    case mnesia:dirty_select(xabber_push_session, MatchSpec) of
	[#xabber_push_session{timestamp = TS, xml = El, encryption_key = Key, encryption_type = EncriptionType}] ->
	    {ok, {TS, PushLJID, Node, decode_xdata(El), EncriptionType, Key}};
	[] ->
	    ?DEBUG("No push session found for ~s@~s (~p, ~s)",
		   [LUser, LServer, PushJID, Node]),
	    {error, notfound}
    end.

lookup_session(LUser, LServer, TS) ->
    MatchSpec = ets:fun2ms(
		  fun(#xabber_push_session{us = {U, S}, timestamp = T} = Rec)
			when U == LUser,
			     S == LServer,
			     T == TS ->
			  Rec
		  end),
    case mnesia:dirty_select(xabber_push_session, MatchSpec) of
	[#xabber_push_session{service = PushLJID, node = Node, xml = El, encryption_key = Key, encryption_type = EncriptionType}] ->
	    {ok, {TS, PushLJID, Node, decode_xdata(El), EncriptionType, Key}};
	[] ->
	    ?DEBUG("No push session found for ~s@~s (~p)",
		   [LUser, LServer, TS]),
	    {error, notfound}
    end.

lookup_sessions(LUser, LServer, PushJID) ->
    PushLJID = jid:tolower(PushJID),
    MatchSpec = ets:fun2ms(
		  fun(#xabber_push_session{us = {U, S}, service = P,
				    node = Node, timestamp = TS,
				    xml = El} = Rec)
			when U == LUser,
			     S == LServer,
			     P == PushLJID ->
			  Rec
		  end),
    Records = mnesia:dirty_select(xabber_push_session, MatchSpec),
    {ok, records_to_sessions(Records)}.

lookup_sessions(LUser, LServer) ->
    Records = mnesia:dirty_read(xabber_push_session, {LUser, LServer}),
    {ok, records_to_sessions(Records)}.

lookup_sessions(LServer) ->
    MatchSpec = ets:fun2ms(
		  fun(#xabber_push_session{us = {_U, S},
				    timestamp = TS,
				    service = PushLJID,
				    node = Node,
				    xml = El})
			when S == LServer ->
			  {TS, PushLJID, Node, El}
		  end),
    Records = mnesia:dirty_select(xabber_push_session, MatchSpec),
    {ok, records_to_sessions(Records)}.

lookup_device_sessions(LUser, LServer, Devices) ->
	Records1 = mnesia:dirty_read(xabber_push_session, {LUser, LServer}),
	Records2 = lists:filter(fun(R)-> lists:member(R#xabber_push_session.device_id, Devices) end, Records1),
	{ok, records_to_sessions(Records2)}.

delete_session(LUser, LServer, TS) ->
    MatchSpec = ets:fun2ms(
		  fun(#xabber_push_session{us = {U, S}, timestamp = T} = Rec)
			when U == LUser,
			     S == LServer,
			     T == TS ->
			  Rec
		  end),
    F = fun() ->
		Recs = mnesia:select(xabber_push_session, MatchSpec),
		lists:foreach(fun mnesia:delete_object/1, Recs)
	end,
    case mnesia:transaction(F) of
	{atomic, ok} ->
	    ok;
	{aborted, E} ->
	    ?ERROR_MSG("Cannot delete push session of ~s@~s: ~p",
		       [LUser, LServer, E]),
	    {error, db_failure}
    end.

delete_old_sessions(_LServer, Time) ->
    DelIfOld = fun(#xabber_push_session{timestamp = T} = Rec, ok) when T < Time ->
		       mnesia:delete_object(Rec);
		  (_Rec, ok) ->
		       ok
	       end,
    F = fun() ->
		mnesia:foldl(DelIfOld, ok, xabber_push_session)
	end,
    case mnesia:transaction(F) of
	{atomic, ok} ->
	    ok;
	{aborted, E} ->
	    ?ERROR_MSG("Cannot delete old push sessions: ~p", [E]),
	    {error, db_failure}
    end.

transform({xabber_push_session, US, TS, Service, Node, XData}) ->
    ?INFO_MSG("Transforming xabber_push_session Mnesia table", []),
    #xabber_push_session{us = US, timestamp = TS, service = Service,
		  node = Node, xml = encode_xdata(XData)}.

%%--------------------------------------------------------------------
%% Internal functions.
%%--------------------------------------------------------------------
-spec enforce_max_sessions({binary(), binary()}, non_neg_integer()) -> ok.
enforce_max_sessions({U, S} = US, Max) ->
    Recs = mnesia:wread({xabber_push_session, US}),
    NumRecs = length(Recs),
    if NumRecs > Max ->
	    NumOldRecs = NumRecs - Max,
	    Recs1 = lists:keysort(#xabber_push_session.timestamp, Recs),
	    Recs2 = lists:reverse(Recs1),
	    OldRecs = lists:sublist(Recs2, Max + 1, NumOldRecs),
	    ?INFO_MSG("Disabling ~B old push session(s) of ~s@~s",
		      [NumOldRecs, U, S]),
	    lists:foreach(fun(Rec) -> mnesia:delete_object(Rec) end, OldRecs);
       true ->
	    ok
    end.

decode_xdata(undefined) ->
    undefined;
decode_xdata(El) ->
    xmpp:decode(El).

encode_xdata(undefined) ->
    undefined;
encode_xdata(XData) ->
    xmpp:encode(XData).

records_to_sessions(Records) ->
    [{TS, PushLJID, Node, decode_xdata(El), EncriptionType, Key}
     || #xabber_push_session{timestamp = TS,
		      service = PushLJID,
		      node = Node,
		      xml = El,
			    encryption_type = EncriptionType,
			    encryption_key = Key} <- Records].

update_table() ->
	Transformer =
		fun(X)->
			#xabber_push_session{
				us = element(2,X),
				timestamp = element(3,X),
				service = element(4,X),
				node = element(5,X),
				encryption_type = element(6,X),
				encryption_key = element(7,X),
				xml = element(8,X),
				device_id = undefined}
		end,
	try
		mnesia:transform_table(xabber_push_session, Transformer, record_info(fields, xabber_push_session))
	catch exit:{aborted, {no_exists, _}} ->
		ok
	end.
