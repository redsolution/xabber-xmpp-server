%%%-------------------------------------------------------------------
%%% File    : sync_external_groups.erl
%%% Purpose : External group sync cache, counters and deduplication
%%%-------------------------------------------------------------------

-module(sync_external_groups).

-compile([{parse_transform, ejabberd_sql_pt}]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").

-export([init_tables/0,
  store_message/5, change_last_message/2, delete_message/5,
  batch_counts/2, unread_count/5, last_message/5,
  last_message_id_ts/3, message_ts/4,
  cleanup_if_unused/3, delete_read_messages/1, migrate_message_meta/1]).

-record(external_group_last_msg,
{
  group = {<<"">>, <<"">>}             :: {binary(), binary()} | '_',
  id = <<>>                            :: binary() | '_',
  user_id = <<>>                       :: binary() | '_',
  packet = <<>>                        :: binary() | xmlel() | message() | '_',
  retract_version = <<>>               :: binary() | '_'
}
).

-record(external_group_dedup,
{
  group = {<<"">>, <<"">>}              :: {binary(), binary()} | '_',
  messages = []                         :: list() | '_',
  retracts = []                         :: list() | '_'
}).

-define(TABLE_SIZE_LIMIT, 2000000000). % A bit less than 2 GiB.
-define(DEDUP_LIMIT, 50).

init_tables() ->
  ejabberd_mnesia:create(?MODULE, external_group_last_msg,
    [{disc_only_copies, [node()]},
      {type, set},
      {attributes, record_info(fields, external_group_last_msg)}]),
  ejabberd_mnesia:create(?MODULE, external_group_dedup,
    [{ram_copies, [node()]},
      {type, set},
      {attributes, record_info(fields, external_group_dedup)}]).

store_message(LServer, {GUser, GServer} = Group, StanzaID, Packet, TS) ->
  TS1 = read_ts(TS),
  UserID = get_user_id(Packet),
  case remember_action(Group, messages, StanzaID) of
    duplicate ->
      ok;
    new ->
      LastMessage = #external_group_last_msg{
        group = Group,
        id = StanzaID,
        user_id = UserID,
        packet = Packet,
        retract_version = <<>>},
      store_last_msg(LastMessage, TS1),
      store_message_meta(LServer, GUser, GServer, StanzaID,
        author_id(UserID), TS1, false)
  end.

change_last_message(Group, Replace) ->
  ID = Replace#replace.id,
  Ver = integer_to_binary(Replace#replace.version),
  case remember_action(Group, retracts, {message, ID, Ver}) of
    duplicate ->
      ok;
    new ->
      case select_last_msg(Group) of
        #external_group_last_msg{retract_version = Ver, id = ID} ->
          ok;
        #external_group_last_msg{id = ID} = Record ->
          do_change_last_message(Replace, Record);
        _ ->
          ok
      end
  end.

delete_message(_LServer, _Group, <<>>, <<>>, _Version) ->
  ok;
delete_message(LServer, Group, StanzaID, UserID, Version) ->
  Action = retract_dedup_key(StanzaID, UserID, Version),
  case remember_action(Group, retracts, Action) of
    duplicate ->
      ok;
    new ->
      do_delete_message(LServer, Group, StanzaID, UserID)
  end.

batch_counts(_LServer, []) ->
  #{};
batch_counts(LServer, Reqs) ->
  ODBCType = ejabberd_config:get_option({sql_type, LServer}),
  ToString = fun(S) -> ejabberd_sql:to_string_literal(ODBCType, S) end,
  Rows = lists:join(<<",">>,
    [batch_count_row(ToString, Chat, GUser, GServer, ReadTS)
      || {_Key, Chat, GUser, GServer, ReadTS} <- Reqs]),
  Query = [<<"select c.chat, coalesce(m.unread_count, 0) "
  "from (values ">>, Rows,
  <<") as c(chat, group_user, group_server, read_ts) "
  "left join lateral (select count(*) as unread_count "
  "from external_group_message_meta m where m.group_user=c.group_user "
  "and m.group_server=c.group_server "
  "and m.timestamp > c.read_ts "
  "and not m.deleted) m on true;">>],
  case ejabberd_sql:sql_query(LServer, Query) of
    {selected, _, ResultRows} ->
      maps:from_list(
        [{{external_group, Chat}, sql_count_to_integer(Count)}
          || [Chat, Count] <- ResultRows]);
    Error ->
      ?ERROR_MSG("mod_sync external group count failed for ~s: ~p",
        [LServer, Error]),
      #{}
  end.

unread_count(LServer, GUser, GServer, ReadTS, both) ->
  Chat = jid:to_string(jid:make(GUser, GServer)),
  Key = {external_group, Chat},
  CountMap = batch_counts(
    LServer, [{Key, Chat, GUser, GServer, ReadTS}]),
  maps:get(Key, CountMap, 0);
unread_count(_, _, _, _, _) ->
  0.

last_message(LUser, LServer, GUser, GServer, both) ->
  case select_last_msg({GUser, GServer}) of
    #external_group_last_msg{packet = Msg} ->
      [#sync_last{sub_els = [xmpp:set_to(Msg, jid:make(LUser, LServer))]}];
    _ ->
      []
  end;
last_message(_, _, _, _, _) ->
  [].

last_message_id_ts(LServer, GUser, GServer) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(stanza_id)s, @(timestamp)d "
    "from external_group_message_meta "
    "where group_user=%(GUser)s and group_server=%(GServer)s "
    "and not deleted "
    "order by timestamp desc limit 1")) of
    {selected, [{ID, TS}]} -> {ID, TS};
    _ -> undefined
  end.

message_ts(LServer, GUser, GServer, StanzaID) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(timestamp)d from external_group_message_meta "
    "where group_user=%(GUser)s and group_server=%(GServer)s "
    "and stanza_id=%(StanzaID)s")) of
    {selected, [{TS}]} -> TS;
    _ -> time_now()
  end.

cleanup_if_unused(LServer, Conversation, Group) ->
  case has_local_participants(LServer, Conversation) of
    true ->
      ok;
    false ->
      delete_cache(LServer, Group)
  end.

delete_read_messages(_LServer) ->
  ok.

migrate_message_meta(Server) when is_list(Server) ->
  migrate_message_meta(iolist_to_binary(Server));
migrate_message_meta(LServer) when is_binary(LServer) ->
  case old_messages_table_exists() of
    false ->
      {ok, 0, 0};
    true ->
      case mnesia:wait_for_tables([external_group_msgs], 60000) of
        ok ->
          case catch mnesia:dirty_first(external_group_msgs) of
            {'EXIT', Reason} ->
              {error, Reason};
            Key ->
              migrate_message_meta(LServer, Key, 0, 0)
          end;
        Error ->
          Error
      end
  end.

batch_count_row(ToString, Chat, GUser, GServer, ReadTS) ->
  [<<"(">>, ToString(Chat), <<", ">>, ToString(GUser), <<", ">>,
    ToString(GServer), <<", ">>, sql_integer_literal(read_ts(ReadTS)), <<")">>].

store_message_meta(LServer, GUser, GServer, StanzaID, AuthorID, TS, Deleted) ->
  case do_store_message_meta(LServer, GUser, GServer, StanzaID,
    AuthorID, TS, Deleted) of
    ok ->
      ?DEBUG("Save external group message ~p~n",
        [{{GUser, GServer}, StanzaID}]),
      ok;
    Err ->
      ?DEBUG("Cannot save external group message ~p: ~p",
        [{{GUser, GServer}, StanzaID}, Err]),
      Err
  end.

do_store_message_meta(LServer, GUser, GServer, StanzaID, AuthorID, TS, Deleted) ->
  ?SQL_UPSERT(
    LServer,
    "external_group_message_meta",
    ["!group_user=%(GUser)s",
      "!group_server=%(GServer)s",
      "!stanza_id=%(StanzaID)s",
      "author_id=%(AuthorID)s",
      "timestamp=%(TS)d",
      "deleted=%(Deleted)b"]).

store_last_msg(Record1) ->
  store_last_msg(Record1, undefined).

store_last_msg(Record1, TS) ->
  #external_group_last_msg{packet = Pkt} = Record1,
  XML = fxml:element_to_binary(xmpp:encode(Pkt)),
  Record = Record1#external_group_last_msg{packet = XML},
  case {mnesia:table_info(external_group_last_msg, disc_only_copies),
    mnesia:table_info(external_group_last_msg, memory)} of
    {[_|_], TableSize} when TableSize > ?TABLE_SIZE_LIMIT ->
      ?ERROR_MSG("external_group_last_msg too large, won't store ~p", [Record]),
      {error, overflow};
    _ ->
      F = fun() -> maybe_write_last_msg(Record, TS) end,
      case mnesia:transaction(F) of
        {atomic, ok} ->
          ?DEBUG("Save last message ~p ~p",
            [Record#external_group_last_msg.group,
              Record#external_group_last_msg.id]),
          ok;
        {atomic, stale} ->
          ?DEBUG("Skip stale last message ~p ~p",
            [Record#external_group_last_msg.group,
              Record#external_group_last_msg.id]),
          ok;
        {aborted, Err} ->
          ?DEBUG("Cannot save last msg for ~p ~p: ~s",
            [Record#external_group_last_msg.group,
              Record#external_group_last_msg.id, Err]),
          Err
      end
  end.

maybe_write_last_msg(Record, TS) when is_integer(TS) ->
  Group = Record#external_group_last_msg.group,
  case mnesia:read(external_group_last_msg, Group, write) of
    [Current] ->
      case last_msg_ts(Current) of
        CurrentTS when is_integer(CurrentTS), TS < CurrentTS ->
          stale;
        _ ->
          mnesia:write(Record)
      end;
    [] ->
      mnesia:write(Record)
  end;
maybe_write_last_msg(Record, _TS) ->
  mnesia:write(Record).

last_msg_ts(#external_group_last_msg{
    group = {GUser, GServer},
    packet = Packet}) ->
  packet_delivery_ts(Packet, jid:make(GUser, GServer)).

packet_delivery_ts(Packet, BareJID) when is_binary(Packet) ->
  case fxml_stream:parse_element(Packet) of
    #xmlel{} = El ->
      try xmpp:decode(El, ?NS_CLIENT, []) of
        Decoded ->
          packet_delivery_ts(Decoded, BareJID)
      catch _:_ ->
        undefined
      end;
    _ ->
      undefined
  end;
packet_delivery_ts(Packet, BareJID) ->
  Filtered = filter_packet(Packet, BareJID),
  case xmpp:get_subtag(Filtered, #delivery_time{}) of
    #delivery_time{stamp = TS} ->
      stamp_to_usec(TS);
    _ ->
      undefined
  end.

stamp_to_usec(TS) ->
  try misc:now_to_usec(TS) of
    Usec when is_integer(Usec) ->
      Usec
  catch _:_ ->
    undefined
  end.

select_last_msg(Group) ->
  case mnesia:dirty_read(external_group_last_msg, Group) of
    [#external_group_last_msg{packet = XML} = Record] ->
      case fxml_stream:parse_element(XML) of
        #xmlel{} = El ->
          try xmpp:decode(El, ?NS_CLIENT, []) of
            Pkt ->
              Record#external_group_last_msg{packet = Pkt}
          catch _:{xmpp_codec, Why} ->
            ?ERROR_MSG("Failed to decode raw element ~p from "
            "external_group_last_msg of group ~p: ~s",
              [El, Group, xmpp:format_error(Why)]),
            {error, invalid_xml}
          end;
        {error, {_, Reason}} ->
          ?ERROR_MSG("Malformed 'xml' field with value '~s' detected "
          "for group ~p in table 'external_group_last_msg': ~s",
            [XML, Group, Reason]),
          {error, invalid_xml}
      end;
    _ ->
      {error, not_found}
  end.

do_change_last_message(Replace, LastMsg) ->
  Ver = integer_to_binary(Replace#replace.version),
  #replace{replace_message = XabberReplaceMessage} = Replace,
  #replace_message{body = Text, sub_els = NewEls} = XabberReplaceMessage,
  MD = xmpp:decode(LastMsg#external_group_last_msg.packet),
  Sub = MD#message.sub_els,
  Body = MD#message.body,
  OldText = xmpp:get_text(Body),
  Sub1 = lists:filter(fun(El) ->
    case xmpp:get_ns(El) of
      ?NS_REFERENCES -> false;
      ?NS_GROUPS -> false;
      _ -> true
    end end, Sub),
  Els1 = Sub1 ++ NewEls,
  NewBody = [#text{lang = <<>>, data = Text}],
  R = #replaced{stamp = erlang:timestamp(), body = OldText},
  Els2 = [R|Els1],
  NewMsg = MD#message{sub_els = Els2, body = NewBody},
  NewLastMsg = LastMsg#external_group_last_msg{
    packet = NewMsg,
    retract_version = Ver},
  store_last_msg(NewLastMsg).

retract_dedup_key(all, all, Version) ->
  {all, Version};
retract_dedup_key(StanzaID, <<>>, Version) when StanzaID /= <<>> ->
  {message, StanzaID, Version};
retract_dedup_key(<<>>, UserID, Version) when UserID /= <<>> ->
  {user, UserID, Version}.

do_delete_message(LServer, {GUser, GServer} = Group, all, all) ->
  mnesia:dirty_delete(external_group_last_msg, Group),
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from external_group_message_meta "
    "where group_user=%(GUser)s and group_server=%(GServer)s"));
do_delete_message(LServer, {GUser, GServer} = Group, ID, <<>>) when ID /= <<>> ->
  case is_last_message(Group, ID) of
    false -> ok;
    _ ->
      mnesia:dirty_delete(external_group_last_msg, Group)
  end,
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update external_group_message_meta set deleted=true "
    "where group_user=%(GUser)s and group_server=%(GServer)s "
    "and stanza_id=%(ID)s"));
do_delete_message(LServer, {GUser, GServer} = Group, <<>>, UserID)
    when UserID /= <<>> ->
  case mnesia:dirty_read(external_group_last_msg, Group) of
    [#external_group_last_msg{user_id = UserID}] ->
      mnesia:dirty_delete(external_group_last_msg, Group);
    _ -> ok
  end,
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from external_group_message_meta "
    "where group_user=%(GUser)s and group_server=%(GServer)s "
    "and author_id=%(UserID)s"));
do_delete_message(_, _, _, _) ->
  ok.

is_last_message(Group, ID) when is_integer(ID) ->
  is_last_message(Group, integer_to_binary(ID));
is_last_message(Group, ID) ->
  F = fun() ->
    mnesia:match_object(external_group_last_msg,
      {external_group_last_msg, Group, ID, '_', '_', '_'},
      read)
      end,
  case mnesia:transaction(F) of
    {atomic, [#external_group_last_msg{}]} ->
      true;
    _ ->
      false
  end.

migrate_message_meta(_LServer, '$end_of_table', Migrated, Skipped) ->
  {ok, Migrated, Skipped};
migrate_message_meta(LServer, Key, Migrated, Skipped) ->
  Rows = case catch mnesia:dirty_read(external_group_msgs, Key) of
           {'EXIT', _Reason} -> [];
           Result when is_list(Result) -> Result;
           _ -> []
         end,
  case migrate_message_meta_rows(LServer, Rows, Migrated, Skipped) of
    {Migrated1, Skipped1, undefined} ->
      case catch mnesia:dirty_next(external_group_msgs, Key) of
        {'EXIT', Reason} ->
          {error, Reason, Migrated1, Skipped1};
        NextKey ->
          migrate_message_meta(LServer, NextKey, Migrated1, Skipped1)
      end;
    {Migrated1, Skipped1, Error} ->
      {error, Error, Migrated1, Skipped1}
  end.

migrate_message_meta_rows(LServer, Rows, Migrated, Skipped) ->
  lists:foldl(
    fun(Row, {MigratedAcc, SkippedAcc, ErrorAcc}) ->
      case ErrorAcc of
        undefined ->
          case migrate_message_meta_row(LServer, Row) of
            ok -> {MigratedAcc + 1, SkippedAcc, undefined};
            skip -> {MigratedAcc, SkippedAcc + 1, undefined};
            Error -> {MigratedAcc, SkippedAcc + 1, Error}
          end;
        Error ->
          {MigratedAcc, SkippedAcc, Error}
      end
    end,
    {Migrated, Skipped, undefined},
    Rows).

migrate_message_meta_row(
    LServer,
    {external_group_msgs, {{GUser0, GServer0}, StanzaID0}, UserID0, TS0, Deleted0}) ->
  GUser = meta_text(GUser0),
  GServer = meta_text(GServer0),
  StanzaID = meta_text(StanzaID0),
  AuthorID = author_id(UserID0),
  TS = read_ts(TS0),
  Deleted = is_deleted(Deleted0),
  case GUser == <<>> orelse GServer == <<>> orelse StanzaID == <<>> of
    true ->
      skip;
    false ->
      do_store_message_meta(LServer, GUser, GServer, StanzaID,
        AuthorID, TS, Deleted)
  end;
migrate_message_meta_row(_, _) ->
  skip.

old_messages_table_exists() ->
  case catch mnesia:system_info(tables) of
    Tables when is_list(Tables) ->
      lists:member(external_group_msgs, Tables);
    _ ->
      false
  end.

has_local_participants(LServer, Conversation) ->
  Type = ?NS_GROUPS,
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @('true')b from conversation_metadata "
    "where conversation = %(Conversation)s and type = %(Type)s "
    "and status != 'deleted' limit 1")) of
    {selected, [_|_]} ->
      true;
    _ ->
      false
  end.

delete_cache(LServer, {GUser, GServer} = Group) ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from external_group_message_meta "
    "where group_user = %(GUser)s and group_server = %(GServer)s")),
  mnesia:dirty_delete(external_group_last_msg, Group),
  mnesia:dirty_delete(external_group_dedup, Group),
  ok.

remember_action(Group, Field, Key) ->
  F = fun() ->
    Record = case mnesia:read(external_group_dedup, Group, write) of
               [Stored] -> Stored;
               [] -> #external_group_dedup{group = Group}
             end,
    Keys = dedup_keys(Field, Record),
    case lists:member(Key, Keys) of
      true ->
        duplicate;
      false ->
        mnesia:write(update_dedup_keys(Field, Key, Record)),
        new
    end
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
      Result;
    {aborted, Reason} ->
      ?ERROR_MSG("external group dedup failed for ~p: ~p",
        [{Group, Field, Key}, Reason]),
      new
  end.

dedup_keys(messages, #external_group_dedup{messages = Keys}) ->
  Keys;
dedup_keys(retracts, #external_group_dedup{retracts = Keys}) ->
  Keys.

update_dedup_keys(messages, Key, Record) ->
  Keys = push_dedup_key(Key, Record#external_group_dedup.messages),
  Record#external_group_dedup{messages = Keys};
update_dedup_keys(retracts, Key, Record) ->
  Keys = push_dedup_key(Key, Record#external_group_dedup.retracts),
  Record#external_group_dedup{retracts = Keys}.

push_dedup_key(Key, Keys) ->
  lists:sublist([Key | Keys], ?DEDUP_LIMIT).

get_user_id(Pkt) ->
  case xmpp:get_subtag(Pkt, #groups_x{}) of
    #groups_x{author = #groups_user{id = ID}} ->
      ID;
    _ ->
      false
  end.

author_id(false) ->
  <<"">>;
author_id(UserID) ->
  meta_text(UserID).

is_deleted(true) ->
  true;
is_deleted(_) ->
  false.

read_ts(ReadTS) when is_integer(ReadTS) ->
  ReadTS;
read_ts(ReadTS) when is_binary(ReadTS) ->
  try binary_to_integer(ReadTS) of
    I -> I
  catch
    _:_ -> 0
  end;
read_ts(_) ->
  0.

meta_text(Value) when is_binary(Value) ->
  Value;
meta_text(Value) when is_integer(Value) ->
  integer_to_binary(Value);
meta_text(_) ->
  <<"">>.

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

filter_packet(Pkt, BareJID) ->
  Els = xmpp:get_els(Pkt),
  NewEls = lists:filtermap(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"stanza-id">> andalso NS == ?NS_SID_0);
      (Name == <<"time">> andalso NS == ?NS_UNIQUE) ->
        try xmpp:decode(El) of
          #stanza_id{by = By} ->
            By == BareJID;
          #delivery_time{by = By} ->
            By == BareJID
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          true
      end
    end, Els),
  xmpp:set_els(Pkt, NewEls).

time_now() ->
  erlang:system_time(microsecond).
