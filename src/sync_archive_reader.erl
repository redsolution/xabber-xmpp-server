%%%-------------------------------------------------------------------
%%% File    : sync_archive_reader.erl
%%% Purpose : Read-only archive lookups for sync metadata
%%%-------------------------------------------------------------------

-module(sync_archive_reader).

-compile([{parse_transform, ejabberd_sql_pt}]).

-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").

-export([counts/3, last_informative_messages/3, last_encrypted_messages/3]).

-define(CHAT_TYPE, <<"urn:xabber:chat">>).

counts(_LServer, _LUser, []) ->
  #{};
counts(LServer, LUser, Reqs) ->
  ODBCType = ejabberd_config:get_option({sql_type, LServer}),
  ToString = fun(S) -> ejabberd_sql:to_string_literal(ODBCType, S) end,
  SServer = ToString(LServer),
  SUser = ToString(LUser),
  Rows = lists:join(<<",">>,
    [count_row(ToString, Conversation, Read, ConvType)
      || {_Key, Conversation, Read, ConvType} <- Reqs]),
  ServerClause = case ejabberd_sql:use_new_schema() of
                   true -> [<<" and a.server_host=">>, SServer];
                   _ -> []
                 end,
  Query = [<<"select c.peer, c.conv_type, coalesce(a.unread_count, 0) "
  "from (values ">>, Rows, <<") as c(peer, read_ts, conv_type) "
  "left join lateral (select count(*) as unread_count "
  "from archive a where a.username=">>, SUser,
  <<" and a.bare_peer=c.peer "
  "and a.txt is not null and a.txt != '' "
  "and a.timestamp > c.read_ts "
  "and (not ARRAY['invite','voip'] && a.tags or a.tags is null) "
  "and a.conversation_type = c.conv_type">>, ServerClause,
  <<" group by a.username, a.bare_peer, a.conversation_type">>,
  <<") a on true;">>],
  case ejabberd_sql:sql_query(LServer, Query) of
    {selected, _, ResultRows} ->
      maps:from_list(
        [{{chat, Peer, ConvType}, sql_count_to_integer(Count)}
          || [Peer, ConvType, Count] <- ResultRows]);
    Error ->
      ?ERROR_MSG("sync_archive_reader count failed for ~s@~s: ~p",
        [LUser, LServer, Error]),
      #{}
  end.

last_informative_messages(_LServer, _LUser, []) ->
  #{};
last_informative_messages(LServer, LUser, Reqs) ->
  ODBCType = ejabberd_config:get_option({sql_type, LServer}),
  ToString = fun(S) -> ejabberd_sql:to_string_literal(ODBCType, S) end,
  SServer = ToString(LServer),
  SUser = ToString(LUser),
  ConvType = ToString(?CHAT_TYPE),
  Rows = lists:join(<<",">>,
    [last_informative_row(ToString, Conversation)
      || {_Key, Conversation} <- Reqs]),
  EmptyMap = maps:from_list([{Key, []} || {Key, _Conversation} <- Reqs]),
  ServerClause = case ejabberd_sql:use_new_schema() of
                   true -> [<<" and a.server_host=">>, SServer];
                   _ -> []
                 end,
  Query = [<<"select c.peer, a.timestamp, a.xml, a.peer, a.kind, a.nick "
  "from (values ">>, Rows, <<") as c(peer) "
  "join lateral (select timestamp, xml, peer, kind, nick "
  "from archive a where a.username=">>, SUser,
  <<" and a.bare_peer=c.peer "
  "and a.txt is not null and a.txt != '' "
  "and (not ARRAY['invite','voip'] && a.tags or a.tags is null) "
  "and a.conversation_type=">>, ConvType, ServerClause,
  <<" order by a.timestamp desc limit 1) a on true;">>],
  case ejabberd_sql:sql_query(LServer, Query) of
    {selected, _, ResultRows} ->
      LastMap =
        maps:from_list(
          [{{last, chat, Conversation, ?CHAT_TYPE},
            convert_message(sql_count_to_integer(TS), XML, Peer, Kind, Nick,
              LUser, LServer)}
            || [Conversation, TS, XML, Peer, Kind, Nick] <- ResultRows]),
      maps:merge(EmptyMap, LastMap);
    Error ->
      ?ERROR_MSG("sync_archive_reader last informative message failed "
      "for ~s@~s: ~p", [LUser, LServer, Error]),
      EmptyMap
  end.

last_encrypted_messages(_LServer, _LUser, []) ->
  #{};
last_encrypted_messages(LServer, LUser, Reqs) ->
  ODBCType = ejabberd_config:get_option({sql_type, LServer}),
  ToString = fun(S) -> ejabberd_sql:to_string_literal(ODBCType, S) end,
  SServer = ToString(LServer),
  SUser = ToString(LUser),
  Rows = lists:join(<<",">>,
    [last_encrypted_row(ToString, Conversation, ConvType)
      || {_Key, Conversation, ConvType} <- Reqs]),
  EmptyMap = maps:from_list([{Key, []} || {Key, _Conversation, _ConvType}
    <- Reqs]),
  ServerClause = case ejabberd_sql:use_new_schema() of
                   true -> [<<" and a.server_host=">>, SServer];
                   _ -> []
                 end,
  Query = [<<"select c.peer, c.conv_type, a.timestamp, a.xml, "
  "a.peer, a.kind, a.nick "
  "from (values ">>, Rows, <<") as c(peer, conv_type) "
  "join lateral (select timestamp, xml, peer, kind, nick "
  "from archive a where a.username=">>, SUser,
  <<" and a.bare_peer=c.peer "
  "and a.txt is not null and a.txt != '' "
  "and a.conversation_type=c.conv_type">>, ServerClause,
  <<" order by a.timestamp desc limit 1) a on true;">>],
  case ejabberd_sql:sql_query(LServer, Query) of
    {selected, _, ResultRows} ->
      maps:merge(EmptyMap,
        maps:from_list(
          [{{last, chat, Conversation, ConvType},
            convert_message(sql_count_to_integer(TS), XML, Peer, Kind, Nick,
              LUser, LServer)}
            || [Conversation, ConvType, TS, XML, Peer, Kind, Nick]
            <- ResultRows]));
    Error ->
      ?ERROR_MSG("sync_archive_reader last encrypted message failed "
      "for ~s@~s: ~p", [LUser, LServer, Error]),
      EmptyMap
  end.

count_row(ToString, Conversation, Read, ConvType) ->
  [<<"(">>, ToString(Conversation), <<", ">>, sql_integer_literal(Read),
    <<", ">>, ToString(ConvType), <<")">>].

last_informative_row(ToString, Conversation) ->
  [<<"(">>, ToString(Conversation), <<")">>].

last_encrypted_row(ToString, Conversation, ConvType) ->
  [<<"(">>, ToString(Conversation), <<", ">>, ToString(ConvType), <<")">>].

convert_message(TS, XML, Peer, Kind, Nick, LUser, LServer) ->
  case mod_mam_sql:make_archive_el(integer_to_binary(TS), XML, Peer,
    Kind, Nick, chat, jid:make(LUser,LServer), jid:make(LUser,LServer)) of
    {ok, ArchiveElement} ->
      #forwarded{sub_els = [Message]} = ArchiveElement,
      [#sync_last{sub_els = [Message]}];
    _ ->
      []
  end.

sql_integer_literal(I) when is_integer(I) ->
  integer_to_binary(I);
sql_integer_literal(B) when is_binary(B) ->
  try integer_to_binary(binary_to_integer(B)) of
    I -> I
  catch
    _:_ -> <<"0">>
  end;
sql_integer_literal(_) ->
  <<"0">>.

sql_count_to_integer(I) when is_integer(I) ->
  I;
sql_count_to_integer(B) when is_binary(B) ->
  binary_to_integer(B);
sql_count_to_integer(_) ->
  0.
