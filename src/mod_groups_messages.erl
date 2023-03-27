%%%-------------------------------------------------------------------
%%% File    : mod_groups_messages.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Work with message in group chats
%%% Created : 17 May 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_groups_messages).
-author('andrey.gagarin@redsolution.com').
-compile([{parse_transform, ejabberd_sql_pt}]).
-behavior(gen_mod).
-behaviour(gen_server).
-export([start/2, stop/1, depends/2, mod_options/1]).
-export([process_messages/0,send_message/3]).
-export([init/1, handle_call/3, handle_cast/2,
  handle_info/2, terminate/2, code_change/3]).
-export([
  message_hook/1,
  strip_stanza_id/2,
  send_displayed/3,
  get_actual_user_info/2, get_displayed_msg/4, shift_references/2, binary_length/1, set_displayed/4
]).
-export([get_last/1, seconds_since_epoch/1]).

-record(state, {host :: binary()}).

-record(displayed_msg,
{
  chat = {<<"">>, <<"">>}                     :: {binary(), binary()} | '_',
  bare_peer = {<<"">>, <<"">>, <<"">>}        :: ljid() | '_',
  stanza_id = <<>>                            :: binary() | '_',
  origin_id = <<>>                            :: binary() | '_'
}
).

-record(groupchat_blocked_user, {user :: binary(), timestamp :: integer() }).
-export([send_received/4]).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").

start(Host, Opts) ->
  gen_mod:start_child(?MODULE, Host, Opts).


stop(Host) ->
  gen_mod:stop_child(?MODULE, Host).

depends(_Host, _Opts) -> [].

mod_options(_Opts) -> [].

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Host, _Opts]) ->
  init_db(),
  {ok, #state{host = Host}}.

init_db() ->
  ejabberd_mnesia:create(?MODULE, displayed_msg,
    [{disc_only_copies, [node()]},
      {type, bag},
      {attributes, record_info(fields, displayed_msg)}]),
  ejabberd_mnesia:create(?MODULE, groupchat_blocked_user,
    [{ram_copies, [node()]},
      {attributes, record_info(fields, groupchat_blocked_user)}]).

handle_call(_Call, _From, State) ->
  {noreply, State}.

handle_cast(Msg, State) ->
  ?WARNING_MSG("unexpected cast: ~p", [Msg]),
  {noreply, State}.


handle_info(Info, State) ->
  ?WARNING_MSG("unexpected info: ~p", [Info]),
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%
message_hook(#message{to =To, from = From} = Pkt) ->
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  UserStatus = check_permission_write(User,Chat),
  ChatStatus = mod_groups_chats:get_chat_active(Server,Chat),
  case UserStatus of
    restricted ->
      Text = <<"You have no permission to write in this chat">>,
      BodySer = [#text{lang = <<>>,data = Text}],
      ElsSer = [#xabbergroupchat_x{no_permission = <<>>, xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE}],
      MessageNew = #message{from = To, to = From, id = randoms:get_string(),
        type = chat, body = BodySer, sub_els = ElsSer, meta = #{}},
      UserID = mod_groups_users:get_user_id(Server,User,Chat),
      ejabberd_router:route_error(Pkt, xmpp:err_not_allowed()),
      send_message_no_permission_to_write(UserID,MessageNew);
    blocked ->
      Text = <<"You are blocked in this chat">>,
      BodySer = [#text{lang = <<>>,data = Text}],
      UserID = mod_groups_users:get_user_id(Server,User,Chat),
      UserJID = jid:from_string(User),
      UserCard = #xabbergroupchat_user_card{id = UserID, jid = UserJID},
      ElsSer = [#xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE, sub_els = [UserCard]}],
      MessageNew = #message{from = To, to = From, id = randoms:get_string(),
        type = chat, body = BodySer, sub_els = ElsSer, meta = #{}},
      ejabberd_router:route_error(Pkt, xmpp:err_not_allowed()),
      send_message_no_permission_to_write(UserID,MessageNew);
    allowed when ChatStatus =/= <<"inactive">> ->
      Message = Pkt#message{type = chat},
      transform_message(Message);
    _ when ChatStatus == <<"inactive">> ->
      Text = <<"Chat is inactive.">>,
      BodySer = [#text{lang = <<>>,data = Text}],
      ElsSer = [#xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE}],
      MessageNew = #message{from = To, to = From, id = randoms:get_string(),
        type = chat, body = BodySer, sub_els = ElsSer, meta = #{}},
      UserID = mod_groups_users:get_user_id(Server,User,Chat),
      ejabberd_router:route_error(Pkt, xmpp:err_not_allowed()),
      send_message_no_permission_to_write(UserID,MessageNew);
    _ ->
      ejabberd_router:route_error(Pkt, xmpp:err_not_allowed())
  end.

-spec check_permission_write(binary(), binary()) -> allowed | restricted | blocked | notexist .
check_permission_write(User,Chat) ->
  ChatJID = jid:from_string(Chat),
  Server = ChatJID#jid.lserver,
  case mod_groups_users:check_if_exist(Server,Chat,User) of
    true ->
      case mod_groups_restrictions:is_restricted(<<"send-messages">>,User,Chat) of
        true -> restricted;
        _ -> allowed
      end;
    _ ->
      UserJID =  jid:from_string(User),
      Domain = UserJID#jid.lserver,
      case mod_groups_block:check_block(Server,Chat,User,Domain) of
        {stop,not_ok} -> blocked;
        _-> notexist
      end
  end.

send_received_and_message(Pkt, From, To, OriginID, Users) ->
  {Pkt2, _State2} = mod_mam:user_send_packet({Pkt,#{jid => To}}),
  send_received(Pkt2,From,OriginID,To),
  send_message(Pkt2,Users,To).

send_message(Message,[],From) ->
  mod_groups_presence:send_message_to_index(From, Message),
  ok;
send_message(Message,Users,From) ->
  [{User}|RestUsers] = Users,
  To = jid:from_string(User),
  ejabberd_router:route(From,To,Message),
  send_message(Message,RestUsers,From).

%%--------------------------------------------------------------------
%% Sub process.
%%--------------------------------------------------------------------
process_messages() ->
  receive
    {message,Message} ->
      do_route(Message),
      process_messages();
    _ ->
      exit(normal)
  after
    300000 -> exit(normal)
  end.

%% Internal functions
%% todo: check this
do_route(#message{from = From, to = From, body=[], sub_els = Sub, type = headline} = Message) ->
  Event = lists:keyfind(ps_event,1,Sub),
  FromChat = jid:replace_resource(From,<<"Group">>),
  case Event of
    false ->
      ok;
    _ ->
      Chat = jid:to_string(From),
      #ps_event{items = Items} = Event,
      #ps_items{items = ItemList, node = Node} = Items,
      Item = lists:keyfind(ps_item,1,ItemList),
      #ps_item{sub_els = Els} = Item,
      Decoded = lists:map(fun(N) -> xmpp:decode(N) end, Els),
      [El|_R] = Decoded,
      case El of
        {nick,Nickname} when Node == <<"http://jabber.org/protocol/nick">> ->
          mod_groups_vcard:change_nick_in_vcard(From#jid.luser,From#jid.lserver,Nickname),
          AllUsers = mod_groups_users:user_list_to_send(From#jid.lserver,Chat),
          send_message(Message,AllUsers,FromChat);
        {avatar_meta,AvatarInfo,_Smth} when Node == <<"urn:xmpp:avatar:metadata">> ->
          AvatarI = hd(AvatarInfo),
          IdAvatar = AvatarI#avatar_info.id,
          AllUsers = mod_groups_users:user_list_to_send(From#jid.lserver,Chat),
          send_message(Message,AllUsers,FromChat),
          mod_groups_inspector:update_chat_avatar_id(From#jid.lserver,Chat,IdAvatar);
        {avatar_meta,_AvatarInfo,_Smth} ->
          AllUsers = mod_groups_users:user_list_to_send(From#jid.lserver,Chat),
          send_message(Message,AllUsers,FromChat);
        {nick,_Nickname} ->
          AllUsers = mod_groups_users:user_list_to_send(From#jid.lserver,Chat),
          send_message(Message,AllUsers,FromChat);
        _ ->
          ok
      end
  end;
do_route(#message{from = From, to = To, body=[], sub_els = Sub, type = headline}) ->
  Event = lists:keyfind(ps_event,1,Sub),
  Chat = jid:to_string(jid:remove_resource(To)),
  User = jid:to_string(jid:remove_resource(From)),
  LServer = To#jid.lserver,
  case Event of
    false ->
      ok;
    _ ->
      #ps_event{items = Items} = Event,
      #ps_items{items = ItemList, node = Node} = Items,
      Item = lists:keyfind(ps_item,1,ItemList),
      #ps_item{sub_els = Els} = Item,
      Decoded = lists:map(fun(N) -> xmpp:decode(N) end, Els),
      [El|_R] = Decoded,
      case El of
        {avatar_meta,AvatarInfo,_Smth} when Node == <<"urn:xmpp:avatar:metadata">> ->
          AvatarI = hd(AvatarInfo),
          IdAvatar = AvatarI#avatar_info.id,
          OldID = mod_groups_vcard:get_image_id(LServer,User, Chat),
          case OldID of
            IdAvatar ->
              ok;
            _ ->
              %% todo: why can't we use metadata from this message?
              ejabberd_router:route(jid:replace_resource(To,<<"Group">>),jid:remove_resource(From), mod_groups_vcard:get_pubsub_meta())
          end;
        _ ->
          ok
      end
  end;
do_route(#message{body=[], from = From, type = chat, to = To} = Msg) ->
  Displayed = xmpp:get_subtag(Msg, #message_displayed{}),
  case Displayed of
    #message_displayed{id = OriginID,sub_els = _Sub} ->
      {LName,LServer,_} = jid:tolower(To),
      ChatJID = jid:make(LName,LServer),
      Displayed2 = filter_packet(Displayed,ChatJID),
      StanzaID = get_stanza_id(Displayed2,ChatJID,LServer,OriginID),
      ejabberd_hooks:run(groupchat_got_displayed,LServer,[From,ChatJID,StanzaID]),
      send_displayed(ChatJID,StanzaID,OriginID);
    _ ->
      ok
  end;
do_route(#message{body=_Body, type = Type} = Message) when Type == normal orelse Type == chat->
  case xmpp:get_subtag(Message, #xabbergroupchat_invite{}) of
    false ->
      message_hook(Message);
    _ ->
      ?DEBUG("Drop message with invite",[]),
      ok
  end;
do_route(_Message) ->
  ok.

%% todo: it needs to be optimized
send_displayed(_ChatJID,empty,_MessageID) ->
  ok;
send_displayed(ChatJID,StanzaID,MessageID) ->
  #jid{lserver = LServer, luser = LName} = ChatJID,
  Msgs = get_displayed_msg(LName,LServer,StanzaID, MessageID),
  lists:foreach(fun(Msg) ->
    #displayed_msg{bare_peer = {PUser,PServer,_}, stanza_id = StanzaID, origin_id = MessageID} = Msg,
    case PUser of
      LName when PServer == LServer ->
        send_displayed_to_all(ChatJID,StanzaID,MessageID);
      _ ->
        Displayed = #message_displayed{id = MessageID, sub_els = [#stanza_id{id = StanzaID, by = jid:remove_resource(ChatJID)}]},
        M = #message{type = chat, from = ChatJID, to = jid:make(PUser,PServer), sub_els = [Displayed], id=randoms:get_string()},
        ejabberd_router:route(M)
    end
                end, Msgs),
  delete_old_messages(LName,LServer,StanzaID).

send_displayed_to_all(ChatJID,StanzaID,MessageID) ->
  Displayed = #message_displayed{id = MessageID, sub_els = [#stanza_id{id = StanzaID, by = jid:remove_resource(ChatJID)}]},
  Server = ChatJID#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(ChatJID)),
  ListAll = mod_groups_users:user_list_to_send(Server,Chat),
  {selected, NoReaders} = mod_groups_users:user_no_read(Server,Chat),
  ListTo = ListAll -- NoReaders,
  case ListTo of
    [] ->
      ok;
    _ ->
      lists:foreach(fun(U) ->
        {Member} = U,
        To = jid:from_string(Member),
        M = #message{type = chat, from = ChatJID, to = To, sub_els = [Displayed], id=randoms:get_string()},
        ejabberd_router:route(M) end, ListTo)
  end,
  ok.

get_displayed_msg(LName,LServer,StanzaID, MessageID) ->
  FN = fun()->
    mnesia:match_object(displayed_msg,
      {displayed_msg, {LName,LServer}, {'_','_','_'}, StanzaID, MessageID},
      read)
       end,
  {atomic,Msgs} = mnesia:transaction(FN),
  Msgs.

delete_old_messages(LName,LServer,StanzaID) ->
  FN = fun()->
    mnesia:match_object(displayed_msg,
      {displayed_msg, {LName,LServer}, {'_','_','_'}, '_','_'},
      read)
       end,
  {atomic,Msgs} = mnesia:transaction(FN),
  MsgToDel = [X || X <- Msgs, X#displayed_msg.stanza_id =< StanzaID],
  lists:foreach(fun(M) ->
    mnesia:dirty_delete_object(M) end, MsgToDel).

get_stanza_id(Pkt,BareJID,LServer,OriginID) ->
  case xmpp:get_subtag(Pkt, #stanza_id{}) of
    #stanza_id{by = BareJID, id = StanzaID} ->
      StanzaID;
    _ ->
      mod_unique:get_stanza_id_by_origin_id(LServer,OriginID,BareJID#jid.luser)
  end.

filter_packet(Pkt,BareJID) ->
  Els = xmpp:get_els(Pkt),
  NewEls = lists:filtermap(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"stanza-id">> andalso NS == ?NS_SID_0) ->
        try xmpp:decode(El) of
          #stanza_id{by = By} ->
            By == BareJID
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          true
      end
    end, Els),
  xmpp:set_els(Pkt, NewEls).

binary_length(Binary) ->
  B1 = binary:replace(Binary,<<"&">>,<<"&amp;">>,[global]),
  B2 = binary:replace(B1,<<">">>,<<"&gt;">>,[global]),
  B3 = binary:replace(B2,<<"<">>,<<"&lt;">>,[global]),
  B4 = binary:replace(B3,<<"\"">>,<<"&quot;">>,[global]),
  B5 = binary:replace(B4,<<"\'">>,<<"&apos;">>,[global]),
  string:len(unicode:characters_to_list(B5)).

transform_message(#message{id = Id, to = To,from = From, body = Body} = Pkt) ->
  Text = xmpp:get_text(Body),
  Server = To#jid.lserver,
  LUser = To#jid.luser,
  Chat = jid:to_string(jid:remove_resource(To)),
  Jid = jid:to_string(jid:remove_resource(From)),
  UserCard = mod_groups_users:form_user_card(Jid,Chat),
  User = mod_groups_users:choose_name(UserCard),
  Username = <<User/binary, ":", "\n">>,
  Length = binary_length(Username),
  Reference = #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT, sub_els = [#xmppreference{type = <<"mutable">>, 'begin' = 0, 'end' = Length, sub_els = [UserCard]}]},
  NewBody = [#text{lang = <<>>,data = <<Username/binary, Text/binary >>}],
  {selected, AllUsers} = mod_groups_sql:user_list_to_send(Server,Chat),
  {selected, NoReaders} = mod_groups_users:user_no_read(Server,Chat),
  UsersWithoutSender = AllUsers -- [{Jid}],
  Users = UsersWithoutSender -- NoReaders,
  PktSanitarized1 = strip_x_elements(Pkt),
  PktSanitarized = strip_reference_elements(PktSanitarized1),
  Els2 = shift_references(PktSanitarized, Length),
  NewEls = [Reference|Els2],
  ArchiveMsg = Pkt#message{body = NewBody, sub_els = NewEls, to = jid:remove_resource(From)},
  OriginID = case get_origin_id(xmpp:get_subtag(ArchiveMsg, #origin_id{})) of
               false ->
                 Id;
               Val -> Val
             end,
  Retry = xmpp:get_subtag(ArchiveMsg, #delivery_retry{}),
  Pkt0 = strip_stanza_id(ArchiveMsg,Server),
  Pkt1 = mod_unique:remove_request(Pkt0,Retry),
  case Retry of
    false ->
      send_received_and_message(Pkt1, From, To, OriginID, Users);
    _ ->
      case mod_unique:get_message(Server, LUser, OriginID) of
        #message{} = Found ->
          FoundMeta = Found#message.meta,
          StanzaID = integer_to_binary(maps:get('stanza_id', FoundMeta)),
          Message =  case mod_mam_sql:select(Server, To, To,[{'stanza-id',StanzaID}], undefined, chat) of
                       {[{_, _, Forwarded}], true, 1} ->
                         Message1 = hd(Forwarded#forwarded.sub_els),
                         Message2 = Message1#message{meta = FoundMeta},
                         xmpp:set_from_to(Message2,From,To);
                       _ ->
                         %%  message not found in archive
                         Found
                     end,
          send_received(Message, From, OriginID,To);
        _ ->
         send_received_and_message(Pkt1, From, To, OriginID, Users)
      end
  end.

get_origin_id(OriginId) ->
  case OriginId of
    false ->
      false;
    _ ->
      #origin_id{id = ID} = OriginId,
      ID
  end.

-spec strip_reference_elements(stanza()) -> stanza().
strip_reference_elements(Pkt) ->
  Els = xmpp:get_els(Pkt),
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
  xmpp:set_els(Pkt, NewEls).

-spec strip_x_elements(stanza()) -> stanza().
strip_x_elements(Pkt) ->
  Els = xmpp:get_els(Pkt),
  NewEls = lists:filter(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      IsGroupsNS = str:prefix(?NS_GROUPCHAT, NS),
      if (Name == <<"x">> andalso IsGroupsNS) ->
        try xmpp:decode(El) of
          #xabbergroupchat_x{} ->
            false
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          true
      end
    end, Els),
  xmpp:set_els(Pkt, NewEls).

-spec strip_stanza_id(stanza(), binary()) -> stanza().
strip_stanza_id(Pkt, LServer) ->
  Els = xmpp:get_els(Pkt),
  NewEls = lists:filter(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"archived">> andalso NS == ?NS_MAM_TMP);
      (Name == <<"time">> andalso NS == ?NS_UNIQUE);
      (Name == <<"stanza-id">> andalso NS == ?NS_SID_0) ->
        try xmpp:decode(El) of
          #mam_archived{by = By} ->
            By#jid.lserver == LServer;
          #unique_time{by = By} ->
            By#jid.lserver == LServer;
          #stanza_id{by = By} ->
            By#jid.lserver == LServer
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          true
      end
    end, Els),
  xmpp:set_els(Pkt, NewEls).

send_received(
    Pkt,
    JID,
    OriginID,ChatJID) ->
  JIDBare = jid:remove_resource(JID),
  #message{meta = #{stanza_id := StanzaID}} = Pkt,
  Pkt2 = xmpp:set_from_to(Pkt,JID,ChatJID),
  set_displayed(ChatJID,JID,StanzaID,OriginID),
  UniqueReceived = #delivery_x{sub_els = [Pkt2]},
  Confirmation = #message{
    from = ChatJID,
    to = JIDBare,
    type = headline,
    sub_els = [UniqueReceived]},
  ejabberd_router:route(Confirmation).

set_displayed(ChatJID,UserJID,StanzaID,OriginID) ->
  {LName,LServer,_} = jid:tolower(ChatJID),
  {PUser,PServer,_} = jid:tolower(UserJID),
  Msg = #displayed_msg{chat = {LName,LServer}, stanza_id = integer_to_binary(StanzaID), origin_id = OriginID, bare_peer = {PUser,PServer,<<>>}},
  mnesia:dirty_write(Msg).

%% Actual information about user

get_actual_user_info(_Server, []) ->
  [];
get_actual_user_info(Server, Msgs) ->
  UsersIDs = lists:map(fun(Pkt) ->
    {_ID, _IDInt, El} = Pkt,
    #forwarded{sub_els = [MsgE]} = El,
    Msg = xmpp:decode(MsgE),
    X = xmpp:get_subtag(Msg, #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT}),
    case X of
      false ->
        {false,false};
      _ ->
        Reference = xmpp:get_subtag(X, #xmppreference{}),
        case Reference of
          false ->
            {false, false};
          _ ->
            Card = xmpp:get_subtag(Reference, #xabbergroupchat_user_card{}),
            case Card of
              false ->
                {false,false};
              _ ->
                {jid:to_string(jid:remove_resource(Msg#message.from)),
                  Card#xabbergroupchat_user_card.id}
            end
        end
    end
    end, Msgs
  ),
  UniqUsersIDs = lists:usort(UsersIDs),
  Chats = lists:usort([C || {C,_ID} <- UsersIDs]),
  ChatandUserCards = lists:map(fun(Chat) ->
    case Chat of
      false ->
        {false,[]};
      _ ->
        Users = [U ||{C,U} <- UniqUsersIDs ,C == Chat],
        AllUserCards = lists:map(fun(UsID) ->
          User = mod_groups_users:get_user_by_id(Server,Chat,UsID),
          case User of
            none ->
              {none,none};
            _ ->
              UserCard = mod_groups_users:form_user_card(User,Chat),
              {UsID, UserCard}
          end end, Users),
        UserCards = [{UID,Card}|| {UID,Card} <- AllUserCards, UID =/= none],
        {Chat, UserCards}
    end end, Chats),
  change_all_messages(ChatandUserCards,Msgs).

change_all_messages(ChatandUsers, Msgs) ->
  lists:map(fun(Pkt) ->
    {_ID, _IDInt, El} = Pkt,
    #forwarded{sub_els = [Msg0]} = El,
    Msg = xmpp:decode(Msg0),
    X = xmpp:get_subtag(Msg, #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT}),
    case X of
      false ->
        Pkt;
      _ ->
        Ref = xmpp:get_subtag(X, #xmppreference{}),
        case Ref of
          false ->
            Pkt;
          _ ->
            Card = xmpp:get_subtag(Ref, #xabbergroupchat_user_card{}),
            change_message(Card,ChatandUsers,Pkt)
        end
    end
            end
    , Msgs
  ).

change_message(false,_ChatandUsers,Pkt) ->
  Pkt;
change_message(OldCard,ChatandUsers,Pkt) ->
  {ID, IDInt, El} = Pkt,
  #forwarded{sub_els = [Msg0]} = El,
  Msg = xmpp:decode(Msg0),
  Xtag = xmpp:get_subtag(Msg, #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT}),
  CurrentUserID = OldCard#xabbergroupchat_user_card.id,
  Chat = jid:to_string(jid:remove_resource(Msg#message.from)),
  Cards = lists:keyfind(Chat,1,ChatandUsers),
  case Cards of
    false ->
      Pkt;
    _ ->
      {Chat,UserCards} = Cards,
      IDNewCard = lists:keyfind(CurrentUserID,1,UserCards),
      case IDNewCard of
        false ->
          Pkt;
        _ ->
          {CurrentUserID, NewCard} = IDNewCard,
          Pkt2 = strip_x_elements(Msg),
          Sub2 = xmpp:get_els(Pkt2),
          Reference = xmpp:get_subtag(Xtag, #xmppreference{}),
          X = Reference#xmppreference{type = <<"mutable">>, sub_els = [NewCard]},
          NewX = #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT, sub_els = [X]},
          XEl = xmpp:encode(NewX),
          Sub3 = [XEl|Sub2],
          {ID,IDInt,El#forwarded{sub_els = [Msg0#message{sub_els = Sub3}]}}
      end
  end.


shift_references(Pkt, Length) ->
  Els = xmpp:get_els(Pkt),
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

%% Block to write

send_message_no_permission_to_write(User,Message) ->
  Last = get_last(User),
  case Last of
    [] ->
      write_new_ts(User),
      ejabberd_router:route(Message);
    [Blocked] ->
      check_and_send(Blocked,Message)
  end.

check_and_send(Last,Message) ->
  Now = seconds_since_epoch(0),
  LastTime = Last#groupchat_blocked_user.timestamp,
  User = Last#groupchat_blocked_user.user,
  Diff = Now - LastTime,
  case Diff of
    _  when Diff > 60 ->
      clean_last(Last),
      ejabberd_router:route(Message),
      write_new_ts(User);
    _ ->
      ok
  end.

get_last(User) ->
  FN = fun()->
    mnesia:match_object(groupchat_blocked_user,
      {groupchat_blocked_user, User, '_'},
      read) end,
  {atomic,Last} = mnesia:transaction(FN),
  Last.

clean_last(Last) ->
  mnesia:dirty_delete_object(Last).

write_new_ts(User) ->
  TS = seconds_since_epoch(0),
  B = #groupchat_blocked_user{user = User, timestamp = TS},
  mnesia:dirty_write(B).

-spec seconds_since_epoch(integer()) -> non_neg_integer().
seconds_since_epoch(Diff) ->
  {Mega, Secs, _} = os:timestamp(),
  Mega * 1000000 + Secs + Diff.
