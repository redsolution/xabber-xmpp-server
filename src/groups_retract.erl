%%%-------------------------------------------------------------------
%%% File    : groups_retract.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : Message retraction in Groups.
%%% Created : 22 Jan 2026 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%%
%%%
%%% xabberserver, Copyright (C) 2007-2026   redsolution corp
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

-module(groups_retract).
-author('ilya.kalashnikov@redsolution.com').
-compile([{parse_transform, ejabberd_sql_pt}]).
-behavior(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").

%% gen_mod
-export([start/2, stop/1, depends/2, mod_options/1]).

%% API
-export([rewrite_message/4, retract_message/4,
  retract_all_messages/3, retract_user_messages/4,
  send_rewrite_archive/5, get_version_reply/2]).

start(_Host, _Opts) ->
  ok.

stop(_Host) ->
  ok.

depends(_Host, _Opts) ->  [].

mod_options(_Opts) -> [].

%% get version

get_version_reply(Server, Group) ->
  Ver = get_version(Server, Group),
  #rewrite_query{version=Ver}.

%% rewrite message

rewrite_message(Server, Group, User, #replace{sid = #stanza_id{id = ID},
    replacement = #replacement_message{message = Message}}) ->
  try binary_to_integer(ID) of
    Timestamp when Timestamp >= 0 ->
      case check_permissions(rewrite, Server, User, Group, [ID]) of
        ok -> do_rewrite_message(Server, Group, User, ID, Timestamp, Message);
        Err -> Err
      end;
    _ -> {error, bad_request}
  catch error:badarg -> {error, bad_request}
  end.

do_rewrite_message(Server, Group, UserS, ID, Timestamp, Message) ->
  GroupJID = jid:from_string(Group),
  UserJID = jid:from_string(UserS),
  case sql_get_message(Server, GroupJID#jid.luser, Timestamp) of
    {ok, OldXML, Peer} ->
      OldMsg = xmpp:decode(fxml_stream:parse_element(OldXML)),
      SubEls = [El || El <- Message#message.sub_els, not rewrite_protected(El)],
      GrMsg = groups_messages:modify(Message#message{from = UserJID, to = GroupJID,
        sub_els = SubEls}),
      Origin = #origin_id{id = OldMsg#message.id},
      Replaced = #replaced{stamp = erlang:timestamp()},
      NewMsg = OldMsg#message{body = GrMsg#message.body, subject = GrMsg#message.subject,
        sub_els = [Origin | GrMsg#message.sub_els] ++ [Replaced]},
      MsgEl = xmpp:encode(NewMsg),
      XML = fxml:element_to_binary(MsgEl),
      Text = fxml:get_subtag_cdata(MsgEl, <<"body">>),
      Tags = mod_mam_sql:get_message_tags(MsgEl),
      SID = #stanza_id{by = GroupJID, id = ID},
      Archived = #mam_archived{by = GroupJID, id = ID},
      Time = #delivery_time{by = GroupJID, stamp = misc:usec_to_now(Timestamp)},
      FullMsg = NewMsg#message{sub_els = [Archived, SID, Time | NewMsg#message.sub_els]},
      Ver = get_new_version(Server, Group),
      Notify = #replace{conversation = GroupJID, sid = SID, version = Ver,
        replacement = #replacement_message{message = FullMsg}},
      EventXML = fxml:element_to_binary(xmpp:encode(Notify)),
      case sql_replace_group_message(Server, Group, Timestamp, OldXML,
          XML, Text, Tags, EventXML, Ver) of
        {atomic, ok} ->
          ejabberd_hooks:run(groups_archive_changed, Server,
            [Server, Group, {replace, Timestamp, Peer, NewMsg}]),
          send_notifications(Server, Group, Notify),
          ok;
        {atomic, not_found} -> {error, not_found};
        {aborted, Reason} ->
          ?ERROR_MSG("Failed to replace group message: ~p", [Reason]),
          {error, db_error}
      end;
    Err -> Err
  end.

rewrite_protected(El) ->
  Name = xmpp:get_name(El),
  NS = xmpp:get_ns(El),
  (NS =:= ?NS_SID_0 andalso Name =:= <<"origin-id">>) orelse
    (NS =:= ?NS_DELAY andalso Name =:= <<"delay">>) orelse
    (NS =:= ?NS_XABBER_REWRITE andalso Name =:= <<"replaced">>).

%% retract all messages

retract_all_messages(Server, Group, User) ->
  case check_permissions(retract_all, Server, User, Group, []) of
    ok ->
      Ver = get_new_version(Server, Group),
      Notify = #retract_archive{version = Ver},
      XML = fxml:element_to_binary(xmpp:encode(Notify)),
      case sql_retract_group_archive(Server, Group, XML, Ver) of
        {atomic, ok} ->
          ejabberd_hooks:run(groups_archive_changed, Server, [Server, Group, retract_archive]),
          delete_pinned_message(Server, Group, all),
          send_notifications(Server, Group, Notify),
          ok;
        {aborted, Reason} ->
          ?ERROR_MSG("Failed to retract group archive: ~p", [Reason]),
          {error, db_error}
      end;
    Err ->
      Err
  end.

%% retract user messages

retract_user_messages(Server, Group, User, UserID) ->
  case check_permissions(retract_user, Server, User,
    Group, [UserID]) of
    {ok, Peer} when is_binary(Peer) ->
      Ver = get_new_version(Server, Group),
      Notify = #retract_all{sender = UserID, type = ?NS_GROUPS,
        conversation = jid:from_string(Group), version = Ver},
      XML = fxml:element_to_binary(xmpp:encode(Notify)),
      delete_pinned_message(Server, Group, {user, Peer}),
      case sql_retract_user_messages(Server, Group, Peer, XML, Ver) of
        {atomic, ok} ->
          ejabberd_hooks:run(groups_archive_changed, Server, [Server, Group, {retract_sender, Peer}]),
          send_notifications(Server, Group, Notify),
          ok;
        {aborted, Reason} ->
          ?ERROR_MSG("Failed to retract group user messages: ~p", [Reason]),
          {error, db_error}
      end;
    {ok, _} -> {error, not_found};
    Err ->
      Err
  end.

%% retract message

retract_message(Server, Group, User, ID) ->
  try binary_to_integer(ID) of
    Timestamp when Timestamp >= 0 ->
      case sql_message_exists(Server, Group, Timestamp) of
        {ok, false} -> ok;
        {ok, true} -> retract_message(Server, Group, User, ID, Timestamp);
        {error, _} -> {error, db_error}
      end;
    _ -> {error, bad_request}
  catch
    error:badarg -> {error, bad_request}
  end.

retract_message(Server, Group, User, ID, Timestamp) ->
  case check_permissions(retract, Server, User, Group, [ID]) of
    ok ->
      GroupJID = jid:from_string(Group),
      Ver = get_new_version(Server, Group),
      Notify = #retract_message{conversation = GroupJID, version = Ver,
        sid = #stanza_id{by = GroupJID, id = ID}},
      XML = fxml:element_to_binary(xmpp:encode(Notify)),
      case sql_retract_message(Server, Group, Timestamp, XML, Ver) of
        {atomic, ok} ->
          ejabberd_hooks:run(groups_archive_changed, Server, [Server, Group, {retract, Timestamp}]),
          delete_pinned_message(Server, Group, ID),
          send_notifications(Server, Group, Notify),
          ok;
        {atomic, not_found} -> ok;
        {aborted, Reason} ->
          ?ERROR_MSG("Failed to retract group message: ~p", [Reason]),
          {error, db_error}
      end;
    Err ->
      Err
  end.

%% rewrite archive

send_rewrite_archive(Server, UserJID, Group, Ver, Max0) ->
  Max = case Max0 of undefined -> 50; N when N > 50 -> 50; N -> N end,
  case sql_history_summary(Server, Group, Ver) of
    {ok, CurrentVer, Count, ArchiveVer} ->
      Result = if
        ArchiveVer > 0 ->
          send_archive_event(Server, UserJID, Group, ArchiveVer);
        Count > Max ->
          send_invalidate(UserJID, Group, CurrentVer);
        true ->
          send_rewrite_events(Server, UserJID, Group, Ver, CurrentVer)
      end,
      case Result of ok -> {ok, CurrentVer}; {error, _} = Err -> Err end;
    {error, _} = Err -> Err
  end.

send_rewrite_events(Server, UserJID, Group, FromVer, ToVer) ->
  case sql_rewrite_archive(Server, Group, FromVer, ToVer) of
    {ok, Events} -> send_events(UserJID, Group, Events);
    {error, _} = Err -> Err
  end.

send_archive_event(Server, UserJID, Group, Version) ->
  case sql_get_archive_event(Server, Group, Version) of
    {ok, Event} -> send_events(UserJID, Group, [Event]);
    {error, _} = Err -> Err
  end.

send_events(UserJID, Group, Events) ->
  GroupJID = jid:from_string(Group),
  lists:foreach(fun({Version, XML}) ->
    Event = fxml_stream:parse_element(XML),
    Delay = #delay{stamp = misc:usec_to_now(Version)},
    M = #message{from = GroupJID, to = UserJID,
      type = headline, id = randoms:get_string(), sub_els = [Event, Delay]},
    ejabberd_router:route(M)
  end, Events),
  ok.

send_invalidate(UserJID, Group, Ver) ->
  Invalidate = #rewrite_invalidate{version = Ver,
    conversation = jid:from_string(Group),
    type = ?NS_GROUPS},
  M = #message{from = jid:from_string(Group), to = UserJID,
    type = headline, id= randoms:get_string(),
    sub_els = [Invalidate]},
  ejabberd_router:route(M),
  ok.

%% Internal functions

check_permissions(rewrite, Server, User, Group, [ID]) ->
  case get_message_author(Server, Group, ID) of
    User -> ok;
    _ ->
      {error, not_allowed}
  end;
check_permissions(retract, Server, User, Group, [ID]) ->
  case get_message_author(Server, Group, ID) of
    User -> ok;
    _ ->
      is_permitted(Server, User, Group)
  end;
check_permissions(retract_all, Server, User, Group, _) ->
  is_permitted(Server, User, Group);
check_permissions(retract_user, Server, User, Group, [UserID]) ->
  case groups_members:get_user_by_id(Server, Group, UserID) of
    User -> {ok, User};
    Val ->
      case is_permitted(Server, User, Group) of
        ok -> {ok, Val};
        Err -> Err
      end
  end;
check_permissions(user_exist, _, _, _, _) ->
  ok.

is_permitted(Server, User, Group) ->
  case groups_members:is_permitted(Server, Group, User,
    delete_messages, false, []) of
    true -> ok;
    _ -> {error, not_allowed}
  end.

send_notifications(Server, Group, Element) ->
  M = #message{type = headline, id = randoms:get_string(),
    sub_els = [Element]},
  notify(Server, Group, M).

notify(Server, Group, Stanza) ->
  FromBare = jid:from_string(Group),
  From = jid:replace_resource(FromBare,<<"Group">>),
  UserList = groups_members:users_to_send(Server, Group),
  lists:foreach(fun(To) ->
    ejabberd_router:route(From, To, Stanza) end, UserList).

get_message_author(Server, Group, ID) ->
  sql_message_author(Server, Group, ID).

delete_pinned_message(Server, Group, {user, User}) ->
  [Pinned]= groups_groups:get_info(Group, [messages]),
  IDs = [ID || #groups_pinned_message{id = ID}
    <- Pinned#groups_pinned.messages],
  MsgOwners = lists:map(fun(SID) ->
    {get_message_author(Server, Group, SID), SID}
                        end, IDs),
  lists:foreach(fun({Owner, SID}) ->
    case Owner of
      User ->
        groups_groups:change_pinned(Server, Group,
          #groups_pinned_message{id = SID, status = remove});
      _ -> ok
    end
  end, MsgOwners);
delete_pinned_message(Server, Group, all) ->
  groups_groups:delete_all_pinned(Server, Group);
delete_pinned_message(Server, Group, ID) ->
  [#groups_pinned{messages = Pinned}] =
    groups_groups:get_info(Group, [messages]),
  case lists:keyfind(ID, #groups_pinned_message.id, Pinned) of
    false -> ok;
    Msg ->
      groups_groups:change_pinned(Server, Group,
        Msg#groups_pinned_message{status = remove})
  end.

sql_retract_user_messages(Server, Group, Peer, XML, Version) ->
  GroupJID = jid:from_string(Group),
  User = GroupJID#jid.luser,
  BarePeer = jid:encode(jid:remove_resource(jid:decode(Peer))),
  ejabberd_sql:sql_transaction(Server, fun() ->
    ejabberd_sql:sql_query_t(?SQL(
      "delete from archive where username=%(User)s and %(Server)H "
      "and bare_peer=%(BarePeer)s")),
    sql_store_event(Group, XML, Version, <<"retract-all">>),
    ok
  end).

sql_message_exists(Server, Group, ID) ->
  GroupJID = jid:from_string(Group),
  User = GroupJID#jid.luser,
  case ejabberd_sql:sql_query(Server, ?SQL(
    "select @(timestamp)d from archive where username=%(User)s "
    "and timestamp=%(ID)d and %(Server)H")) of
    {selected, []} -> {ok, false};
    {selected, [_]} -> {ok, true};
    Error -> {error, Error}
  end.

sql_get_message(Server, User, ID) ->
  case ejabberd_sql:sql_query(Server, ?SQL(
    "select @(xml)s, @(bare_peer)s from archive where username=%(User)s "
    "and timestamp=%(ID)d and %(Server)H")) of
    {selected, [{XML, Peer}]} -> {ok, XML, Peer};
    {selected, []} -> {error, not_found};
    Error ->
      ?ERROR_MSG("Failed to read group message: ~p", [Error]),
      {error, db_error}
  end.

sql_replace_group_message(Server, Group, ID, OldXML, XML, Text, Tags, EventXML, Version) ->
  GroupJID = jid:from_string(Group),
  User = GroupJID#jid.luser,
  ejabberd_sql:sql_transaction(Server, fun() ->
    case ejabberd_sql:sql_query_t(?SQL(
      "update archive set xml=%(XML)s, txt=%(Text)s, tags=%(Tags)as "
      "where username=%(User)s and timestamp=%(ID)d and xml=%(OldXML)s "
      "and %(Server)H")) of
      {updated, 1} ->
        sql_store_event(Group, EventXML, Version, <<"replace">>),
        ok;
      {updated, 0} -> not_found
    end
  end).

sql_retract_message(Server, Group, ID, XML, Version) ->
  GroupJID = jid:from_string(Group),
  User = GroupJID#jid.luser,
  ejabberd_sql:sql_transaction(Server, fun() ->
    case ejabberd_sql:sql_query_t(?SQL(
      "delete from archive where username=%(User)s "
      "and timestamp=%(ID)d and %(Server)H")) of
      {updated, 1} ->
        sql_store_event(Group, XML, Version, <<"retract-message">>),
        ok;
      {updated, 0} -> not_found
    end
  end).

sql_retract_group_archive(Server, Group, XML, Version) ->
  GroupJID = jid:from_string(Group),
  User = GroupJID#jid.luser,
  ejabberd_sql:sql_transaction(Server, fun() ->
    ejabberd_sql:sql_query_t(?SQL(
      "delete from archive where username=%(User)s and %(Server)H")),
    sql_store_event(Group, XML, Version, <<"retract-archive">>),
    ok
  end).

sql_store_event(Group, XML, Version, EventType) ->
  ejabberd_sql:sql_query_t(?SQL_INSERT("groupchat_retract",
    ["chatgroup=%(Group)s", "xml=%(XML)s", "version=%(Version)d",
     "event_type=%(EventType)s"])) .

get_version(Server, Group) ->
  sql_get_version(Server, Group).

get_new_version(_Server, _Group) ->
  erlang:system_time(microsecond).

sql_message_author(Server, Group, ID) ->
  GroupJID = jid:from_string(Group),
  GUser = GroupJID#jid.luser,
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(bare_peer)s from archive where username=%(GUser)s "
    " and timestamp=%(ID)d and %(Server)H")) of
    {selected,[{User}]} -> User;
    _ -> error
  end.

sql_history_summary(Server, Group, Version) ->
  case ejabberd_sql:sql_query(Server, ?SQL(
    "select @(coalesce(max(version),0))d, "
    "@(count(case when missed = 1 then 1 end))d, "
    "@(coalesce(max(case when missed = 1 "
    "and event_type = 'retract-archive' then version end),0))d "
    "from (select version, event_type, "
    "case when version > %(Version)d then 1 else 0 end as missed "
    "from groupchat_retract where chatgroup=%(Group)s) events")) of
    {selected, [{CurrentVer, Count, ArchiveVer}]} ->
      {ok, CurrentVer, Count, ArchiveVer};
    Error -> {error, Error}
  end.

sql_rewrite_archive(Server, Group, Version, CurrentVer) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(version)d, @(xml)s from groupchat_retract where chatgroup=%(Group)s "
    "and version > %(Version)d and version <= %(CurrentVer)d order by version")) of
    {selected, Result} -> {ok, Result};
    Error -> {error, Error}
  end.

sql_get_archive_event(Server, Group, Version) ->
  case ejabberd_sql:sql_query(Server, ?SQL(
    "select @(version)d, @(xml)s from groupchat_retract "
    "where chatgroup=%(Group)s and version=%(Version)d "
    "and event_type='retract-archive'")) of
    {selected, [Event | _]} -> {ok, Event};
    Error -> {error, Error}
  end.

sql_get_version(Server, Group) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select coalesce(max(@(version)d),0) from groupchat_retract "
    " where chatgroup = %(Group)s")) of
    {selected,[{Version}]} -> Version;
    {selected,_} -> 0;
    Err ->
      ?ERROR_MSG("failed to get retract version: ~p", [Err]),
      0
  end.

