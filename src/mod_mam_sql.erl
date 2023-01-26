%%%-------------------------------------------------------------------
%%% File    : mod_mam_sql.erl
%%% Author  : Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% Created : 15 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2018   ProcessOne
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

-module(mod_mam_sql).

-compile([{parse_transform, ejabberd_sql_pt}]).

-behaviour(mod_mam).

%% API
-export([init/2, remove_user/2, remove_room/3, delete_old_messages/3,
	 get_columns_and_from/0, get_user_and_bare_peer/3, get_odbctype_and_escape/1, is_encrypted/2,
	 extended_fields/0, store/8, write_prefs/4, get_prefs/2, select/6, export/1,
   remove_from_archive/3, make_archive_el/8]).

-include_lib("stdlib/include/ms_transform.hrl").
-include("xmpp.hrl").
-include("mod_mam.hrl").
-include("logger.hrl").
-include("ejabberd_sql_pt.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(_Host, _Opts) ->
    ok.

remove_user(LUser, LServer) ->
    ejabberd_sql:sql_query(
      LServer,
      ?SQL("delete from archive where username=%(LUser)s and %(LServer)H")),
    ejabberd_sql:sql_query(
      LServer,
      ?SQL("delete from archive_prefs where username=%(LUser)s and %(LServer)H")).

remove_room(LServer, LName, LHost) ->
    LUser = jid:encode({LName, LHost, <<>>}),
    remove_user(LUser, LServer).

remove_from_archive(LUser, LServer, none) ->
    case ejabberd_sql:sql_query(LServer,
				?SQL("delete from archive where username=%(LUser)s and %(LServer)H")) of
	{error, Reason} -> {error, Reason};
	_ -> ok
    end;
remove_from_archive(LUser, LServer, WithJid) ->
    Peer = jid:encode(jid:remove_resource(WithJid)),
    case ejabberd_sql:sql_query(LServer,
				?SQL("delete from archive where username=%(LUser)s and %(LServer)H and bare_peer=%(Peer)s")) of
	{error, Reason} -> {error, Reason};
	_ -> ok
    end.

delete_old_messages(ServerHost, TimeStamp, Type) ->
    TS = misc:now_to_usec(TimeStamp),
    case Type of
        all ->
            ejabberd_sql:sql_query(
              ServerHost,
              ?SQL("delete from archive"
                   " where timestamp < %(TS)d and %(ServerHost)H"));
        _ ->
            SType = misc:atom_to_binary(Type),
            ejabberd_sql:sql_query(
              ServerHost,
              ?SQL("delete from archive"
                   " where timestamp < %(TS)d"
                   " and kind=%(SType)s"
                   " and %(ServerHost)H"))
    end,
    ok.

extended_fields() ->
    [{withtext, <<"">>},{'stanza-id',<<"">>},
      {last, false}].

-spec get_user_and_bare_peer({binary(), binary()},
    chat | groupchat, jid()) -> {binary(), binary()}.
get_user_and_bare_peer({LUser, LHost}, Type, Peer) ->
    SUser = case Type of
		chat -> LUser;
		groupchat -> jid:encode({LUser, LHost, <<>>})
	    end,
    BarePeer = jid:encode(
		 jid:tolower(
		   jid:remove_resource(Peer))),
    {SUser, BarePeer}.

store(Pkt, LServer, {LUser, LHost}, Type, Peer, Nick, _Dir, TS) ->
    {SUser, BarePeer} = get_user_and_bare_peer(
            {LUser, LHost}, Type, Peer),
    LPeer = jid:encode(
	      jid:tolower(Peer)),
    References = filter_all_except_references(Pkt),
    Is_image = search_in_references(References,<<"image">>),
  Is_audio = search_in_references(References,<<"audio">>),
  Is_video = search_in_references(References,<<"video">>),
  Is_document = search_in_references(References,<<"application">>),
  Is_voice = search_element_in_references(References,#voice_message{}),
  Is_geo = search_element_in_references(References,#geoloc{}),
  Is_sticker = search_element_in_references(References,#sticker{}),
  Is_encrypted = is_encrypted(Pkt),
  Tags = get_message_tags(Pkt),
    XML = fxml:element_to_binary(Pkt),
    Body = fxml:get_subtag_cdata(Pkt, <<"body">>),
    SType = misc:atom_to_binary(Type),
    case ejabberd_sql:sql_query(
           LServer,
           ?SQL_INSERT(
              "archive",
              ["username=%(SUser)s",
               "server_host=%(LServer)s",
               "timestamp=%(TS)d",
               "peer=%(LPeer)s",
               "bare_peer=%(BarePeer)s",
               "xml=%(XML)s",
               "txt=%(Body)s",
               "kind=%(SType)s",
               "image=%(Is_image)b",
               "video=%(Is_video)b",
               "audio=%(Is_audio)b",
               "document=%(Is_document)b",
                "geo=%(Is_geo)b",
                "sticker=%(Is_sticker)b",
                "voice=%(Is_voice)b",
                "encrypted=%(Is_encrypted)b",
                "tags=%(Tags)s",
               "nick=%(Nick)s"])) of
	{updated, _} ->
	    ok;
	Err ->
	    Err
    end.

is_encrypted(LServer,StanzaID) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(encrypted)b,@(xml)s
       from archive where timestamp=%(StanzaID)d")) of
    {selected,[{true, XML}]} ->
      {true, get_encrypted_type(fxml_stream:parse_element(XML))};
    _ ->
      false
  end.

is_encrypted(Pkt0) ->
  case get_encrypted_type(Pkt0) of
    <<>> -> false;
    _ -> true
  end.

get_encrypted_type({error, _}) ->
  <<>>;
get_encrypted_type(Pkt) ->
  Patterns = [<<"urn:xmpp:otr">>, <<"urn:xmpp:omemo">>],
  lists:foldl(fun(El, Acc0) ->
    NS0 = xmpp:get_ns(El),
    NS1 = lists:foldl(fun(P, Acc1) ->
      case binary:match(NS0,P) of
        nomatch -> Acc1;
        _ -> NS0
      end  end, <<>>, Patterns),
    if
      NS1 == <<>> -> Acc0;
      true -> NS1
    end
              end, <<>>, xmpp:get_els(Pkt)).

filter_all_except_references(Pkt) ->
  Els = xmpp:get_els(Pkt),
  NewEls = lists:filter(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"reference">> andalso NS == ?NS_REFERENCE_0) ->
        try xmpp:decode(El) of
          #xmppreference{} ->
            true
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          false
      end
    end, Els),
  DecodedEls = lists:map(fun(El) -> xmpp:decode(El) end, NewEls),
  DecodedEls.

search_in_references(References,SearchType) ->
  Array = lists:map(fun(Reference) ->
    File = xmpp:get_subtag(Reference, #xabber_file_sharing{}),
    case File of
      #xabber_file_sharing{file = #xabber_file{type = MediaType}} when MediaType =/= undefined ->
        Type = hd(binary:split(MediaType,<<"/">>,[global])),
        case Type of
          SearchType ->
            true;
          _ ->
            false
        end;
      _ ->
        false
    end
            end, References),
  lists:member(true,Array).

search_element_in_references(References,Element) ->
  lists:foldl(fun(Reference, Acc) ->
    case  xmpp:get_subtag(xmpp:decode(Reference), Element) of
      false -> Acc;
      _ -> true
    end end, false, References).

get_message_tags(Pkt) ->
  Message = xmpp:decode(Pkt),
  Invite = case xmpp:has_subtag(Message, #xabbergroupchat_invite{}) of
             true -> [<<"<invite>">>];
             _ -> []
           end,
  VoIP = lists:filtermap(fun(SubTag) ->
    case xmpp:has_subtag(Message,SubTag) of
      true -> {true, <<"<voip>">>};
      _ -> false
    end end,
    [#jingle_reject{}, #jingle_accept{}, #jingle_propose{}]),
  Tags = [],
  lists:join(<<$,>>, lists:usort(Tags ++ Invite ++ VoIP)).

write_prefs(LUser, _LServer, #archive_prefs{default = Default,
					   never = Never,
					   always = Always},
	    ServerHost) ->
    SDefault = erlang:atom_to_binary(Default, utf8),
    SAlways = misc:term_to_expr(Always),
    SNever = misc:term_to_expr(Never),
    case ?SQL_UPSERT(
            ServerHost,
            "archive_prefs",
            ["!username=%(LUser)s",
             "!server_host=%(ServerHost)s",
             "def=%(SDefault)s",
             "always=%(SAlways)s",
             "never=%(SNever)s"]) of
	ok ->
	    ok;
	Err ->
	    Err
    end.

get_prefs(LUser, LServer) ->
    case ejabberd_sql:sql_query(
	   LServer,
	   ?SQL("select @(def)s, @(always)s, @(never)s from archive_prefs"
                " where username=%(LUser)s and %(LServer)H")) of
	{selected, [{SDefault, SAlways, SNever}]} ->
	    Default = erlang:binary_to_existing_atom(SDefault, utf8),
	    Always = ejabberd_sql:decode_term(SAlways),
	    Never = ejabberd_sql:decode_term(SNever),
	    {ok, #archive_prefs{us = {LUser, LServer},
		    default = Default,
		    always = Always,
		    never = Never}};
	_ ->
	    error
    end.

select(LServer, JidRequestor, #jid{luser = LUser} = JidArchive,
       MAMQuery, RSM, MsgType) ->
    User = case MsgType of
	       chat -> LUser;
	       {groupchat, _Role, _MUCState} -> jid:encode(JidArchive)
	   end,
    {Query, CountQuery} = make_sql_query(User, LServer, MAMQuery, RSM),
    % TODO from XEP-0313 v0.2: "To conserve resources, a server MAY place a
    % reasonable limit on how many stanzas may be pushed to a client in one
    % request. If a query returns a number of stanzas greater than this limit
    % and the client did not specify a limit using RSM then the server should
    % return a policy-violation error to the client." We currently don't do this
    % for v0.2 requests, but we do limit #rsm_in.max for v0.3 and newer.
    case {ejabberd_sql:sql_query(LServer, Query),
	  ejabberd_sql:sql_query(LServer, CountQuery)} of
	{{selected, _, Res}, {selected, _, [[Count]]}} ->
	    {Max, Direction, _} = get_max_direction_id(RSM),
	    {Res1, IsComplete} =
		if Max >= 0 andalso Max /= undefined andalso length(Res) > Max ->
			if Direction == before ->
				{lists:nthtail(1, Res), false};
			   true ->
				{lists:sublist(Res, Max), false}
			end;
		   true ->
			{Res, true}
		end,
	    {lists:flatmap(
	       fun([TS, XML, PeerBin, Kind, Nick]) ->
		       case make_archive_el(TS, XML, PeerBin, Kind, Nick,
             MsgType, JidRequestor, JidArchive) of
			   {ok, El} ->
			       [{TS, binary_to_integer(TS), El}];
			   error ->
			       []
		       end
	       end, Res1), IsComplete, binary_to_integer(Count)};
	_ ->
	    {[], false, 0}
    end.

export(_Server) ->
    [{archive_prefs,
      fun(Host, #archive_prefs{us =
                {LUser, LServer},
                default = Default,
                always = Always,
                never = Never})
          when LServer == Host ->
                SDefault = erlang:atom_to_binary(Default, utf8),
                SAlways = misc:term_to_expr(Always),
                SNever = misc:term_to_expr(Never),
                [?SQL_INSERT(
                    "archive_prefs",
                    ["username=%(LUser)s",
                     "server_host=%(LServer)s",
                     "def=%(SDefault)s",
                     "always=%(SAlways)s",
                     "never=%(SNever)s"])];
          (_Host, _R) ->
              []
      end},
     {archive_msg,
      fun(Host, #archive_msg{us ={LUser, LServer},
                id = _ID, timestamp = TS, peer = Peer,
                type = Type, nick = Nick, packet = Pkt})
          when LServer == Host ->
                TStmp = misc:now_to_usec(TS),
                SUser = case Type of
                      chat -> LUser;
                      groupchat -> jid:encode({LUser, LServer, <<>>})
                    end,
                BarePeer = jid:encode(jid:tolower(jid:remove_resource(Peer))),
                LPeer = jid:encode(jid:tolower(Peer)),
                XML = fxml:element_to_binary(Pkt),
                Body = fxml:get_subtag_cdata(Pkt, <<"body">>),
                SType = misc:atom_to_binary(Type),
                [?SQL_INSERT(
                    "archive",
                    ["username=%(SUser)s",
                     "server_host=%(LServer)s",
                     "timestamp=%(TStmp)d",
                     "peer=%(LPeer)s",
                     "bare_peer=%(BarePeer)s",
                     "xml=%(XML)s",
                     "txt=%(Body)s",
                     "kind=%(SType)s",
                     "nick=%(Nick)s"])];
         (_Host, _R) ->
              []
      end}].

-spec get_columns_and_from() ->
    {binary(), binary()}.
get_columns_and_from() ->
    {<<" timestamp, xml, peer, kind, nick">>, <<" FROM archive">>}.

get_odbctype_and_escape(LServer) ->
    ODBCType = ejabberd_config:get_option({sql_type, LServer}),
    Escape =
        case ODBCType of
            mssql -> fun ejabberd_sql:standard_escape/1;
            sqlite -> fun ejabberd_sql:standard_escape/1;
            _ -> fun ejabberd_sql:escape/1
        end,
    {ODBCType, Escape}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
make_sql_query(User, LServer, MAMQuery, RSM) ->
		StanzaId = proplists:get_value('stanza-id', MAMQuery),
    Start = proplists:get_value(start, MAMQuery),
    End = proplists:get_value('end', MAMQuery),
    With = proplists:get_value(with, MAMQuery),
    WithText = proplists:get_value(withtext, MAMQuery),
    FilterAudio = proplists:get_value(filter_audio, MAMQuery),
    FilterVideo = proplists:get_value(filter_video, MAMQuery),
    FilterDocument = proplists:get_value(filter_document, MAMQuery),
    FilterEncrypted = proplists:get_value(filter_encrypted, MAMQuery),
    FilterVoice = proplists:get_value(filter_voice, MAMQuery),
    FilterSticker = proplists:get_value(filter_sticker, MAMQuery),
    FilterGeo = proplists:get_value(filter_geo, MAMQuery),
    FilterImage = proplists:get_value(filter_image, MAMQuery),
    FilterIDs = proplists:get_value(ids, MAMQuery),
    FilterAfterID = proplists:get_value('after-id', MAMQuery),
    FilterBeforeID = proplists:get_value('before-id', MAMQuery),
    {Max, Direction, ID} = get_max_direction_id(RSM),
    {ODBCType, Escape} = get_odbctype_and_escape(LServer),
    LimitClause = if is_integer(Max), Max >= 0, ODBCType /= mssql ->
			  [<<" limit ">>, integer_to_binary(Max+1)];
		     true ->
			  []
		  end,
    TopClause = if is_integer(Max), Max >= 0, ODBCType == mssql ->
			  [<<" TOP ">>, integer_to_binary(Max+1)];
		     true ->
			  []
		  end,
    WithTextClause = if is_binary(WithText), WithText /= <<>> ->
			     [<<" and  to_tsvector (txt) @@ plainto_tsquery ('">>,
			      Escape(WithText), <<"')">>];
			true ->
			     []
		     end,
    WithClause = case catch jid:tolower(With) of
		     {_, _, <<>>} ->
			 [<<" and bare_peer='">>,
			  Escape(jid:encode(With)),
			  <<"'">>];
		     {_, _, _} ->
			 [<<" and peer='">>,
			  Escape(jid:encode(With)),
			  <<"'">>];
		     _ ->
			 []
		 end,
    PageClause = case catch binary_to_integer(ID) of
		     I when is_integer(I), I >= 0 ->
			 case Direction of
			     before ->
				 [<<" AND timestamp < ">>, ID];
			     'after' ->
				 [<<" AND timestamp > ">>, ID];
			     _ ->
				 []
			 end;
		     _ ->
			 []
		 end,
    StartClause = case Start of
		      {_, _, _} ->
			  [<<" and timestamp >= ">>,
			   integer_to_binary(misc:now_to_usec(Start))];
		      _ ->
			  []
		  end,
    EndClause = case End of
		    {_, _, _} ->
			[<<" and timestamp <= ">>,
			 integer_to_binary(misc:now_to_usec(End))];
		    _ ->
			[]
		end,
    IDsClause = case FilterIDs of
                  undefined -> [];
                  [] -> [];
                  _ ->
                    [<<" and timestamp in (">>] ++ lists:join(<<$,>>,FilterIDs) ++ [<<$)>>]
                end,
    BeforeIDClause = case FilterBeforeID of
                       undefined -> [];
                       <<>> -> [];
                       _ -> [<<" and timestamp < ">>,FilterBeforeID]
                     end,
    AfterIDClause = case FilterAfterID of
                       undefined -> [];
                       <<>> -> [];
                       _ -> [<<" and timestamp > ">>,FilterAfterID]
                     end,
		StanzaIdClause = case StanzaId of
											 <<>> ->
												 [];
											 undefined ->
												 [];
											 _ ->
												 [<<" and timestamp = ">>,
													 StanzaId]
										 end,
    ImageClause = case FilterImage of
                    false ->
                      [<<"and image = false ">>];
                    true ->
                      [<<"and image = true ">>];
                    _ ->
                      []
                  end,
    AudioClause = case FilterAudio of
                    false ->
                      [<<"and audio = false ">>];
                    true ->
                      [<<"and audio = true ">>];
                    _ ->
                      []
                  end,
    VideoClause = case FilterVideo of
               false ->
                 [<<"and video = false ">>];
               true ->
                 [<<"and video = true ">>];
               _ ->
                 []
             end,
    GeoClause = case FilterGeo of
               false ->
                 [<<"and geo = false ">>];
               true ->
                 [<<"and geo = true ">>];
               _ ->
                 []
             end,
    EncryptedClause = case FilterEncrypted of
               false ->
                 [<<"and encrypted = false ">>];
               true ->
                 [<<"and encrypted = true ">>];
               _ ->
                 []
             end,
    VoiceClause = case FilterVoice of
               false ->
                 [<<"and voice = false ">>];
               true ->
                 [<<"and voice = true ">>];
               _ ->
                 []
             end,
    StickerClause = case FilterSticker of
               false ->
                 [<<"and sticker = false ">>];
               true ->
                 [<<"and sticker = true ">>];
               _ ->
                 []
             end,
    DocumentClause = case FilterDocument of
               false ->
                 [<<"and document = false ">>];
               true ->
                 [<<"and document = true ">>];
               _ ->
                 []
             end,
    SUser = Escape(User),
    SServer = Escape(LServer),
    Query =
        case ejabberd_sql:use_new_schema() of
            true ->
                [<<"SELECT ">>, TopClause,
                 <<" timestamp, xml, peer, kind, nick"
                 " FROM archive WHERE username='">>,
                 SUser, <<"' and server_host='">>,
                 SServer, <<"'">>, WithClause, WithTextClause,
                  StartClause, EndClause, PageClause, StanzaIdClause,
                  IDsClause, AfterIDClause, BeforeIDClause,
                  ImageClause, AudioClause, VideoClause, VoiceClause,
                  DocumentClause, StickerClause, GeoClause, EncryptedClause];
            false ->
                [<<"SELECT ">>, TopClause,
                  <<" timestamp, xml, peer, kind, nick"
                  " FROM archive WHERE username='">>,
                 SUser, <<"'">>, WithClause, WithTextClause,
                  StartClause, EndClause, PageClause, StanzaIdClause,
                  IDsClause, AfterIDClause, BeforeIDClause,
                  ImageClause, AudioClause, VideoClause, VoiceClause,
                  DocumentClause, StickerClause, GeoClause, EncryptedClause]
        end,

    QueryPage =
      case Direction of
        before ->
          % ID can be empty because of
          % XEP-0059: Result Set Management
          % 2.5 Requesting the Last Page in a Result Set
          [<<"SELECT timestamp, xml, peer, kind, nick FROM (">>, Query,
            <<" ORDER BY timestamp DESC NULLS LAST">>,
            LimitClause, <<") AS t ORDER BY timestamp ASC;">>];
        _ ->
          [Query, <<" ORDER BY timestamp ASC ">>,
            LimitClause, <<";">>]
      end,
    case ejabberd_sql:use_new_schema() of
        true ->
            {QueryPage,
             [<<"SELECT COUNT(*) FROM archive WHERE username='">>,
              SUser, <<"' and server_host='">>,
              SServer, <<"'">>, WithClause, WithTextClause,
               StartClause, EndClause, StanzaIdClause,
               IDsClause, AfterIDClause, BeforeIDClause,
               ImageClause,AudioClause, VideoClause, VoiceClause,
               DocumentClause, StickerClause, GeoClause, EncryptedClause, <<";">>]};
        false ->
            {QueryPage,
             [<<"SELECT COUNT(*) FROM archive WHERE username='">>,
              SUser, <<"'">>, WithClause, WithTextClause,
              StartClause, EndClause, StanzaIdClause,
               IDsClause, AfterIDClause, BeforeIDClause,
               ImageClause, AudioClause, VideoClause, VoiceClause,
               DocumentClause,StickerClause, GeoClause, EncryptedClause, <<";">>]}
    end.

-spec get_max_direction_id(rsm_set() | undefined) ->
				  {integer() | undefined,
				   before | 'after' | undefined,
				   binary()}.
get_max_direction_id(RSM) ->
    case RSM of
	#rsm_set{max = Max, before = Before} when is_binary(Before) ->
	    {Max, before, Before};
	#rsm_set{max = Max, 'after' = After} when is_binary(After) ->
	    {Max, 'after', After};
	#rsm_set{max = Max} ->
	    {Max, undefined, <<>>};
	_ ->
	    {undefined, undefined, <<>>}
    end.

-spec make_archive_el(binary(), binary(), binary(), binary(),
		      binary(), _, jid(), jid()) ->
			     {ok, xmpp_element()} | {error, invalid_jid |
						     invalid_timestamp |
						     invalid_xml}.
make_archive_el(TS, XML, Peer, Kind, Nick, MsgType, JidRequestor, JidArchive) ->
    case fxml_stream:parse_element(XML) of
	#xmlel{} = El ->
	    try binary_to_integer(TS) of
		TSInt ->
		    try jid:decode(Peer) of
			PeerJID ->
			    Now = misc:usec_to_now(TSInt),
			    PeerLJID = jid:tolower(PeerJID),
			    T = case Kind of
				    <<"">> -> chat;
				    null -> chat;
				    _ -> misc:binary_to_atom(Kind)
				end,
			    mod_mam:msg_to_el(
			      #archive_msg{timestamp = Now,
					   id = TS,
					   packet = El,
					   type = T,
					   nick = Nick,
					   peer = PeerLJID},
			      MsgType, JidRequestor, JidArchive)
		    catch _:{bad_jid, _} ->
			    ?ERROR_MSG("Malformed 'peer' field with value "
				       "'~s' detected for user ~s in table "
				       "'archive': invalid JID",
				       [Peer, jid:encode(JidArchive)]),
			    {error, invalid_jid}
		    end
	    catch _:_ ->
		    ?ERROR_MSG("Malformed 'timestamp' field with value '~s' "
			       "detected for user ~s in table 'archive': "
			       "not an integer",
			       [TS, jid:encode(JidArchive)]),
		    {error, invalid_timestamp}
	    end;
	{error, {_, Reason}} ->
	    ?ERROR_MSG("Malformed 'xml' field with value '~s' detected "
		       "for user ~s in table 'archive': ~s",
		       [XML, jid:encode(JidArchive), Reason]),
	    {error, invalid_xml}
    end.
