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
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
%% API
-export([get_version/2]).
-export([strip_els/1, filter_els/1, shift_references/2]).
-export([user_in_chat/2,check_user_permission/2,check_if_message_exist/2,check_if_message_pinned/2,check_if_less/2,send_query/2]).
-export([check_user/2,delete_message/2,store_event/2,send_notifications/2]).
-export([check_user_permission_to_delete_messages/2, check_and_unpin_message/2, delete_user_messages/2]).
-export([check_user_before_all/2,check_user_permission_to_delete_all/2,check_pinned_messages/2,delete_messages/2]).
-export([check_replace_permission/2,replace_message/2,store_event_replace/2,send_notifications_replace/2, check_user_replace/2]).
-export([start/2, stop/1, depends/2, mod_options/1]).

-export([check_pinned_message/3]).
start(Host, _Opts) ->
  ejabberd_hooks:add(replace_message, Host, ?MODULE, check_user_replace, 10),
  ejabberd_hooks:add(replace_message, Host, ?MODULE, check_replace_permission, 15),
  ejabberd_hooks:add(replace_message, Host, ?MODULE, replace_message, 25),
  ejabberd_hooks:add(replace_message, Host, ?MODULE, store_event_replace, 30),
  ejabberd_hooks:add(replace_message, Host, ?MODULE, send_notifications_replace, 35),
  ejabberd_hooks:add(retract_all, Host, ?MODULE, check_user_before_all, 10),
  ejabberd_hooks:add(retract_all, Host, ?MODULE, check_user_permission_to_delete_all, 15),
  ejabberd_hooks:add(retract_all, Host, ?MODULE, check_pinned_messages, 20),
  ejabberd_hooks:add(retract_all, Host, ?MODULE, delete_messages, 25),
  ejabberd_hooks:add(retract_all, Host, ?MODULE, store_event, 30),
  ejabberd_hooks:add(retract_all, Host, ?MODULE, send_notifications, 35),
  ejabberd_hooks:add(retract_user, Host, ?MODULE, check_user, 10),
  ejabberd_hooks:add(retract_user, Host, ?MODULE, check_user_permission_to_delete_messages, 15),
  ejabberd_hooks:add(retract_user, Host, ?MODULE, check_and_unpin_message, 20),
  ejabberd_hooks:add(retract_user, Host, ?MODULE, delete_user_messages, 25),
  ejabberd_hooks:add(retract_user, Host, ?MODULE, store_event, 30),
  ejabberd_hooks:add(retract_user, Host, ?MODULE, send_notifications, 35),
  ejabberd_hooks:add(retract_message, Host, ?MODULE, check_user, 10),
  ejabberd_hooks:add(retract_message, Host, ?MODULE, check_user_permission, 15),
  ejabberd_hooks:add(retract_message, Host, ?MODULE, check_if_message_exist, 20),
  ejabberd_hooks:add(retract_message, Host, ?MODULE, check_if_message_pinned, 22),
  ejabberd_hooks:add(retract_message, Host, ?MODULE, delete_message, 25),
  ejabberd_hooks:add(retract_message, Host, ?MODULE, store_event, 30),
  ejabberd_hooks:add(retract_message, Host, ?MODULE, send_notifications, 35),
  ejabberd_hooks:add(retract_query, Host, ?MODULE, user_in_chat, 10),
  ejabberd_hooks:add(retract_query, Host, ?MODULE, check_if_less, 25),
  ejabberd_hooks:add(retract_query, Host, ?MODULE, send_query, 30).

stop(Host) ->
  ejabberd_hooks:delete(replace_message, Host, ?MODULE, check_user_replace, 10),
  ejabberd_hooks:delete(replace_message, Host, ?MODULE, check_replace_permission, 15),
  ejabberd_hooks:delete(replace_message, Host, ?MODULE, replace_message, 25),
  ejabberd_hooks:delete(replace_message, Host, ?MODULE, store_event_replace, 30),
  ejabberd_hooks:delete(replace_message, Host, ?MODULE, send_notifications_replace, 35),
  ejabberd_hooks:delete(retract_all, Host, ?MODULE, check_user_before_all, 10),
  ejabberd_hooks:delete(retract_all, Host, ?MODULE, check_user_permission_to_delete_all, 15),
  ejabberd_hooks:delete(retract_all, Host, ?MODULE, check_pinned_messages, 20),
  ejabberd_hooks:delete(retract_all, Host, ?MODULE, delete_messages, 25),
  ejabberd_hooks:delete(retract_all, Host, ?MODULE, store_event, 30),
  ejabberd_hooks:delete(retract_all, Host, ?MODULE, send_notifications, 35),
  ejabberd_hooks:delete(retract_user, Host, ?MODULE, check_user, 10),
  ejabberd_hooks:delete(retract_user, Host, ?MODULE, check_user_permission_to_delete_messages, 15),
  ejabberd_hooks:delete(retract_user, Host, ?MODULE, check_and_unpin_message, 20),
  ejabberd_hooks:delete(retract_user, Host, ?MODULE, delete_user_messages, 25),
  ejabberd_hooks:delete(retract_user, Host, ?MODULE, store_event, 30),
  ejabberd_hooks:delete(retract_user, Host, ?MODULE, send_notifications, 35),
  ejabberd_hooks:delete(retract_message, Host, ?MODULE, check_user, 10),
  ejabberd_hooks:delete(retract_message, Host, ?MODULE, check_user_permission, 15),
  ejabberd_hooks:delete(retract_message, Host, ?MODULE, check_if_message_exist, 20),
  ejabberd_hooks:delete(retract_message, Host, ?MODULE, check_if_message_pinned, 22),
  ejabberd_hooks:delete(retract_message, Host, ?MODULE, delete_message, 25),
  ejabberd_hooks:delete(retract_message, Host, ?MODULE, store_event, 30),
  ejabberd_hooks:delete(retract_message, Host, ?MODULE, send_notifications, 35),
  ejabberd_hooks:delete(retract_query, Host, ?MODULE, user_in_chat, 10),
  ejabberd_hooks:delete(retract_query, Host, ?MODULE, check_if_less, 25),
  ejabberd_hooks:delete(retract_query, Host, ?MODULE, send_query, 30).

depends(_Host, _Opts) ->  [].

mod_options(_Opts) -> [].

%% replace hook
check_user_replace(_Acc, {Server,User,Chat,_ID,_X,_Replace,_V}) ->
  Status = mod_groups_users:check_user(Server,User,Chat),
  case Status of
    not_exist ->
      {stop,not_ok};
    _ ->
      ok
  end.

check_replace_permission(_Acc, {Server,User,Chat,ID,_X,_Replace,_V}) ->
  OwnerOfMessage = get_owner_of_message(Server,Chat,ID),
  case OwnerOfMessage of
    User ->
      ok;
    _ ->
      {stop,not_ok}
  end.

replace_message(_Acc, {Server,_User,Chat,ID,X,Replace,_V}) ->
  replace_message_from_archive(Server,Chat,ID,X,Replace).

store_event_replace(Acc, {Server,_User,Chat,_ID,_X, _Replace, Version}) ->
  XR = xmpp:encode(Acc),
  Txt = fxml:element_to_binary(XR),
  insert_event(Server,Chat,Txt,Version),
  Acc.

send_notifications_replace(Acc, {Server,_User,Chat,_ID,_X,  _Replace, _Version}) ->
  M = #message{type = headline, id = randoms:get_string(), sub_els = [Acc]},
  notificate(Server,Chat,M),
  {stop,ok}.

%% retract_all hook
check_user_before_all(_Acc, {Server,User,Chat,_ID,_X,_V}) ->
  Status = mod_groups_users:check_user(Server,User,Chat),
  case Status of
    not_exist ->
      {stop,not_ok};
    _ ->
      ok
  end.

check_user_permission_to_delete_all(_Acc, {_Server,User,Chat,_ID,_X,_V}) ->
  IsPermitted = mod_groups_restrictions:is_permitted(<<"delete-messages">>,User,Chat),
  case IsPermitted of
    true ->
      ok;
    _ ->
      {stop,not_ok}
  end.


check_pinned_messages(_Acc, {Server,_User,Chat,_ID,_X,_V}) ->
  case find_and_delete_pinned_message(Server,Chat) of
    {updated,1} ->
      P = mod_groups_presence:form_presence(Chat),
      notificate(Server,Chat,P),
      ok;
    _ ->
      ok
  end.

delete_messages(_Acc, {Server,_User,Chat,_ID,_X,_V}) ->
  delete_messages_from_archive(Server,Chat),
  ok.

%% retract_user hook

check_user_permission_to_delete_messages(_Acc, {Server,User,Chat,ID,_X,_V}) ->
  IsPermitted = mod_groups_restrictions:is_permitted(<<"delete-messages">>,User,Chat),
  OwnerOfMessage = mod_groups_inspector:get_user_by_id(Server,Chat,ID),
  case OwnerOfMessage of
    User ->
      ok;
    _ when IsPermitted == true->
      ok;
    _ ->
      {stop,not_ok}
  end.

check_and_unpin_message(_Acc, {Server,_U,Chat,ID,_X,_V}) ->
  User = mod_groups_inspector:get_user_by_id(Server,Chat,ID),
  case find_and_delete_pinned_message(Server,Chat,User) of
    {updated,1} ->
      P = mod_groups_presence:form_presence(Chat),
      notificate(Server,Chat,P),
      ok;
    _ ->
      ok
  end.

delete_user_messages(_Acc, {Server,_User,Chat,ID,_X,_V}) ->
  User = mod_groups_inspector:get_user_by_id(Server,Chat,ID),
  delete_user_messages_from_archive(Server,Chat,User),
  ok.

%% retract_message hook

check_user(_Acc, {Server,User,Chat,_ID,_X,_V}) ->
  Status = mod_groups_users:check_user(Server,User,Chat),
  case Status of
    not_exist ->
      {stop,not_ok};
    _ ->
      ok
  end.

check_user_permission(_Acc, {Server,User,Chat,ID,_X,_V}) ->
  IsPermitted = mod_groups_restrictions:is_permitted(<<"delete-messages">>,User,Chat),
  OwnerOfMessage = get_owner_of_message(Server,Chat,ID),
  case OwnerOfMessage of
    User ->
      ok;
    _ when IsPermitted == true->
      ok;
    _ ->
      {stop,not_ok}
  end.

check_if_message_exist(_Acc, {Server,_User,Chat,ID,_X,_V}) ->
  case check_message(Server,Chat,ID) of
    no_message ->
      {stop,no_message};
    _ ->
      ok
  end.

check_if_message_pinned(_Acc, {Server,_User,Chat,ID,_X,_V}) ->
  case check_pinned_message(Server,Chat,ID) of
    no_message ->
      ok;
    _ ->
      delete_pinned_message(Server,Chat,ID),
      Presence = mod_groups_presence:form_presence(Chat),
      notificate(Server,Chat,Presence),
      ok
  end.

delete_message(_Acc, {Server,_User,Chat,ID,_X,_V}) ->
  delete_message_from_archive(Server,Chat,ID).

store_event(_Acc, {Server,_User,Chat,_ID,Retract,Version}) ->
  XR = xmpp:encode(Retract),
  Txt = fxml:element_to_binary(XR),
  insert_event(Server,Chat,Txt,Version),
  Version.

send_notifications(_Acc, {Server,_User,Chat,_ID,Retract,_Version}) ->
  M = #message{type = headline, id = randoms:get_string(), sub_els = [Retract]},
  notificate(Server,Chat,M),
  {stop,ok}.

%% retract_query hook

user_in_chat(_Acc, {Server,UserJID,Chat,_Version,_Less}) ->
  User = jid:to_string(jid:remove_resource(UserJID)),
  Status = mod_groups_users:check_user(Server,User,Chat),
  case Status of
    not_exist ->
      {stop,not_ok};
    _ ->
      ok
  end.

check_if_less(_Acc,{Server,_User,Chat,Version,Less}) ->
  LessInteger = case Less of
                  undefined -> 0;
                  <<>> -> 0;
                  _ -> Less
                end,
  VersionInteger = case Version of
                     undefined -> 0;
                     _ -> Version
                   end,
  Count = get_count_events(Server,Chat,VersionInteger),
  case Count of
    _ when LessInteger =/= 0 andalso Count > LessInteger ->
      {stop,too_much};
    _ ->
      ok
  end.



send_query(_Acc,{Server,UserJID,Chat,Version,_Less}) ->
  V = case Version of
        undefined -> 0;
        <<>> -> 0;
        _ -> Version
      end,
  QueryElements = get_query(Server,Chat,V),
  ChatJID = jid:from_string(Chat),
  MsgHead = lists:map(fun(El) ->
    {Element} = El,
    EventNotDecoded= fxml_stream:parse_element(Element),
    Event = xmpp:decode(EventNotDecoded),
    #message{from = ChatJID, to = UserJID,
      type = headline, id= randoms:get_string(), sub_els = [Event]} end, QueryElements
  ),
  lists:foreach(fun(M) -> ejabberd_router:route(M) end, MsgHead),
  {stop,ok}.


%% Internal functions
notificate(Server,Chat,Stanza) ->
  From = jid:from_string(Chat),
  FromChat = jid:replace_resource(From,<<"Group">>),
  UserList = mod_groups_users:user_list_to_send(Server,Chat),
  lists:foreach(fun(U) ->
    {Member} = U,
    To = jid:from_string(Member),
    PServer = To#jid.lserver,
    PUser = To#jid.luser,
    case PServer of
      Server when Stanza == #message{} ->
        #message{sub_els = [Event]} = Stanza,
        ejabberd_hooks:run(xabber_push_notification, Server, [<<"update">>, PUser, Server, Event]);
      _ ->
        ok
    end,
    ejabberd_router:route(FromChat,To,Stanza) end, UserList
  ).

replace_message_from_archive(Server,Chat,ID,Text,Replace) ->
  #xabber_replace{ xabber_replace_message = XabberReplaceMessage} = Replace,
  NewEls = XabberReplaceMessage#xabber_replace_message.sub_els,
  ChatJID = jid:from_string(Chat),
  User = ChatJID#jid.luser,
  {selected,[{Xml}]} = ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(xml)s from archive"
    " where username=%(User)s and timestamp=%(ID)d and %(Server)H")),
  M = fxml_stream:parse_element(Xml),
  MD = xmpp:decode(M),
  From = MD#message.from,
  MessageID = MD#message.id,
  To = MD#message.to,
  Meta = MD#message.meta,
  Type = MD#message.type,
  Sub = MD#message.sub_els,
  X = xmpp:get_subtag(MD, #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT}),
  Reference = xmpp:get_subtag(X, #xmppreference{}),
  NewSubFiltered = filter_els(NewEls),
  UserCard = xmpp:get_subtag(Reference, #xabbergroupchat_user_card{}),
  UserID = UserCard#xabbergroupchat_user_card.id,
  UserJID = mod_groups_users:get_user_by_id(Server,Chat,UserID),
  ActualCard = mod_groups_users:form_user_card(UserJID,Chat),
  UserChoose = mod_groups_users:choose_name(ActualCard),
  Username = <<UserChoose/binary, ":", "\n">>,
  Length = mod_groups_messages:binary_length(Username),
  NewX = #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT, sub_els = [#xmppreference{type = <<"mutable">>, sub_els = [ActualCard], 'begin' = 0, 'end' = Length}]},
  Els1 = strip_els(Sub),
  NewSubRefShift = shift_references(NewSubFiltered, Length),
  Els2 = Els1 ++ [NewX] ++ NewSubRefShift,
  NewText = <<Username/binary, Text/binary >>,
  NewBody = [#text{lang = <<>>,data = NewText}],
  Replaced = XabberReplaceMessage#xabber_replace_message.replaced,
  MessageDecoded = #message{id = MessageID, type = Type, from = From, to = To, sub_els = [Replaced|Els2], meta = Meta, body = NewBody},
  NewM = xmpp:encode(MessageDecoded),
  XML = fxml:element_to_binary(NewM),
  ?SQL_UPSERT(
    Server,
    "archive",
    ["!timestamp=%(ID)d",
      "!username=%(User)s",
      "xml=%(XML)s",
      "txt=%(NewText)s",
      "server_host=%(Server)s"]),
  Time = #unique_time{by = ChatJID, stamp = misc:usec_to_now(binary_to_integer(ID))},
  NewXabberReplaceMessage = XabberReplaceMessage#xabber_replace_message{body = NewText, sub_els = Els2 ++ [Time]},
  NewReplace = Replace#xabber_replace{xabber_replace_message = NewXabberReplaceMessage},
  NewReplace.

get_owner_of_message(Server,Chat,ID) ->
  ChatJID = jid:from_string(Chat),
  User = ChatJID#jid.luser,
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(bare_peer)s from archive"
    " where username=%(User)s and timestamp=%(ID)d")) of
    {selected,[<<>>]} ->
      [];
    {selected,[{Query}]} ->
      Query;
    _ ->
      []
  end.

check_message(Server,Chat,ID) ->
  ChatJID = jid:from_string(Chat),
  User = ChatJID#jid.luser,
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(timestamp)s from archive"
    " where username=%(User)s and timestamp=%(ID)d")) of
    {selected,[]} ->
      no_message;
    {selected,Query} ->
      Query
  end.
find_and_delete_pinned_message(Server,Chat) ->
  ChatJID = jid:from_string(Chat),
  ChatName = ChatJID#jid.luser,
  ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchats set message = 0 where jid=%(Chat)s and message IN (select @(timestamp)s from archive"
    " where username=%(ChatName)s);")).

find_and_delete_pinned_message(Server,Chat,User) ->
  ChatJID = jid:from_string(Chat),
  ChatName = ChatJID#jid.luser,
  ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchats set message = 0 where jid=%(Chat)s and message IN (select @(timestamp)s from archive"
    " where username=%(ChatName)s and bare_peer=%(User)s);")).

check_pinned_message(Server,Chat,ID) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(message)s from groupchats"
    " where jid=%(Chat)s and message=%(ID)d")) of
    {selected,[]} ->
      no_message;
    {selected,Query} ->
      Query
  end.

delete_pinned_message(Server,Chat,ID) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchats set message = 0 "
    " where jid=%(Chat)s and message=%(ID)d")).

delete_user_messages_from_archive(Server,Chat,BarePeer) ->
  ChatJID = jid:from_string(Chat),
  User = ChatJID#jid.luser,
  ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from archive"
    " where username=%(User)s and bare_peer=%(BarePeer)s")).

delete_message_from_archive(Server,Chat,ID) ->
  ChatJID = jid:from_string(Chat),
  User = ChatJID#jid.luser,
  ejabberd_sql:sql_query(
  Server,
  ?SQL("delete from archive"
  " where username=%(User)s and timestamp=%(ID)d")).

delete_messages_from_archive(Server,Chat) ->
  ChatJID = jid:from_string(Chat),
  User = ChatJID#jid.luser,
  ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from archive"
    " where username=%(User)s and %(Server)H")).

get_count_events(Server,Chat,Version) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(count(*))d from groupchat_retract"
    " where chatgroup=%(Chat)s and version > %(Version)d")) of
    {selected, [{Count}]} ->
      Count
  end.

get_query(Server,Chat,Version) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(xml)s from groupchat_retract"
		" where chatgroup=%(Chat)s and version > %(Version)d order by version")) of
    {selected,[<<>>]} ->
      [];
    {selected,Query} ->
      Query
  end.

get_version(Server,Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select coalesce(max(@(version)d),0) from groupchat_retract where chatgroup = %(Chat)s")) of
    {selected,[{Version}]} ->
      Version;
    {selected,_} ->
      0;
    Err ->
      ?ERROR_MSG("failed to get retract version: ~p", [Err]),
      0
  end.

insert_event(Server,Chat,Txt,Version) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL_INSERT(
      "groupchat_retract",
      [ "chatgroup=%(Chat)s",
        "xml=%(Txt)s",
        "version=%(Version)s"
      ])).

strip_els(Els) ->
  NewEls = lists:filter(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"archived">> andalso NS == ?NS_MAM_TMP);
      (Name == <<"reference">> andalso NS == ?NS_REFERENCE_0);
      (Name == <<"time">> andalso NS == ?NS_UNIQUE);
      (Name == <<"origin-id">> andalso NS == ?NS_SID_0);
      (Name == <<"stanza-id">> andalso NS == ?NS_SID_0) ->
        try xmpp:decode(El) of
          #mam_archived{} ->
            false;
          #unique_time{} ->
            false;
          #origin_id{} ->
            true;
          #stanza_id{} ->
            false;
          #xmppreference{type = _Any} ->
            false
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          false
      end
    end, Els),
  NewEls.

filter_els(Els) ->
  NewEls = lists:filter(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"reference">> andalso NS == ?NS_REFERENCE_0) ->
        try xmpp:decode(El) of
          #xmppreference{type = <<"groupchat">>} ->
            false;
          #xmppreference{type = _Any} ->
            true
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          true
      end
    end, Els),
  NewEls.

shift_references(Els, Length) ->
  NewEls = lists:filtermap(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"reference">> andalso NS == ?NS_REFERENCE_0) ->
        try xmpp:decode(El) of
          #xmppreference{type = Type, 'begin' = undefined, 'end' = undefined, sub_els = Sub} ->
            {true, #xmppreference{type = Type, 'begin' = undefined, 'end' = undefined, sub_els = Sub}};
          #xmppreference{type = Type, 'begin' = Begin, 'end' = End, sub_els = Sub} ->
            {true, #xmppreference{type = Type, 'begin' = Begin + Length, 'end' = End + Length, sub_els = Sub}}
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          true
      end
    end, Els),
  NewEls.
