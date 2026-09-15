%%%-------------------------------------------------------------------
%%% File    : sync_local_groups.erl
%%% Purpose : Local group sync counters and archive lookups
%%%-------------------------------------------------------------------

-module(sync_local_groups).

-compile([{parse_transform, ejabberd_sql_pt}]).

-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").

-export([statuses/3, counts/2, archive_last_messages/1, last_message_id/2]).

statuses(_LServer, _LUser, []) ->
  #{};
statuses(LServer, LUser, Chats) ->
  ODBCType = ejabberd_config:get_option({sql_type, LServer}),
  ToString = fun(S) -> ejabberd_sql:to_string_literal(ODBCType, S) end,
  SUser = ToString(jid:to_string(jid:make(LUser,LServer))),
  Rows = lists:join(<<",">>,
    [[<<"(">>, ToString(Chat), <<")">>] || Chat <- Chats]),
  EmptyMap = maps:from_list(
    [{{status, local_group, Chat}, not_exist} || Chat <- Chats]),
  Query = [<<"select c.chat, g.subscription "
  "from (values ">>, Rows, <<") as c(chat) "
  "left join groupchat_users g on g.chatgroup=c.chat "
  "and g.username=">>, SUser, <<";">>],
  case ejabberd_sql:sql_query(LServer, Query) of
    {selected, _, ResultRows} ->
      maps:merge(EmptyMap,
        maps:from_list(
          [{{status, local_group, Chat}, sql_subscription(Subscription)}
            || [Chat, Subscription] <- ResultRows]));
    Error ->
      ?ERROR_MSG("sync_local_groups status failed for ~s@~s: ~p",
        [LUser, LServer, Error]),
      EmptyMap
  end.

counts(_BareUser, []) ->
  #{};
counts(BareUser, Reqs) ->
  GroupedReqs = group_count_requests(Reqs),
  maps:fold(
    fun(GServer, ServerReqs, AccMap) ->
      maps:merge(AccMap, counts_for_server(GServer, BareUser, ServerReqs))
    end,
    #{},
    GroupedReqs).

archive_last_messages([]) ->
  #{};
archive_last_messages(Reqs) ->
  GroupedReqs = group_last_requests(Reqs),
  maps:fold(
    fun(GServer, ServerReqs, Acc) ->
      maps:merge(Acc, archive_last_messages(GServer, ServerReqs))
    end,
    #{},
    GroupedReqs).

last_message_id(GUser, GServer) ->
  case ejabberd_sql:sql_query(GServer,
    ?SQL("select @(timestamp)s from archive"
    " where username=%(GUser)s  and txt notnull and txt !='' and %(GServer)H "
    " order by timestamp desc limit 1")) of
    {selected,[{TS}]} -> TS;
    _ -> undefined
  end.

sql_subscription(null) ->
  not_exist;
sql_subscription(undefined) ->
  not_exist;
sql_subscription(Subscription) ->
  Subscription.

group_count_requests(Reqs) ->
  lists:foldl(
    fun({_Key, _Chat, _GUser, GServer, _Read} = Req, Acc) ->
      maps:update_with(GServer, fun(ServerReqs) -> [Req | ServerReqs] end,
        [Req], Acc)
    end,
    #{},
    Reqs).

counts_for_server(_GServer, _BareUser, []) ->
  #{};
counts_for_server(GServer, BareUser, Reqs) ->
  ODBCType = ejabberd_config:get_option({sql_type, GServer}),
  ToString = fun(S) -> ejabberd_sql:to_string_literal(ODBCType, S) end,
  SServer = ToString(GServer),
  SBareUser = ToString(BareUser),
  Rows = lists:join(<<",">>,
    [count_row(ToString, Chat, GUser, Read)
      || {_Key, Chat, GUser, _GServer, Read} <- Reqs]),
  ServerClause = case ejabberd_sql:use_new_schema() of
                   true -> [<<" and a.server_host=">>, SServer];
                   _ -> []
                 end,
  Query = [<<"select c.chat, coalesce(a.unread_count, 0) "
  "from (values ">>, Rows, <<") as c(chat, group_user, read_ts) "
  "left join lateral (select count(*) as unread_count "
  "from archive a where a.username=c.group_user "
  "and a.txt is not null and a.txt != '' "
  "and a.bare_peer!=">>, SBareUser,
  <<" and a.timestamp > c.read_ts">>, ServerClause,
  <<" group by a.username">>,
  <<") a on true;">>],
  case ejabberd_sql:sql_query(GServer, Query) of
    {selected, _, ResultRows} ->
      maps:from_list(
        [{{local_group, Chat}, sql_count_to_integer(Count)}
          || [Chat, Count] <- ResultRows]);
    Error ->
      ?ERROR_MSG("sync_local_groups count failed for ~s: ~p",
        [GServer, Error]),
      #{}
  end.

count_row(ToString, Chat, GUser, Read) ->
  [<<"(">>, ToString(Chat), <<", ">>, ToString(GUser), <<", ">>,
    sql_integer_literal(Read), <<")">>].

group_last_requests(Reqs) ->
  lists:foldl(
    fun({_Key, _Chat, _GUser, GServer, _Status} = Req, Acc) ->
      maps:update_with(GServer, fun(ServerReqs) -> [Req | ServerReqs] end,
        [Req], Acc)
    end,
    #{},
    Reqs).

archive_last_messages(_GServer, []) ->
  #{};
archive_last_messages(GServer, Reqs) ->
  ODBCType = ejabberd_config:get_option({sql_type, GServer}),
  ToString = fun(S) -> ejabberd_sql:to_string_literal(ODBCType, S) end,
  SServer = ToString(GServer),
  Rows = lists:join(<<",">>,
    [last_row(ToString, Chat, GUser)
      || {_Key, Chat, GUser, _GServer, _Status} <- Reqs]),
  EmptyMap = maps:from_list(
    [{Key, []} || {Key, _Chat, _GUser, _GServer, _Status} <- Reqs]),
  ServerClause = case ejabberd_sql:use_new_schema() of
                   true -> [<<" and a.server_host=">>, SServer];
                   _ -> []
                 end,
  Query = [<<"select c.chat, c.group_user, a.timestamp, a.xml, "
  "a.peer, a.kind, a.nick "
  "from (values ">>, Rows, <<") as c(chat, group_user) "
  "join lateral (select timestamp, xml, peer, kind, nick "
  "from archive a where a.username=c.group_user "
  "and a.txt is not null and a.txt != ''">>, ServerClause,
  <<" order by a.timestamp desc limit 1) a on true;">>],
  case ejabberd_sql:sql_query(GServer, Query) of
    {selected, _, ResultRows} ->
      maps:merge(EmptyMap,
        maps:from_list(
          [{{last, local_group, Chat},
            convert_message(sql_count_to_integer(TS), XML, Peer, Kind, Nick,
              GUser, GServer)}
            || [Chat, GUser, TS, XML, Peer, Kind, Nick] <- ResultRows]));
    Error ->
      ?ERROR_MSG("sync_local_groups last message failed for ~s: ~p",
        [GServer, Error]),
      EmptyMap
  end.

last_row(ToString, Chat, GUser) ->
  [<<"(">>, ToString(Chat), <<", ">>, ToString(GUser), <<")">>].

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
