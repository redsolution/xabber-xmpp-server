%%%-------------------------------------------------------------------
%%% File    : mod_groups_retract.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Retract messages in group chats
%%% Created : 06 Nov 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_groups_retract).
-author('andrey.gagarin@redsolution.com').
-compile([{parse_transform, ejabberd_sql_pt}]).
-behavior(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").

-export([start/2, stop/1, depends/2, mod_options/1]).

%% API
-export([get_version/2]).
-export([rewrite_message/3, retract_message/3,
  retract_all_messages/2, retract_user_messages/3,
  send_rewrite_archive/5, get_version_reply/2]).

start(_Host, _Opts) ->
  ok.

stop(_Host) ->
  ok.

depends(_Host, _Opts) ->  [].

mod_options(_Opts) -> [].

%% get version

get_version_reply(UserJID, GroupJID) ->
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  User = jid:to_string(jid:remove_resource(UserJID)),
  Server = GroupJID#jid.lserver,
  case check_permissions(user_exist, Server, User, Group, []) of
    ok ->
      Ver = get_version(Server, Group),
      {ok, #xabber_retract_query{version=Ver}};
    Err ->
      Err
  end.

%% rewrite message

rewrite_message(UserJID, GroupJID, #xabber_replace{id = ID,
  xabber_replace_message = XRM}) ->
  User = jid:to_string(jid:remove_resource(UserJID)),
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  Server = GroupJID#jid.lserver,
  case check_permissions(rewrite, Server, User, Group, [ID]) of
    ok ->
      Ver = get_new_version(Server, Group),
      Notify1 = #xabber_replace{id = ID,
        xabber_replace_message = XRM,
        version = Ver,
        conversation = jid:remove_resource(GroupJID),
        type = ?NS_GROUPCHAT,
        xmlns = ?NS_XABBER_REWRITE_NOTIFY},
      Notify2 = rewrite_message(Server, Group, User, Notify1),
      store_event(Server, Group, Notify2, Ver),
      send_notifications(Server, Group, Notify2),
      ok;
    Err ->
      Err
  end.

rewrite_message(Server, Group, UserS, Replace) ->
  #xabber_replace{id = ID,
    xabber_replace_message = ReplaceMsg} = Replace,
  #xabber_replace_message{body = Text,
    sub_els = SubEls} = ReplaceMsg,
  NewEls = mod_retract:filter_new_els(SubEls),
  GroupJID = jid:from_string(Group),
  Mod = gen_mod:db_mod(Server, 'mod_mam'),
  OldMsg = case Mod:select(Server, GroupJID, GroupJID,[{'ids',[ID]}],
    undefined, chat) of
         {[{_, _, Forwarded}], true, 1} ->
           hd(Forwarded#forwarded.sub_els);
         Err ->
           %%  message not found in archive
           ?ERROR_MSG("The message is gone!!! group: ~p, id: ~p.\n ~p",
             [Group, ID, Err]),
           error
       end,
  ActualCard = mod_groups_users:form_user_card(UserS, Group),
  UserChoose = mod_groups_users:choose_name(ActualCard),
  Username = <<UserChoose/binary, ":", "\n">>,
  Length = misc:escaped_text_len(Username),
  NewX = #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT,
    sub_els = [#xmppreference{type = <<"mutable">>, sub_els = [ActualCard],
      'begin' = 0, 'end' = Length}]},
  NewElsShifted = mod_groups_messages:shift_references(NewEls, Length),
  Els2 = [#origin_id{id = OldMsg#message.id}] ++ [NewX] ++ NewElsShifted,
  NewText = <<Username/binary, Text/binary >>,
  NewBody = [#text{lang = <<>>,data = NewText}],
  Replaced = #replaced{stamp = erlang:timestamp()},
  NewMsg = OldMsg#message{sub_els = [Replaced|Els2], body = NewBody},
  XML = fxml:element_to_binary(xmpp:encode(NewMsg)),
  GUser = GroupJID#jid.luser,
  ?SQL_UPSERT(
    Server,
    "archive",
    ["!timestamp=%(ID)d",
      "!username=%(GUser)s",
      "!server_host=%(Server)s",
      "xml=%(XML)s",
      "txt=%(NewText)s"]),
  Time = #unique_time{by = GroupJID,
    stamp = misc:usec_to_now(binary_to_integer(ID))},
  NewReplaceMsg = ReplaceMsg#xabber_replace_message{
    replaced = Replaced,
    stanza_id = #stanza_id{id = ID, by = GroupJID},
    body = NewText, sub_els = Els2 ++ [Time]},
  Replace#xabber_replace{xabber_replace_message = NewReplaceMsg}.

%% retract all messages

retract_all_messages(UserJID, GroupJID) ->
  User = jid:to_string(jid:remove_resource(UserJID)),
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  Server = GroupJID#jid.lserver,
  case check_permissions(retract_all, Server, User, Group, []) of
    ok ->
      Ver = get_new_version(Server, Group),
      Notify = #xabber_retract_all{symmetric = true,
        conversation = jid:remove_resource(GroupJID),
        type = ?NS_GROUPCHAT, version = Ver,
        xmlns = ?NS_XABBER_REWRITE_NOTIFY},
      delete_messages_from_archive(Group),
      check_if_message_pinned(Server, Group, 0),
      store_event(Server, Group, Notify, Ver),
      send_notifications(Server, Group, Notify),
      ok;
    Err ->
      Err
  end.

%% retract user messages

retract_user_messages( UserJID, GroupJID, Retract) ->
  #xabber_retract_user{id = UserID} = Retract,
  User = jid:to_string(jid:remove_resource(UserJID)),
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  Server = GroupJID#jid.lserver,
  case check_permissions(retract_user, Server, User,
    Group, [UserID]) of
    {ok, Peer} ->
      Ver = get_new_version(Server, Group),
      Notify =  #xabber_retract_user{id = UserID,
        symmetric = true, type = ?NS_GROUPCHAT,
        conversation = jid:remove_resource(GroupJID),
        version = Ver,
        xmlns = ?NS_XABBER_REWRITE_NOTIFY},
      check_if_message_pinned(Server, Group, {user, Peer}),
      delete_user_messages_from_archive(Group, Peer),
      store_event(Server, Group, Notify, Ver),
      send_notifications(Server, Group, Notify),
      ok;
    Err ->
      Err
  end.

%% retract message

retract_message(UserJID, GroupJID, Retract) ->
  #xabber_retract_message{id = ID} = Retract,
  User = jid:to_string(jid:remove_resource(UserJID)),
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  Server = GroupJID#jid.lserver,
  case check_permissions(retract, Server, User, Group, [ID]) of
    ok ->
      Notify = #xabber_retract_message{id = ID,
        type = ?NS_GROUPCHAT, symmetric = true,
        conversation = jid:remove_resource(GroupJID),
        xmlns = ?NS_XABBER_REWRITE_NOTIFY},
      retract_message(Server, Group, ID, Notify);
    Err ->
      Err
  end.

retract_message(Server, Group, ID, Notify)->
  case delete_message_from_archive(Server, Group, ID) of
    ok ->
      Ver = get_new_version(Server, Group),
      Notify1 = Notify#xabber_retract_message{version = Ver},
      check_if_message_pinned(Server, Group, ID),
      store_event(Server, Group, Notify1, Ver),
      send_notifications(Server, Group, Notify1),
      ok;
    Err ->
      Err
  end.

%% rewrite archive

send_rewrite_archive(Server, UserJID, Group, Ver, Less) ->
  User = jid:to_string(jid:remove_resource(UserJID)),
  case check_permissions(user_exist, Server, User, Group, []) of
    ok ->
      {Less1, Ver1}= check_query_params(Less, Ver),
      Count = get_count_events(Server, Group, Ver1),
      CurrentVer = get_version(Server, Group),
      if
        Count > Less1 ->
          send_invalidate(UserJID, Group, CurrentVer);
        true ->
          send_rewrite_archive(Server, UserJID, Group, Ver1)
      end,
      {ok, CurrentVer};
    Err ->
      Err
  end.

send_rewrite_archive(Server, UserJID, Group, Ver)->
  QueryElements = get_query(Server, Group, Ver),
  GroupJID = jid:from_string(Group),
  lists:foreach(fun(El) ->
    try xmpp:decode(fxml_stream:parse_element(El)) of
      R ->
        M = #message{from = GroupJID, to = UserJID,
          type = headline, id= randoms:get_string(),
          sub_els = [R]},
        ejabberd_router:route(M)
    catch _:_ ->
      ?ERROR_MSG("Unable to decode xml from "
      "the rewrite archive: ~p",[El])
    end
                end, QueryElements),
  ok.

send_invalidate(UserJID, Group, Ver) ->
  Invalidate = #xabber_retract_invalidate{version = Ver,
    conversation = jid:from_string(Group),
    type = ?NS_GROUPCHAT},
  M = #message{from = jid:from_string(Group), to = UserJID,
    type = headline, id= randoms:get_string(),
    sub_els = [Invalidate]},
  ejabberd_router:route(M),
  ok.

%% Internal functions

check_permissions(Action, Server, User, Group, Args)->
  case mod_groups_users:check_if_exist(Server, Group, User) of
    true -> check_special_perms(Action, Server, User, Group, Args);
    _ -> {error, not_allowed}
  end.

check_special_perms(rewrite, Server, User, Group, [ID]) ->
  case get_owner_of_message(Server, Group, ID) of
    User -> ok;
    _ ->
      {error, not_allowed}
  end;
check_special_perms(retract, Server, User, Group, [ID]) ->
  case get_owner_of_message(Server, Group, ID) of
    User -> ok;
    _ ->
      is_permitted(User, Group)
  end;
check_special_perms(retract_all, _Server, User, Group, _) ->
  is_permitted(User, Group);
check_special_perms(retract_user, Server, User, Group, [UserID]) ->
  case mod_groups_users:get_user_by_id(Server, Group, UserID) of
    User -> {ok, User};
    Val ->
      case is_permitted(User, Group) of
        ok -> {ok, Val};
        Err -> Err
      end
  end;
check_special_perms(user_exist, _, _, _, _) ->
  ok.

is_permitted(User, Group) ->
  case mod_groups_restrictions:is_permitted(<<"delete-messages">>,
    User, Group) of
    true -> ok;
    _ -> {error, not_allowed}
  end.

store_event(Server, Group, Element, Ver) ->
  XML = fxml:element_to_binary(xmpp:encode(Element)),
  insert_event(Server, Group, XML, Ver).

send_notifications(Server, Group, Element) ->
  M = #message{type = headline, id = randoms:get_string(),
    sub_els = [Element]},
  notify(Server, Group, M).

notify(Server, Group, Stanza) ->
  FromBare = jid:from_string(Group),
  From = jid:replace_resource(FromBare,<<"Group">>),
  UserList = mod_groups_users:users_to_send(Server, Group),
  lists:foreach(fun(To) ->
    ejabberd_router:route(From, To, Stanza) end, UserList).

get_owner_of_message(Server, Group, ID) ->
  GroupJID = jid:from_string(Group),
  User = GroupJID#jid.luser,
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(bare_peer)s from archive where username=%(User)s "
    " and timestamp=%(ID)d and %(Server)H")) of
    {selected,[<<>>]} ->
      [];
    {selected,[{Query}]} ->
      Query;
    _ ->
      []
  end.

check_if_message_pinned(Server, Group, ID) ->
  case delete_pinned_message(Server, Group, ID) of
    ok ->
      groups_sm:update_group_session_info(Group,#{message => 0}),
      Presence = mod_groups_presence:form_presence(Group),
      notify(Server, Group, Presence);
    _ -> ok
  end.

delete_pinned_message(Server, Group, {user, User}) ->
  GroupJID = jid:from_string(Group),
  GUser = GroupJID#jid.luser,
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchats set message = 0 where jid=%(Group)s "
    " and message IN (select @(timestamp)s from archive"
    " where username=%(GUser)s and bare_peer=%(User)s "
    " and %(Server)H);")) of
    {updated, 1} -> ok;
    {updated, 0} -> {error, not_found};
    _ -> {error, db_error}
  end;
delete_pinned_message(Server, Group, 0) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchats set message = 0 "
    " where jid=%(Group)s")) of
    {updated, 1} -> ok;
    {updated, 0} -> {error, not_found};
    _ -> {error, db_error}
  end;
delete_pinned_message(Server, Group, ID) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchats set message = 0 "
    " where jid=%(Group)s and message=%(ID)d")) of
    {updated, 1} -> ok;
    {updated, 0} -> {error, not_found};
    _ -> {error, db_error}
  end.

-spec delete_user_messages_from_archive(binary(), binary()) ->
  {ok, binary()} | {error, binary()}.
delete_user_messages_from_archive(Group, BarePeer) ->
  GroupJID = jid:from_string(Group),
  mod_mam:remove_mam_for_user_with_peer(GroupJID#jid.luser,
    GroupJID#jid.lserver, BarePeer).

delete_message_from_archive(Server, Group, ID) ->
  GroupJID = jid:from_string(Group),
  User = GroupJID#jid.luser,
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from archive where username=%(User)s "
    " and timestamp=%(ID)d and %(Server)H")) of
    {updated, 1} -> ok;
    {updated, 0} -> {error, not_found};
    _ -> {error, db_error}
  end.

-spec delete_messages_from_archive(binary()) ->
  {ok, binary()} | {error, binary()}.
delete_messages_from_archive(Group) ->
  JID = jid:from_string(Group),
  mod_mam:remove_mam_for_user(JID#jid.luser, JID#jid.lserver).

check_query_params(Less, Ver) ->
  Less1 = if
            Less == undefined -> 50;
            Less == 0 -> 50;
            Less > 50 -> 50;
            true -> Less
          end,
  Ver1 = if
           Ver == undefined -> 0;
           true -> Ver
         end,
  {Less1, Ver1}.

get_count_events(Server, Group, Version) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(count(*))d from groupchat_retract"
    " where chatgroup=%(Group)s and version > %(Version)d")) of
    {selected, [{Count}]} ->
      Count
  end.

get_query(Server, Group, Version) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(xml)s from groupchat_retract where chatgroup=%(Group)s "
    " and version > %(Version)d order by version")) of
    {selected, Result} -> [I || {I} <- Result];
    _ -> []
  end.

get_version(Server, Group) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select coalesce(max(@(version)d),0) from groupchat_retract "
    " where chatgroup = %(Group)s")) of
    {selected,[{Version}]} ->
      Version;
    {selected,_} ->
      0;
    Err ->
      ?ERROR_MSG("failed to get retract version: ~p", [Err]),
      0
  end.

get_new_version(Server, Group) ->
  get_version(Server, Group) + 1.

insert_event(Server, Group, Txt, Version) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL_INSERT(
      "groupchat_retract",
      [ "chatgroup=%(Group)s",
        "xml=%(Txt)s",
        "version=%(Version)s"
      ])).
