%%%-------------------------------------------------------------------
%%% File    : mod_groupchat_messages.erl
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

-module(mod_groupchat_messages).
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
  check_permission_write/2,
  check_permission_media/2,
  add_path/3,
  strip_stanza_id/2,
  send_displayed/3,
  get_items_from_pep/3, check_invite/2, get_actual_user_info/2, get_displayed_msg/4, shift_references/2, binary_length/1, set_displayed/4
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
-export([form_groupchat_message_body/5,send_service_message/3, send_received/4]).
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
  ejabberd_hooks:add(groupchat_message_hook, Host, ?MODULE, check_invite, 5),
  ejabberd_hooks:add(groupchat_message_hook, Host, ?MODULE, check_permission_write, 10),
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

terminate(_Reason, #state{host = Host}) ->
  ejabberd_hooks:delete(groupchat_message_hook, Host, ?MODULE, check_invite, 5),
  ejabberd_hooks:delete(groupchat_message_hook, Host, ?MODULE, check_permission_write, 10).

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%
message_hook(#message{id = Id,to =To, from = From, sub_els = Els, type = Type, meta = Meta, body = Body} = Pkt) ->
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  UserExits = mod_groupchat_inspector_sql:check_user(User,Server,Chat),
  Result = ejabberd_hooks:run_fold(groupchat_message_hook, Server, Pkt, [{User,Chat,UserExits,Els}]),
  ChatStatus = mod_groupchat_chats:get_chat_active(Server,Chat),
  case Result of
    not_ok ->
      Text = <<"You have no permission to write in this chat">>,
      IdSer = randoms:get_string(),
      TypeSer = chat,
      BodySer = [#text{lang = <<>>,data = Text}],
      ElsSer = [#xabbergroupchat_x{no_permission = <<>>}],
      MetaSer = #{},
      MessageNew = construct_message(To,From,IdSer,TypeSer,BodySer,ElsSer,MetaSer),
      UserID = mod_groupchat_inspector:get_user_id(Server,User,Chat),
      Err = xmpp:err_not_allowed(),
      ejabberd_router:route_error(Pkt, Err),
      send_message_no_permission_to_write(UserID,MessageNew);
    blocked ->
      Text = <<"You are blocked in this chat">>,
      IdSer = randoms:get_string(),
      TypeSer = chat,
      BodySer = [#text{lang = <<>>,data = Text}],
      UserID = mod_groupchat_inspector:get_user_id(Server,User,Chat),
      UserJID = jid:from_string(User),
      UserCard = #xabbergroupchat_user_card{id = UserID, jid = UserJID},
      ElsSer = [#xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE, sub_els = [UserCard]}],
      MetaSer = #{},
      MessageNew = construct_message(To,From,IdSer,TypeSer,BodySer,ElsSer,MetaSer),
      Err = xmpp:err_not_allowed(),
      ejabberd_router:route_error(Pkt, Err),
      send_message_no_permission_to_write(UserID,MessageNew);
    {ok,Sub} when ChatStatus =/= <<"inactive">> ->
      Message = change_message(Id,Type,Body,Sub,Meta,To,From),
      transform_message(Message);
    _ when ChatStatus == <<"inactive">> ->
      Text = <<"Chat is inactive.">>,
      IdSer = randoms:get_string(),
      TypeSer = chat,
      BodySer = [#text{lang = <<>>,data = Text}],
      ElsSer = [#xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE}],
      MetaSer = #{},
      MessageNew = construct_message(To,From,IdSer,TypeSer,BodySer,ElsSer,MetaSer),
      UserID = mod_groupchat_inspector:get_user_id(Server,User,Chat),
      Err = xmpp:err_not_allowed(),
      ejabberd_router:route_error(Pkt, Err),
      send_message_no_permission_to_write(UserID,MessageNew);
    _ ->
      Err = xmpp:err_not_allowed(),
      ejabberd_router:route_error(Pkt, Err)
  end.

check_invite(Pkt, {_User,_Chat,_UserExits,_Els}) ->
  case xmpp:get_subtag(Pkt, #xabbergroupchat_invite{}) of
    false ->
      ok;
    _ ->
      ?DEBUG("Drop message with invite",[]),
      {stop, do_nothing}
  end.

check_permission_write(_Acc, {User,Chat,UserExits,Els}) ->
  ChatJID = jid:from_string(Chat),
  UserJId =  jid:from_string(User),
  Domain = UserJId#jid.lserver,
  Server = ChatJID#jid.lserver,
  Block = mod_groupchat_block:check_block(Server,Chat,User,Domain),
  case mod_groupchat_restrictions:is_restricted(<<"send-messages">>,User,Chat) of
    false when UserExits == exist ->
      {stop,{ok,Els}};
    _  when UserExits == exist->
      {stop,not_ok};
    _ when Block == {stop,not_ok} ->
      {stop,blocked};
    _ ->
      {stop, do_nothing}
  end.

check_permission_media(_Acc,{User,Chat,_UserExits,Els}) ->
  X = [Children || {xmlel,<<"x">>,_Attrs,Children} <- Els],
  case length(X) of
    0 ->
      {stop,{ok,Els}};
    _ ->
      [Field] = X,
      MediaList = [Children || {xmlel,<<"field">>,_Attrs,Children} <- Field],
      case length(MediaList) of
        0 ->
          {stop,{ok,Els}};
        _ ->
          [Med|_Another] = MediaList,
          [Media|_Rest] = Med,
          M = xmpp:decode(Media),
          MediaUriRare = M#media.uri,
          [MediaUri|_Re] = MediaUriRare,
          case check_permissions(MediaUri#media_uri.type,User,Chat) of
            true ->
              {stop,not_ok};
            false ->
              {stop,{ok,Els}}
          end
      end
  end.

check_permissions(Media,User,Chat) ->
  [Type,_F] =  binary:split(Media,<<"/">>),
  Allowed = case Type of
              <<"audio">> ->
                mod_groupchat_restrictions:is_restricted(<<"send-audio">>,User,Chat);
              <<"image">> ->
                mod_groupchat_restrictions:is_restricted(<<"send-images">>,User,Chat);
              _ ->
                false
            end,
  Allowed.

send_received_and_message(Pkt, From, To, OriginID, Users) ->
  {Pkt2, _State2} = mod_mam:user_send_packet({Pkt,#{jid => To}}),
  send_received(Pkt2,From,OriginID,To),
  send_message(Pkt2,Users,To).

send_message(Message,[],From) ->
  mod_groupchat_presence:send_message_to_index(From, Message),
  ok;
send_message(Message,Users,From) ->
  [{User}|RestUsers] = Users,
  To = jid:from_string(User),
  ejabberd_router:route(From,To,Message),
  send_message(Message,RestUsers,From).

send_service_message(To,Chat,Text) ->
  Jid = jid:to_string(To),
  From = jid:from_string(Chat),
  FromChat = jid:replace_resource(From,<<"Group">>),
  Id = randoms:get_string(),
  Type = chat,
  Body = [#text{lang = <<>>,data = Text}],
  {selected, AllUsers} = mod_groupchat_sql:user_list_to_send(From#jid.lserver,Chat),
  Users = AllUsers -- [{Jid}],
  Els = [service_message(Chat,Text)],
  Meta = #{},
  send_message(construct_message(Id,Type,Body,Els,Meta),Users,FromChat).

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
          mod_groupchat_vcard:change_nick_in_vcard(From#jid.luser,From#jid.lserver,Nickname),
          {selected, AllUsers} = mod_groupchat_sql:user_list_to_send(From#jid.lserver,Chat),
          send_message(Message,AllUsers,FromChat);
        {avatar_meta,AvatarInfo,_Smth} when Node == <<"urn:xmpp:avatar:metadata">> ->
          [AvatarI|_RestInfo] = AvatarInfo,
          IdAvatar = AvatarI#avatar_info.id,
          {selected, AllUsers} = mod_groupchat_sql:user_list_to_send(From#jid.lserver,Chat),
          send_message(Message,AllUsers,FromChat),
          mod_groupchat_inspector:update_chat_avatar_id(From#jid.lserver,Chat,IdAvatar),
          Presence = mod_groupchat_presence:form_presence_vcard_update(IdAvatar),
          mod_groupchat_presence:send_presence(Presence,AllUsers,FromChat);
        {avatar_meta,_AvatarInfo,_Smth} ->
          {selected, AllUsers} = mod_groupchat_sql:user_list_to_send(From#jid.lserver,Chat),
          send_message(Message,AllUsers,FromChat);
        {nick,_Nickname} ->
          {selected, AllUsers} = mod_groupchat_sql:user_list_to_send(From#jid.lserver,Chat),
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
          [AvatarI|_RestInfo] = AvatarInfo,
          IdAvatar = AvatarI#avatar_info.id,
          OldID = mod_groupchat_vcard:get_image_id(LServer,User, Chat),
          case OldID of
            IdAvatar ->
              ok;
            _ ->
              ejabberd_router:route(jid:replace_resource(To,<<"Group">>),jid:remove_resource(From),mod_groupchat_vcard:get_pubsub_meta())
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
do_route(#message{body=Body} = Message) ->
  Text = xmpp:get_text(Body),
  Len = string:len(unicode:characters_to_list(Text)),
  case Text of
    <<>> ->
      ok;
    _  when Len > 0 ->
      message_hook(Message);
    _ ->
      ok
  end.

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
  ListAll = mod_groupchat_users:user_list_to_send(Server,Chat),
  {selected, NoReaders} = mod_groupchat_users:user_no_read(Server,Chat),
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

transform_message(#message{id = Id, type = Type, to = To,from = From,
                      body = Body, meta = Meta} = Pkt) ->
  Text = xmpp:get_text(Body),
  Server = To#jid.lserver,
  LUser = To#jid.luser,
  Chat = jid:to_string(jid:remove_resource(To)),
  Jid = jid:to_string(jid:remove_resource(From)),
  UserCard = mod_groupchat_users:form_user_card(Jid,Chat),
  User = mod_groupchat_users:choose_name(UserCard),
  Username = <<User/binary, ":", "\n">>,
  Length = binary_length(Username),
  Reference = #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT, sub_els = [#xmppreference{type = <<"mutable">>, 'begin' = 0, 'end' = Length, sub_els = [UserCard]}]},
  NewBody = [#text{lang = <<>>,data = <<Username/binary, Text/binary >>}],
  {selected, AllUsers} = mod_groupchat_sql:user_list_to_send(Server,Chat),
  {selected, NoReaders} = mod_groupchat_users:user_no_read(Server,Chat),
  UsersWithoutSender = AllUsers -- [{Jid}],
  Users = UsersWithoutSender -- NoReaders,
  PktSanitarized1 = strip_x_elements(Pkt),
  PktSanitarized = strip_reference_elements(PktSanitarized1),
  Els2 = shift_references(PktSanitarized, Length),
  NewEls = [Reference|Els2],
  ToArchived = jid:remove_resource(From),
  ArchiveMsg = message_for_archive(Id,Type,NewBody,NewEls,Meta,From,ToArchived),
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

message_for_archive(Id,Type,Body,Els,Meta,From,To)->
  #message{id = Id,from = From, to = To, type = Type, body = Body, sub_els = Els, meta = Meta}.

construct_message(Id,Type,Body,Els,Meta) ->
  M = #message{id = Id, type = Type, body = Body, sub_els = Els, meta = Meta},
  M.

construct_message(From,To,Id,Type,Body,Els,Meta) ->
  M = #message{from = From, to = To, id = Id, type = Type, body = Body, sub_els = Els, meta = Meta},
  M.


change_message(Id,Type,Body,Els,Meta,To,From) ->
  #message{id = Id, type = Type, body = Body, sub_els = Els, meta = Meta, to = To, from = From}.

form_groupchat_message_body(Server,Jid,Chat,Text,Lang) ->
  Request = mod_groupchat_restrictions:get_user_rules(Server,Jid,Chat),
  case Request of
    {selected,_Tables,[]} ->
      not_ok;
    {selected,_Tables,Items} ->
      {Nick,Badge,A} = mod_groupchat_inspector:parse_items_for_message(Items),
      Children = A ++ [body(Text,Lang)],
      {Nick,Badge,#xmlel{
        name = <<"x">>,
        attrs = [
          {<<"xmlns">>,?NS_GROUPCHAT}
        ],
        children = Children
      }};
    _ ->
      not_ok
  end.

body(Data,Lang) ->
   Attrs = [{<<"xml:lang">>,Lang},{<<"xmlns">>,<<"urn:ietf:params:xml:ns:xmpp-streams">>}],
  #xmlel{name = <<"body">>, attrs = Attrs, children = [{xmlcdata, Data}]}.

parse_item(#iq{sub_els = Sub}) ->
  Pubsub = lists:keyfind(pubsub,1,Sub),
  #pubsub{items = ItemList} = Pubsub,
  #ps_items{items = Items} = ItemList,
  Item = lists:keyfind(ps_item,1,Items),
  case Item of
    false ->
      <<>>;
    _ ->
      #ps_item{sub_els = Els} = Item,
      Decoded = lists:map(fun(N) -> xmpp:decode(N) end, Els),
      Result = case Decoded of
                 [{nick,Nickname}] ->
                   Nickname;
                 [{avatar_meta,AvatarInfo,_Smth}] ->
                   AvatarInfo;
                 _ ->
                   <<>>
               end,
      Result
  end.


iq_get_item_from_pubsub(Chat,Node,ItemId) ->
  Item = #ps_item{id = ItemId},
  Items = #ps_items{items = [Item],node = Node},
  Pubsub = #pubsub{items = Items},
  #iq{type = get, id = randoms:get_string(), to = Chat, from = Chat, sub_els = [Pubsub]}.

get_items_from_pep(User,Chat,Hash) ->
  ChatJid = jid:from_string(Chat),
  UserMetadataNode = <<"urn:xmpp:avatar:metadata#",User/binary>>,
  UserNickNode = <<"http://jabber.org/protocol/nick#",User/binary>>,
  Avatar = parse_item(mod_pubsub:iq_sm(iq_get_item_from_pubsub(ChatJid,UserMetadataNode,Hash))),
  Nick = parse_item(mod_pubsub:iq_sm(iq_get_item_from_pubsub(ChatJid,UserNickNode,<<"0">>))),
  {Avatar,Nick}.

add_path(Server,Photo,JID) ->
  case bit_size(Photo) of
    0 ->
      mod_groupchat_sql:set_update_status(Server,JID,<<"true">>),
      <<>>;
    _ ->
      <<Server/binary, ":5280/pictures/", Photo/binary>>
  end.

service_message(JID,Text) ->
  #xmlel{
    name = <<"groupchat">>,
    attrs = [
      {<<"from">>, JID}
    ],
    children = [{xmlcdata, Text}]
  }.

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
      if (Name == <<"x">> andalso NS == ?NS_GROUPCHAT) ->
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
          User = mod_groupchat_users:get_user_by_id(Server,Chat,UsID),
          case User of
            none ->
              {none,none};
            _ ->
              UserCard = mod_groupchat_users:form_user_card(User,Chat),
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
