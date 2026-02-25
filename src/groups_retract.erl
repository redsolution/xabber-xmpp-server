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
-export([get_version/2]).
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
  #retract_query{version=Ver}.

%% rewrite message

rewrite_message(Server, Group, User, #replace{id = ID,
  replace_message = XRM}) ->
  case check_permissions(rewrite, Server, User, Group, [ID]) of
    ok ->
      Ver = get_new_version(Server, Group),
      Notify1 = #replace{id = ID,
        replace_message = XRM,
        version = Ver,
        conversation = jid:from_string(Group),
        type = ?NS_GROUPS,
        xmlns = ?NS_XABBER_REWRITE_NOTIFY},
      Notify2 = do_rewrite_message(Server, Group, User, Notify1),
      store_event(Server, Group, Notify2, Ver),
      send_notifications(Server, Group, Notify2),
      ok;
    Err ->
      Err
  end.

do_rewrite_message(Server, Group, UserS, Replace) ->
  #replace{id = ID, replace_message = ReplaceMsg} = Replace,
  #replace_message{body = Text, sub_els = SubEls} = ReplaceMsg,
  GroupJID = jid:from_string(Group),
  UserJID = jid:from_string(UserS),
  Msg = #message{from = UserJID, to = GroupJID,
    body = [#text{data = Text}], sub_els = SubEls},
  GrMsg = groups_messages:modify(Msg),
  OldMsg = get_msg_from_archive(Server, GroupJID, ID),
  Replaced = #replaced{stamp = erlang:timestamp()},
  NewEls = [#origin_id{id = OldMsg#message.id} | GrMsg#message.sub_els],
  NewMsg = OldMsg#message{
    body = GrMsg#message.body,
    sub_els = [Replaced| NewEls]},
  change_msg_in_archive(Server, Group, ID, NewMsg),
  Time = #delivery_time{by = GroupJID,
    stamp = misc:usec_to_now(binary_to_integer(ID))},
  [#text{data = Text1}]  = GrMsg#message.body,
  NewReplaceMsg = ReplaceMsg#replace_message{
    replaced = Replaced,
    stanza_id = #stanza_id{id = ID, by = GroupJID},
    body = Text1, sub_els = [Time | NewEls]},
  Replace#replace{replace_message = NewReplaceMsg}.

get_msg_from_archive(Server, GroupJID, ID) ->
  Mod = gen_mod:db_mod(Server, 'mod_mam'),
  case Mod:select(Server, GroupJID,
    GroupJID,[{'ids',[ID]}], undefined, chat) of
    {[{_, _, Forwarded}], true, 1} ->
      hd(Forwarded#forwarded.sub_els);
    Err ->
      %%  message not found in archive
      ?ERROR_MSG("The message is gone!!! group: ~p, id: ~p.\n ~p",
        [GroupJID, ID, Err]),
      error
  end.

change_msg_in_archive(Server, Group, ID, Msg) ->
  MsgE = xmpp:encode(Msg),
  {GUser, GHost, _} = jid:tolower(jid:from_string(Group)),
  XML = fxml:element_to_binary(MsgE),
  Text = fxml:get_subtag_cdata(MsgE, <<"body">>),
  ejabberd_sql:sql_query(
    Server,
    ?SQL("update archive set xml=%(XML)s, txt=%(Text)s"
    " where timestamp=%(ID)d and username=%(GUser)s and %(GHost)H")).

%% retract all messages

retract_all_messages(Server, Group, User) ->
  case check_permissions(retract_all, Server, User, Group, []) of
    ok ->
      Ver = get_new_version(Server, Group),
      Notify = #retract_all{symmetric = true,
        conversation = jid:from_string(Group),
        type = ?NS_GROUPS, version = Ver,
        xmlns = ?NS_XABBER_REWRITE_NOTIFY},
      delete_messages_from_archive(Group),
      delete_pinned_message(Server, Group, all),
      store_event(Server, Group, Notify, Ver),
      send_notifications(Server, Group, Notify),
      ok;
    Err ->
      Err
  end.

%% retract user messages

retract_user_messages(Server, Group, User, UserID) ->
  case check_permissions(retract_user, Server, User,
    Group, [UserID]) of
    {ok, Peer} ->
      Ver = get_new_version(Server, Group),
      Notify =  #retract_user{id = UserID,
        symmetric = true, type = ?NS_GROUPS,
        conversation = jid:from_string(Group),
        version = Ver,
        xmlns = ?NS_XABBER_REWRITE_NOTIFY},
      delete_pinned_message(Server, Group, {user, Peer}),
      delete_user_messages_from_archive(Group, Peer),
      store_event(Server, Group, Notify, Ver),
      send_notifications(Server, Group, Notify),
      ok;
    Err ->
      Err
  end.

%% retract message

retract_message(Server, Group, User, ID) ->
  case check_permissions(retract, Server, User, Group, [ID]) of
    ok ->
      Notify = #retract_message{id = ID,
        type = ?NS_GROUPS, symmetric = true,
        conversation = jid:from_string(Group),
        xmlns = ?NS_XABBER_REWRITE_NOTIFY},
      do_retract_message(Server, Group, ID, Notify);
    Err ->
      Err
  end.

do_retract_message(Server, Group, ID, Notify)->
  case delete_message_from_archive(Server, Group, ID) of
    ok ->
      Ver = get_new_version(Server, Group),
      Notify1 = Notify#retract_message{version = Ver},
      delete_pinned_message(Server, Group, ID),
      store_event(Server, Group, Notify1, Ver),
      send_notifications(Server, Group, Notify1),
      ok;
    Err ->
      Err
  end.

%% rewrite archive

send_rewrite_archive(Server, UserJID, Group, Ver, Less) ->
  {Less1, Ver1} = check_query_params(Less, Ver),
  Count = get_count_events(Server, Group, Ver1),
  CurrentVer = get_version(Server, Group),
  if
    Count > Less1 ->
      send_invalidate(UserJID, Group, CurrentVer);
    true ->
      send_rewrite_archive(Server, UserJID, Group, Ver1)
  end,
  CurrentVer.

send_rewrite_archive(Server, UserJID, Group, Ver)->
  QueryElements = get_rewrite_archive(Server, Group, Ver),
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
  Invalidate = #retract_invalidate{version = Ver,
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

store_event(Server, Group, Element, Ver) ->
  XML = fxml:element_to_binary(xmpp:encode(Element)),
  sql_insert_event(Server, Group, XML, Ver).

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
      _ ->
        ok
    end end, MsgOwners);
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
  sql_count_events(Server, Group, Version).

get_rewrite_archive(Server, Group, Version) ->
  sql_rewrite_archive(Server, Group, Version).

get_version(Server, Group) ->
  sql_get_version(Server, Group).

get_new_version(Server, Group) ->
  get_version(Server, Group) + 1.

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

sql_count_events(Server, Group, Version) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(count(*))d from groupchat_retract"
    " where chatgroup=%(Group)s and version > %(Version)d")) of
    {selected, [{Count}]} -> Count;
    _ -> 0
  end.

sql_rewrite_archive(Server, Group, Version) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(xml)s from groupchat_retract where chatgroup=%(Group)s "
    " and version > %(Version)d order by version")) of
    {selected, Result} -> [I || {I} <- Result];
    _ -> []
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

sql_insert_event(Server, Group, Txt, Version) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL_INSERT(
      "groupchat_retract",
      [ "chatgroup=%(Group)s",
        "xml=%(Txt)s",
        "version=%(Version)s"
      ])).
