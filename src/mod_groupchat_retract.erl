%%%-------------------------------------------------------------------
%%% File    : mod_groupchat_retract.erl
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

-module(mod_groupchat_retract).
-author('andrey.gagarin@redsolution.com').
-compile([{parse_transform, ejabberd_sql_pt}]).
-behavior(gen_mod).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
%% API
-export([get_version/2]).

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
  Status = mod_groupchat_users:check_user(Server,User,Chat),
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
  Status = mod_groupchat_users:check_user(Server,User,Chat),
  case Status of
    not_exist ->
      {stop,not_ok};
    _ ->
      ok
  end.

check_user_permission_to_delete_all(_Acc, {_Server,User,Chat,_ID,_X,_V}) ->
  IsPermitted = mod_groupchat_restrictions:is_permitted(<<"delete-messages">>,User,Chat),
  case IsPermitted of
    yes ->
      ok;
    _ ->
      {stop,not_ok}
  end.


check_pinned_messages(_Acc, {Server,_User,Chat,_ID,_X,_V}) ->
  case find_and_delete_pinned_message(Server,Chat) of
    {updated,1} ->
      P = mod_groupchat_presence:form_presence(Chat),
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
  IsPermitted = mod_groupchat_restrictions:is_permitted(<<"delete-messages">>,User,Chat),
  OwnerOfMessage = mod_groupchat_inspector:get_user_by_id(Server,Chat,ID),
  case OwnerOfMessage of
    User ->
      ok;
    _ when IsPermitted == yes->
      ok;
    _ ->
      {stop,not_ok}
  end.

check_and_unpin_message(_Acc, {Server,_U,Chat,ID,_X,_V}) ->
  User = mod_groupchat_inspector:get_user_by_id(Server,Chat,ID),
  case find_and_delete_pinned_message(Server,Chat,User) of
    {updated,1} ->
      P = mod_groupchat_presence:form_presence(Chat),
      notificate(Server,Chat,P),
      ok;
    _ ->
      ok
  end.

delete_user_messages(_Acc, {Server,_User,Chat,ID,_X,_V}) ->
  User = mod_groupchat_inspector:get_user_by_id(Server,Chat,ID),
  delete_user_messages_from_archive(Server,Chat,User),
  ok.

%% retract_message hook

check_user(_Acc, {Server,User,Chat,_ID,_X,_V}) ->
  Status = mod_groupchat_users:check_user(Server,User,Chat),
  case Status of
    not_exist ->
      {stop,not_ok};
    _ ->
      ok
  end.

check_user_permission(_Acc, {Server,User,Chat,ID,_X,_V}) ->
  IsPermitted = mod_groupchat_restrictions:is_permitted(<<"delete-messages">>,User,Chat),
  OwnerOfMessage = get_owner_of_message(Server,Chat,ID),
  case OwnerOfMessage of
    User ->
      ok;
    _ when IsPermitted == yes->
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
      Presence = mod_groupchat_presence:form_presence(Chat),
      notificate(Server,Chat,Presence),
      ok
  end.

delete_message(_Acc, {Server,_User,Chat,ID,_X,_V}) ->
  NextID = select_next_id(Server,ID),
  PreviousID = select_previous_id(Server,ID),
  case NextID of
    [] ->
      delete_message_from_archive(Server,Chat,ID),
      ok;
    _ when NextID =/= [] andalso PreviousID =/= [] ->
      delete_message_from_archive(Server,Chat,ID),
      ejabberd_sql:sql_query(
        Server,
        ?SQL_INSERT(
          "previous_id",
          [ "id=%(PreviousID)d",
            "server_host=%(Server)s",
            "stanza_id=%(NextID)d"
          ])),
      ok;
    _ ->
      delete_message_from_archive(Server,Chat,ID),
      ok
  end.

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
  Status = mod_groupchat_users:check_user(Server,User,Chat),
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
  Count = get_count_events(Server,Chat,Version),
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
  FromChat = jid:replace_resource(From,<<"Groupchat">>),
  UserList = mod_groupchat_users:user_list_to_send(Server,Chat),
  lists:foreach(fun(U) ->
    {Member} = U,
    To = jid:from_string(Member),
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
  Body = MD#message.body,
  OldText = xmpp:get_text(Body),
  RefEls = get_references(Sub),
  [X] = [E || E <- RefEls, E#xmppreference.type == <<"groupchat">>],
  NewSubFiltered = filter_els(NewEls),
  UserCard = xmpp:get_subtag(X, #xabbergroupchat_user_card{}),
  UserID = UserCard#xabbergroupchat_user_card.id,
  UserJID = mod_groupchat_users:get_user_by_id(Server,Chat,UserID),
  ActualCard = mod_groupchat_users:form_user_card(UserJID,Chat),
  UserChoose = mod_groupchat_users:choose_name(ActualCard),
  Username = <<UserChoose/binary, ":", "\n">>,
  Length = mod_groupchat_messages:binary_length(Username),
  NewX = #xmppreference{type = <<"groupchat">>, sub_els = [ActualCard], 'begin' = 0, 'end' = Length - 1},
  Els1 = strip_els(Sub),
  NewSubRefShift = shift_references(NewSubFiltered, Length),
  Els2 = Els1 ++ [NewX] ++ NewSubRefShift,
  NewText = <<Username/binary, Text/binary >>,
  NewBody = [#text{lang = <<>>,data = NewText}],
  R = #replaced{stamp = erlang:timestamp(), body = OldText},
  Els3 = [R|Els2],
  MessageDecoded = #message{id = MessageID, type = Type, from = From, to = To, sub_els = Els3, meta = Meta, body = NewBody},
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
  Els4 =  set_stanza_id(Els3,ChatJID,ID),
  NewXabberReplaceMessage = XabberReplaceMessage#xabber_replace_message{body = NewText, sub_els = Els4},
  NewReplace = Replace#xabber_replace{xabber_replace_message = NewXabberReplaceMessage},
  NewReplace.

get_references(Els) ->
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
          true
      end
    end, Els),
  NewEls.

select_previous_id(Server,ID) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(id)d from previous_id"
    " where stanza_id=%(ID)d and %(Server)H")) of
    {selected,[<<>>]} ->
      [];
    {selected,[{Query}]} ->
      Query;
    _ ->
      []
  end.

select_next_id(Server,ID) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(stanza_id)d from previous_id"
    " where id=%(ID)d and %(Server)H")) of
    {selected,[<<>>]} ->
      [];
    {selected,[{Query}]} ->
      Query;
    _ ->
      []
  end.

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
		" where chatgroup=%(Chat)s and version > %(Version)d")) of
    {selected,[<<>>]} ->
      [];
    {selected,Query} ->
      Query
  end.

get_version(Server,Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    [<<"select max(version) from groupchat_retract where chatgroup = '">>,Chat,<<"' ;">>]) of
    {selected,_MAX,[[null]]} ->
      <<"0">>;
    {selected,_MAX,[[Version]]} ->
      Version
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

-spec set_stanza_id(list(), jid(), binary()) -> list().
set_stanza_id(SubELS, JID, ID) ->
  TimeStamp = usec_to_now(binary_to_integer(ID)),
  BareJID = jid:remove_resource(JID),
  Archived = #mam_archived{by = BareJID, id = ID},
  StanzaID = #stanza_id{by = BareJID, id = ID},
  Time = #unique_time{by = BareJID, stamp = TimeStamp},
  [Archived, StanzaID, Time|SubELS].

-spec usec_to_now(non_neg_integer()) -> erlang:timestamp().
usec_to_now(Int) ->
  Secs = Int div 1000000,
  USec = Int rem 1000000,
  MSec = Secs div 1000000,
  Sec = Secs rem 1000000,
  {MSec, Sec, USec}.