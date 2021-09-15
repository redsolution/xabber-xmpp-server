%%%-------------------------------------------------------------------
%%% File    : mod_groupchat_vcard.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Storage vcard of group chat users
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

-module(mod_groupchat_vcard).
-behavior(gen_mod).
-author('andrey.gagarin@redsolution.com').
-compile([{parse_transform, ejabberd_sql_pt}]).
-export([
  get_vcard/0,
  give_vcard/2,
  gen_vcard/2,
  iq_vcard/3,
  handle/1,
  give_client_vesrion/0,
  iq_last/0,
  handle_pubsub/1,
  handle_request/1,
  change_nick_in_vcard/3,
  get_image_type/2,
  update_metadata/6,
  update_parse_avatar_option/4,
  get_photo_meta/3, get_photo_data/5, get_avatar_type/4, get_all_image_metadata/2, check_old_meta/2,
  make_chat_notification_message/3, get_pubsub_meta/0, get_pubsub_data/0, handle_pubsub/4, handle_pubsub/3, get_image_id/3,
  get_vcard/2, get_payload_from_pubsub/3, update_avatar/7, get_hash/1, get_url/1, create_p2p_avatar/6,
  handle_iq/1
]).
-export([publish_avatar/3]).
%% gen_mod behavior
-export([start/2, stop/1, mod_options/1, depends/2, mod_opt_type/1]).
-include("ejabberd.hrl").
-include("ejabberd_sql_pt.hrl").
-include("logger.hrl").
-include("xmpp.hrl").


start(_, _) ->
  ok.

stop(_) ->
  ok.

mod_opt_type(get_url) ->
  fun(<<"http://", _/binary>> = URL) -> URL;
    (<<"https://", _/binary>> = URL) -> URL
  end.

mod_options(_Host) ->
  [
    %% Required option
    get_url
  ].

depends(_, _) ->
  [{mod_http_fileserver, hard}].

handle_iq(#iq{type = get} = IQ) ->
  handle_request(IQ);
handle_iq(#iq{type = set} = IQ) ->
  handle_pubsub(IQ);
handle_iq(_IQ) ->
  ok.

handle_request(Iq) ->
  try xmpp:decode_els(Iq) of
    DecodedIQ ->
      handle_decoded_request(DecodedIQ)
  catch _:_ ->
    error
  end.

handle_decoded_request(Iq) ->
  #iq{id = Id,type = Type,lang = Lang, meta = Meta, from = From,to = To,sub_els = Decoded} = Iq,
  Pubsub = lists:keyfind(pubsub,1,Decoded),
  #pubsub{items = Items} = Pubsub,
  #ps_items{node = Node} = Items,
  Server = To#jid.lserver,
  UserJid = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  UserId = mod_groupchat_inspector:get_user_id(Server,UserJid,Chat),
  NewIq = #iq{from = To,to = To,id = Id,type = Type,lang = Lang,meta = Meta,sub_els = Decoded},
  case Node of
    <<"urn:xmpp:avatar:data">> ->
      Result = mod_pubsub:iq_sm(NewIq),
      ejabberd_router:route(To,From,Result),
      Result;
    <<"urn:xmpp:avatar:metadata">> ->
      Result = mod_pubsub:iq_sm(NewIq),
      ejabberd_router:route(To,From,Result),
      Result;
    <<"http://jabber.org/protocol/nick">> ->
      Result = mod_pubsub:iq_sm(NewIq),
      ejabberd_router:route(To,From,Result),
      Result;
    <<"urn:xmpp:avatar:data#">> ->
      UserDataNode = <<"urn:xmpp:avatar:data#",UserId/binary>>,
      #ps_items{node = Node, items = Item} = Items,
      Item_ps = lists:keyfind(ps_item,1,Item),
      #ps_item{id = Hash} = Item_ps,
      Data = get_photo_data(Server,Hash,UserDataNode,UserJid,Chat),
      send_back(Data,Iq);
    <<"urn:xmpp:avatar:metadata#">> ->
      UserDataNode = <<"urn:xmpp:avatar:metadata#",UserId/binary>>,
      #ps_items{node = Node, items = Item} = Items,
      NewItems = #ps_items{node = UserDataNode, items = Item},
      NewPubsub = #pubsub{items = NewItems},
      NewDecoded = [NewPubsub],
      NewIqUser = #iq{from = To,to = To,id = Id,type = Type,lang = Lang,meta = Meta,sub_els = NewDecoded},
      Result = mod_pubsub:iq_sm(NewIqUser),
      ejabberd_router:route(To,From,Result),
      Result;
    _ ->
      node_analyse(Iq,Server,Node,Items,UserJid,Chat)
  end.

node_analyse(Iq,Server,Node,Items,User,Chat) ->
  N = binary:split(Node,<<"#">>),
  case N of
    [<<"urn:xmpp:avatar:metadata">>,_UserID] ->
      Result = xmpp:make_error(Iq,xmpp:err_item_not_found()),
      ejabberd_router:route(Result);
    [<<"urn:xmpp:avatar:data">>,_UserID] ->
      #ps_items{node = Node, items = Item} = Items,
      Item_ps = lists:keyfind(ps_item,1,Item),
      #ps_item{id = Hash} = Item_ps,
      Data = get_photo_data(Server,Hash,Node,User,Chat),
      send_back(Data,Iq);
    _ ->
      Result = xmpp:make_error(Iq,xmpp:err_item_not_found()),
      ejabberd_router:route(Result),
      Result
  end.

send_back(not_exist,Iq) ->
  Result = xmpp:make_error(Iq,xmpp:err_item_not_found()),
  ejabberd_router:route(Result),
  Result;
send_back(not_filed,Iq) ->
  Result = xmpp:make_error(Iq,xmpp:err_item_not_found()),
  ejabberd_router:route(Result),
  Result;
send_back(error,Iq) ->
  Result = xmpp:make_error(Iq,xmpp:err_internal_server_error()),
  ejabberd_router:route(Result),
  Result;
send_back(Data,Iq) ->
  Result = xmpp:make_iq_result(Iq,Data),
  ejabberd_router:route(Result),
  Result.

handle_pubsub(#iq{id = Id,type = Type,lang = Lang, meta = Meta, from = From, to = To,sub_els = Decoded} = Iq) ->
  FromGroupJID = jid:replace_resource(To,<<"Group">>),
  NewIq = #iq{from = FromGroupJID,to = To,id = Id,type = Type,lang = Lang,meta = Meta,sub_els = Decoded},
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  Permission = mod_groupchat_restrictions:is_permitted(<<"change-group">>,User,Chat),
  CanChangeAva = mod_groupchat_restrictions:is_permitted(<<"change-users">>,User,Chat),
  Pubsub = lists:keyfind(pubsub,1,Decoded),
  #pubsub{publish = Publish} = Pubsub,
  #ps_publish{node = Node, items = Items} = Publish,
  Item = lists:keyfind(ps_item,1,Items),
  UserId = mod_groupchat_inspector:get_user_id(Server,User,Chat),
  UserDataNodeId = <<"urn:xmpp:avatar:data#",UserId/binary>>,
  UserMetadataNodeId = <<"urn:xmpp:avatar:metadata#",UserId/binary>>,
  UserNickNodeId = <<"http://jabber.org/protocol/nick#",UserId/binary>>,
  UserDataNode = <<"urn:xmpp:avatar:data#">>,
  UserMetaDataNode = <<"urn:xmpp:avatar:metadata#">>,
  UserNickNode = <<"http://jabber.org/protocol/nick#">>,
  Result = case Node of
             <<"urn:xmpp:avatar:data">> when Permission == true->
               mod_pubsub:iq_sm(NewIq);
             <<"urn:xmpp:avatar:metadata">> when Permission == true->
               mod_pubsub:iq_sm(NewIq);
             <<"http://jabber.org/protocol/nick">> when Permission == true->
               mod_pubsub:iq_sm(NewIq);
             UserDataNodeId ->
               #ps_item{id = ItemId,sub_els = [Sub]} = Item,
               #avatar_data{data = Data} = xmpp:decode(Sub),
               update_data_user_put(Server, UserId, Data, ItemId,Chat),
               xmpp:make_iq_result(Iq);
             UserDataNode ->
               #ps_item{id = ItemId,sub_els = [Sub]} = Item,
               #avatar_data{data = Data} = xmpp:decode(Sub),
               update_data_user_put(Server, UserId, Data, ItemId,Chat),
               xmpp:make_iq_result(Iq);
             UserMetadataNodeId ->
               #ps_item{id = IdItem} = Item,
               case IdItem of
                 <<>> ->
                   update_metadata_user_put(Server, User, IdItem, <<>>, 0, Chat),
                   ItemsD = lists:map(fun(E) -> xmpp:decode(E) end, Items),
                   Event = #ps_event{items = ItemsD},
                   M = #message{type = headline,
                     from = To,
                     to = jid:remove_resource(From),
                     id = randoms:get_string(),
                     sub_els = [Event]
                   },
                   ejabberd_hooks:run_fold(groupchat_user_change_own_avatar, Server, User, [Server,Chat]),
                   notificate_all(To,M),
                   xmpp:make_iq_result(Iq);
                 _ ->
                   #ps_item{sub_els = [Sub]} = Item,
                   #avatar_meta{info = [Info]} = xmpp:decode(Sub),
                   #avatar_info{bytes = Size, id = IdItem, type = AvaType} = Info,
                   update_metadata_user_put(Server, User, IdItem, AvaType, Size, Chat),
                   ItemsD = #ps_items{node = UserMetadataNodeId ,items = [
                     #ps_item{id = IdItem,
                       sub_els = [#avatar_meta{info = [Info]}]}
                   ]},
                   Event = #ps_event{items = ItemsD},
                   M = #message{type = headline,
                     from = jid:replace_resource(To,<<"Group">>),
                     to = jid:remove_resource(From),
                     id = randoms:get_string(),
                     sub_els = [Event],
                     meta = #{}
                   },
%%                   ejabberd_router:route(xmpp:make_iq_result(Iq)),
                   ejabberd_hooks:run_fold(groupchat_user_change_own_avatar, Server, User, [Server,Chat]),
                   notificate_all(To,M),
                   xmpp:make_iq_result(Iq)
               end;
             UserNickNodeId ->
               mod_pubsub:iq_sm(NewIq);
             UserMetaDataNode ->
               #ps_item{id = IdItem} = Item,
               case IdItem of
                 <<>> ->
                   update_metadata_user_put(Server, User, IdItem, <<>>, 0, Chat),
%%                   NewItems = [#ps_item{sub_els = [#avatar_meta{}]}],
                   Event = #ps_event{items = #ps_items{items = Items}},
                   M = #message{type = headline,
                     from = To,
                     to = jid:remove_resource(From),
                     id = randoms:get_string(),
                     sub_els = [Event]
                   },
                   notificate_all(To,M),
                   ejabberd_hooks:run_fold(groupchat_user_change_own_avatar, Server, User, [Server,Chat]),
                   xmpp:make_iq_result(Iq);
                 _ ->
                   #ps_item{sub_els = [Sub]} = Item,
                   #avatar_meta{info = [Info]} = xmpp:decode(Sub),
                   #avatar_info{bytes = Size, id = IdItem, type = AvaType} = Info,
                   update_metadata_user_put(Server, User, IdItem, AvaType, Size, Chat),
                   Event = #ps_event{items = Items},
                   M = #message{type = headline,
                     from = To,
                     to = jid:remove_resource(From),
                     id = randoms:get_string(),
                     sub_els = [Event]
                   },
                   notificate_all(To,M),
                   ejabberd_hooks:run_fold(groupchat_user_change_own_avatar, Server, User, [Server,Chat]),
                   xmpp:make_iq_result(Iq)
               end;
             UserNickNode ->
               NewPublish = #ps_publish{node = UserMetadataNodeId, items = Items},
               NewPubsub = #pubsub{publish = NewPublish},
               NewDecoded = [NewPubsub],
               mod_pubsub:iq_sm(#iq{from = To,to = To,id = Id,type = Type,lang = Lang,meta = Meta,sub_els = NewDecoded});
             <<"urn:xmpp:avatar:data#",SomeUserId/binary>> when CanChangeAva == true ->
               SomeUser = mod_groupchat_inspector:get_user_by_id(Server,Chat,SomeUserId),
               case mod_groupchat_restrictions:validate_users(Server,Chat,User,SomeUser) of
                 ok when SomeUser =/= none ->
                   #ps_item{id = ItemId,sub_els = [Sub]} = Item,
                   #avatar_data{data = Data} = xmpp:decode(Sub),
                   update_data_user_put(Server, SomeUserId, Data, ItemId,Chat),
                   xmpp:make_iq_result(Iq);
                 _ ->
                   xmpp:make_error(Iq,xmpp:err_not_allowed(<<"You are not allowed to do it">>,<<"en">>))
               end;
             <<"urn:xmpp:avatar:metadata#",SomeUserId/binary>> when CanChangeAva == true ->
               SomeUser = mod_groupchat_inspector:get_user_by_id(Server,Chat,SomeUserId),
               #ps_item{id = IdItem} = Item,
               case IdItem of
                 <<>> when SomeUser =/= none->
                   case mod_groupchat_restrictions:validate_users(Server,Chat,User,SomeUser) of
                     ok ->
                       update_metadata_user_put_by_id(Server, SomeUserId, IdItem, <<>>, <<>>, Chat),
                       ItemsD = lists:map(fun(E) -> xmpp:decode(E) end, Items),
                       Event = #ps_event{items = ItemsD},
                       M = #message{type = headline,
                         from = To,
                         to = jid:remove_resource(From),
                         id = randoms:get_string(),
                         sub_els = [Event]
                       },
                       notificate_all(To,M),
                       ejabberd_hooks:run_fold(groupchat_user_change_some_avatar, Server, User, [Server,Chat,SomeUser]),
                       xmpp:make_iq_result(Iq);
                     _ ->
                       xmpp:make_error(Iq,xmpp:err_not_allowed(<<"You are not allowed to do it">>,<<"en">>))
                   end;
                 _  when SomeUser =/= none ->
                   case mod_groupchat_restrictions:validate_users(Server,Chat,User,SomeUser) of
                     ok ->
                       SomeUserMetadataNodeId = <<"urn:xmpp:avatar:metadata#",SomeUserId/binary>>,
                       #ps_item{sub_els = [Sub]} = Item,
                       #avatar_meta{info = [Info]} = xmpp:decode(Sub),
                       #avatar_info{bytes = Size, id = IdItem, type = AvaType} = Info,
                       update_metadata_user_put_by_id(Server, SomeUserId, IdItem, AvaType, Size, Chat),
                       ItemsD = #ps_items{node = SomeUserMetadataNodeId ,items = [
                         #ps_item{id = IdItem,
                           sub_els = [#avatar_meta{info = [Info]}]}
                       ]},
                       Event = #ps_event{items = ItemsD},
                       M = #message{type = headline,
                         from = jid:replace_resource(To,<<"Group">>),
                         to = jid:remove_resource(From),
                         id = randoms:get_string(),
                         sub_els = [Event],
                         meta = #{}
                       },
                       ejabberd_router:route(xmpp:make_iq_result(Iq)),
                       notificate_all(To,M),
                       ejabberd_hooks:run_fold(groupchat_user_change_some_avatar, Server, User, [Server,Chat,SomeUser]),
                       xmpp:make_iq_result(Iq);
                     _ ->
                       xmpp:make_error(Iq,xmpp:err_not_allowed(<<"You are not allowed to do it">>,<<"en">>))
                   end;
                 _ ->
                   xmpp:make_error(Iq,xmpp:err_not_allowed(<<"You are not allowed to do it">>,<<"en">>))
               end;
             _ ->
               xmpp:make_error(Iq,xmpp:err_not_allowed(<<"You are not allowed to do it">>,<<"en">>))
           end,
  case Result of
    #iq{type = result} when Node == <<"urn:xmpp:avatar:metadata">> ->
      ejabberd_hooks:run(groupchat_avatar_changed,Server,[Server, Chat, User]);
    _ ->
      ok
  end,
  ejabberd_router:route(To,From,Result),
  Result.

notificate_all(ChatJID,Message) ->
  Chat = jid:to_string(jid:remove_resource(ChatJID)),
  FromChat = jid:replace_resource(ChatJID,<<"Group">>),
  {selected, AllUsers} = mod_groupchat_sql:user_list_to_send(ChatJID#jid.lserver,Chat),
  mod_groupchat_messages:send_message(Message,AllUsers,FromChat).

change_nick_in_vcard(LUser,LServer,NewNick) ->
  [OldVcard|_R] = mod_vcard:get_vcard(LUser,LServer),
  #vcard_temp{photo = OldPhoto} = xmpp:decode(OldVcard),
  NewVcard = #vcard_temp{photo = OldPhoto, nickname = NewNick},
  Jid = jid:make(LUser,LServer,<<>>),
  IqSet = #iq{from = Jid, type = set, id = randoms:get_string(), sub_els = [NewVcard]},
  mod_vcard:vcard_iq_set(IqSet).

iq_vcard(JidS,Nick,Avatar) ->
  Jid = jid:from_string(JidS),
  #iq{id = randoms:get_string(),type = set, sub_els = [gen_vcard(Nick,Avatar)],to = Jid, from = Jid}.

gen_vcard(Nick,Avatar) ->
  Photo = #vcard_photo{binval = Avatar,type = <<"image/png">>},
  #vcard_temp{nickname = Nick,photo = Photo}.

iq_last() ->
#xmlel{name = <<"query">>, attrs = [{<<"xmlns">>,<<"jabber:iq:last">>},{<<"seconds">>,<<"0">>}]}.

give_client_vesrion() ->
  #xmlel{name = <<"query">>, attrs = [{<<"xmlns">>,<<"jabber:iq:version">>}],
    children = [name(<<"XabberGroupchat">>),version(<<"0.9">>),system_os(<<"Gentoo">>)]
    }.

name(Name) ->
  #xmlel{name = <<"name">>,children = [{xmlcdata,Name}]}.

version(Version) ->
  #xmlel{name = <<"version">>,children = [{xmlcdata,Version}]}.

system_os(Os) ->
  #xmlel{name = <<"os">>,children = [{xmlcdata,Os}]}.

give_vcard(User,Server) ->
  Vcard = mod_vcard:get_vcard(User,Server),
  #xmlel{
     name = <<"vCard">>,
     attrs = [{<<"xmlns">>,<<"vcard-temp">>}],
     children = Vcard}.

get_vcard() ->
    #xmlel{
       name = <<"iq">>,
       attrs = [
                {<<"id">>, randoms:get_string()},
                {<<"xmlns">>,<<"jabber:client">>},
                {<<"type">>,<<"get">>}
               ],
       children = [#xmlel{
                      name = <<"vCard">>,
                      attrs = [
                               {<<"xmlns">>,<<"vcard-temp">>}
                              ]
                     }
                  ]
      }.

get_pubsub_meta() ->
  #xmlel{
    name = <<"iq">>,
    attrs = [
      {<<"id">>, randoms:get_string()},
      {<<"xmlns">>,<<"jabber:client">>},
      {<<"type">>,<<"get">>}
    ],
    children = [#xmlel{
      name = <<"pubsub">>,
      attrs = [
        {<<"xmlns">>,<<"http://jabber.org/protocol/pubsub">>}
      ],
      children = [#xmlel{
        name = <<"items">>,
        attrs = [
          {<<"node">>,<<"urn:xmpp:avatar:metadata">>}
      ]
    }]
    }
    ]
  }.

get_pubsub_data() ->
  #xmlel{
    name = <<"iq">>,
    attrs = [
      {<<"id">>, randoms:get_string()},
      {<<"xmlns">>,<<"jabber:client">>},
      {<<"type">>,<<"get">>}
    ],
    children = [#xmlel{
      name = <<"pubsub">>,
      attrs = [
        {<<"xmlns">>,<<"http://jabber.org/protocol/pubsub">>}
      ],
      children = [#xmlel{
        name = <<"items">>,
        attrs = [
          {<<"node">>,<<"urn:xmpp:avatar:data">>}
        ]
      }]
    }
    ]
  }.

get_pubsub_data(ID) ->
  #xmlel{
    name = <<"iq">>,
    attrs = [
      {<<"id">>, randoms:get_string()},
      {<<"xmlns">>,<<"jabber:client">>},
      {<<"type">>,<<"get">>}
    ],
    children = [#xmlel{
      name = <<"pubsub">>,
      attrs = [
        {<<"xmlns">>,<<"http://jabber.org/protocol/pubsub">>}
      ],
      children = [#xmlel{
        name = <<"items">>,
        attrs = [
          {<<"node">>,<<"urn:xmpp:avatar:data">>}
        ],
        children = [#xmlel{name = <<"item">>, attrs = [{<<"id">>,ID}]}]
      }]
    }
    ]
  }.

handle(#iq{from = From, to = To, sub_els = Els}) ->
  Server = To#jid.lserver,
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  case length(Els) of
    0 ->
      ok;
    _  when length(Els) > 0 ->
      Decoded = lists:map(fun(N) -> xmpp:decode(N) end, Els),
      D = lists:keyfind(vcard_temp,1,Decoded),
      case D of
        false ->
          ok;
        _ ->
          update_vcard(Server,User,D,Chat)
      end
  end.

handle_pubsub(ChatJID,UserJID,#avatar_meta{info = AvatarINFO}) ->
  LServer = ChatJID#jid.lserver,
  User = jid:to_string(jid:remove_resource(UserJID)),
  Chat = jid:to_string(jid:remove_resource(ChatJID)),
  case AvatarINFO of
    [] ->
      OldMeta = get_image_metadata(LServer, User, Chat),
      check_old_meta(LServer, OldMeta);
    [#avatar_info{bytes = Size, id = ID, type = Type}] ->
      [#avatar_info{bytes = Size, id = ID, type = Type}] = AvatarINFO,
      OldMeta = get_image_metadata(LServer, User, Chat),
      check_old_meta(LServer, OldMeta),
      update_id_in_chats(LServer,User,ID,Type,Size,<<>>),
      ejabberd_router:route(ChatJID,UserJID,get_pubsub_data(ID));
    _ ->
      ok
  end;
handle_pubsub(_F,_T,false) ->
  ok.

handle_pubsub(ChatJID,UserJID,ID,#avatar_data{data = Data}) ->
  Server = ChatJID#jid.lserver,
  User = jid:to_string(jid:remove_resource(UserJID)),
  Chat = jid:to_string(jid:remove_resource(ChatJID)),
  Meta = get_image_metadata(Server, User, Chat),
  case Meta of
    [{ID,AvaSize,AvaType,_AvaUrl}] ->
      <<"image/",Type/binary>> = AvaType,
      Path = gen_mod:get_module_opt(Server,mod_http_fileserver,docroot),
      UrlDir = get_url(Server),
      Name = <<ID/binary, ".", Type/binary >>,
      Url = <<UrlDir/binary, "/", Name/binary>>,
      File = <<Path/binary, "/" , Name/binary>>,
      file:write_file(binary_to_list(File),Data),
      update_avatar_url_chats(Server,User,ID,AvaType,AvaSize,Url),
      set_update_status(Server,User,<<"false">>);
    _ ->
      ok
  end;
handle_pubsub(_C,_U,_I,false) ->
  ok.

update_vcard(Server,User,D,_Chat) ->
  Status = mod_groupchat_sql:get_update_status(Server,User),
%%  Photo = set_value(D#vcard_temp.photo),
  FN = set_value(D#vcard_temp.fn),
  LF = get_lf(D#vcard_temp.n),
  NickName = set_value(D#vcard_temp.nickname),
  case Status of
    null ->
      set_update_status(Server,User,<<"true">>);
    <<"null">> ->
      set_update_status(Server,User,<<"true">>);
    _ ->
      update_vcard_info(Server,User,LF,FN,NickName,D#vcard_temp.photo)
  end.

send_notifications_about_nick_change(Server,User) ->
  ChatAndIds = select_chat_for_update_nick(Server,User),
  change_user_updated_at(Server,User),
  lists:foreach(fun(El) ->
    {Chat} = El,
    M = notification_message_about_nick(User, Server, Chat),
    mod_groupchat_service_message:send_to_all(Chat,M) end, ChatAndIds).

send_notifications(ChatAndIds,User,Server) ->
  lists:foreach(fun(El) ->
    {Chat,_Hash} = El,
    M = notification_message(User, Server, Chat),
    mod_groupchat_service_message:send_to_all(Chat,M) end, ChatAndIds).

notification_message(User, Server, Chat) ->
  ChatJID = jid:replace_resource(jid:from_string(Chat),<<"Group">>),
  ByUserCard = mod_groupchat_users:form_user_card(User,Chat),
  Version = mod_groupchat_users:current_chat_version(Server,Chat),
  X = #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE, version = Version, sub_els = [ByUserCard]},
  By = #xmppreference{type = <<"mutable">>, sub_els = [ByUserCard]},
  SubEls = [X,By],
  ID = randoms:get_string(),
  OriginID = #origin_id{id = ID},
  NewEls = [OriginID | SubEls],
  #message{from = ChatJID, to = ChatJID, type = headline, id = ID, body = [], sub_els = NewEls, meta = #{}}.

notification_message_about_nick(User, Server, Chat) ->
  ChatJID = jid:replace_resource(jid:from_string(Chat),<<"Group">>),
  ByUserCard = mod_groupchat_users:form_user_card(User,Chat),
  Version = mod_groupchat_users:current_chat_version(Server,Chat),
  X = #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE, version = Version, sub_els = [ByUserCard]},
  By = #xmppreference{type = <<"mutable">>, sub_els = [ByUserCard]},
  SubEls = [X,By],
  ID = randoms:get_string(),
  OriginID = #origin_id{id = ID},
  NewEls = [OriginID | SubEls],
  #message{from = ChatJID, to = ChatJID, type = headline, id = ID, body = [], sub_els = NewEls, meta = #{}}.

get_chat_meta_nodeid(Server,Chat)->
  Node = <<"urn:xmpp:avatar:metadata">>,
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(nodeid)s from pubsub_node
    where host = %(Chat)s and node = %(Node)s")) of
    {selected,[]} ->
      no_avatar;
    {selected,[{Nodeid}]} ->
      Nodeid
  end.

get_chat_meta(Server,_Chat,Nodeid)->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(payload)s,@(itemid)s from pubsub_item
    where nodeid = %(Nodeid)d")) of
    {selected,[]} ->
      no_avatar;
    {selected,[{Payload,ItemID}]} ->
      {Payload,ItemID};
    _ ->
      no_avatar
  end.

make_chat_notification_message(Server,Chat,To) ->

  Nodeid = get_chat_meta_nodeid(Server,Chat),
  maybe_send(Server,Chat,Nodeid,To).

maybe_send(_Server,_Chat,no_avatar,_To) ->
  ok;
maybe_send(Server,Chat,Nodeid,To) ->
  Payload = get_chat_meta(Server,Chat,Nodeid),
  parse_and_send(Server,Chat,Payload,To).

parse_and_send(_Server,_Chat,no_avatar,_To) ->
  ok;
parse_and_send(_Server,Chat,{Payload,Nodeid},To) ->
  Metadata = xmpp:decode(fxml_stream:parse_element(Payload)),
  ChatJID = jid:remove_resource(jid:from_string(Chat)),
  Item = #ps_item{id = Nodeid, sub_els = [Metadata]},
  Node = <<"urn:xmpp:avatar:metadata">>,
  Items = #ps_items{node = Node, items = [Item]},
  Event = #ps_event{items = Items},
  M = #message{type = headline,
    from = ChatJID,
    to = To,
    id = randoms:get_string(),
    sub_els = [Event],
    meta = #{}
  },
  ejabberd_router:route(M).

get_photo_meta(Server,User,Chat)->
  Meta = get_image_metadata(Server, User, Chat),
  Result = case Meta of
    not_exist ->
      #avatar_meta{};
    not_filed ->
      #avatar_meta{};
    error ->
      #avatar_meta{};
    _ ->
      [{Hash,AvatarSize,AvatarType,_AvatarOldStyle}] = Meta,
      <<"image/",Type/binary>> = AvatarType,
      Url = get_url(Server),
      Name = <<Hash/binary, ".", Type/binary >>,
      AvatarUrl = <<Url/binary, "/", Name/binary>>,
      Info = #avatar_info{bytes = AvatarSize, type = AvatarType, id = Hash, url = AvatarUrl},
      #avatar_meta{info = [Info]}
  end,
  Result.

get_photo_data(Server,Hash,UserNode,_User,Chat) ->
  <<"urn:xmpp:avatar:data#", UserID/binary>> = UserNode,
  TypeRaw = get_avatar_type(Server, Hash, UserID,Chat),
  case TypeRaw of
    not_exist ->
      get_vcard_avatar(Server,Hash,UserID,UserNode,Chat);
    not_filed ->
      get_vcard_avatar(Server,Hash,UserID,UserNode,Chat);
    error ->
      error;
    _ ->
      <<"image/", Type/binary>> = TypeRaw,
      Path = gen_mod:get_module_opt(Server,mod_http_fileserver,docroot),
      Name = <<Hash/binary, ".", Type/binary >>,
      File = <<Path/binary, "/" , Name/binary>>,
      get_avatar_data(File,Hash,UserNode)
  end.

get_vcard_avatar(Server,Hash,UserID,UserNode,Chat) ->
  IsAnon = mod_groupchat_chats:is_anonim(Server,Chat),
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_users
  where chatgroup=%(Chat)s and id=%(UserID)s")) of
    {selected, []} ->
      not_exist;
    {selected, [<<>>]} ->
      not_filed;
    {selected,[{Username}]} when IsAnon == no ->
      get_vcard_avatar_data(Server,Username,Hash,UserNode);
    _ ->
      error
  end.

get_vcard_avatar_data(Server,Username,Hash,UserNode) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(image)s from groupchat_users_vcard
  where jid=%(Username)s")) of
    {selected, []} ->
      not_exist;
    {selected, [<<>>]} ->
      not_filed;
    {selected,[{Name}]} ->
      Path = gen_mod:get_module_opt(Server,mod_http_fileserver,docroot),
      File = <<Path/binary, "/" , Name/binary>>,
      get_avatar_data(File,Hash,UserNode);
    _ ->
      error
  end.

get_avatar_data(File,Hash,UserNode) ->
  case file:read_file(File) of
    {ok,Binary} ->
      Item = #ps_item{id = Hash, sub_els = [#avatar_data{data = Binary}]},
      Items = #ps_items{items = [Item], node = UserNode},
      #pubsub{items = Items};
    _ ->
      not_exist
  end.

get_lf(LF) ->
  case LF of
    undefined ->
      <<>>;
    _ ->
      Given = set_value(LF#vcard_name.given),
      Family = set_value(LF#vcard_name.family),
      << Given/binary," ",Family/binary >>
  end.

set_value(Value) ->
  case Value of
    undefined ->
      <<>>;
    _ ->
      Value
  end.

get_image_type(Server, Hash) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(file)s from groupchat_users_vcard
  where image=%(Hash)s")) of
    {selected, []} ->
      not_exist;
    {selected, [<<>>]} ->
      not_filed;
    {selected,[{Type}]} ->
      Type;
    _ ->
      error
  end.

get_avatar_type(Server, Hash, UserID,Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(avatar_type)s from groupchat_users
  where avatar_id=%(Hash)s and chatgroup=%(Chat)s and id=%(UserID)s")) of
    {selected, []} ->
      not_exist;
    {selected, [<<>>]} ->
      not_filed;
    {selected,[{Type}]} ->
      Type;
    _ ->
      error
  end.

get_image_id(Server, User, Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(avatar_id)s from groupchat_users
  where username=%(User)s and chatgroup = %(Chat)s")) of
    {selected, []} ->
      not_exist;
    {selected, [<<>>]} ->
      not_filed;
    {selected,[{ID}]} ->
      ID;
    _ ->
      error
  end.

get_image_metadata(Server, User, Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(avatar_id)s,@(avatar_size)d,@(avatar_type)s,@(avatar_url)s from groupchat_users
  where username=%(User)s and chatgroup = %(Chat)s")) of
    {selected, []} ->
      not_exist;
    {selected, [<<>>]} ->
      get_vcard_avatar(Server,Chat,User);
    {selected, [{_AvaID,0,null,null}]} ->
      get_vcard_avatar(Server,Chat,User);
    {selected, [{_AvaID,_AvaSize,null,null}]} ->
      get_vcard_avatar(Server,Chat,User);
    {selected, [{_AvaID,_AvaSize,_AvaType,null}]} ->
      get_vcard_avatar(Server,Chat,User);
    {selected, [{_AvaID,0,_AvaType,_AvaUrl}]} ->
      get_vcard_avatar(Server,Chat,User);
    {selected,Meta} ->
      Meta;
    _ ->
      error
  end.

get_image_metadata_by_id(Server, UserID, Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(avatar_id)s,@(avatar_size)d,@(avatar_type)s,@(avatar_url)s from groupchat_users
  where id=%(UserID)s and chatgroup = %(Chat)s")) of
    {selected, []} ->
      not_exist;
    {selected, [<<>>]} ->
      not_filed;
    {selected, [{_AvaID,0,null,null}]} ->
      not_filed;
    {selected, [{_AvaID,_AvaSize,null,null}]} ->
      not_filed;
    {selected, [{_AvaID,_AvaSize,_AvaType,null}]} ->
      not_filed;
    {selected, [{_AvaID,0,_AvaType,_AvaUrl}]} ->
      not_filed;
    {selected,Meta} ->
      Meta;
    _ ->
      error
  end.

get_vcard_avatar(Server,Chat,User) ->
  IsAnon = mod_groupchat_chats:is_anonim(Server,Chat),
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(image)s,@(hash)s,@(image_type)s from groupchat_users_vcard
  where jid=%(User)s")) of
    {selected,[{Image,Hash,ImageType}]} when Image =/= null andalso Hash =/= null andalso ImageType =/= null andalso IsAnon == no ->
      Path = gen_mod:get_module_opt(Server,mod_http_fileserver,docroot),
      File = <<Path/binary, "/" , Image/binary>>,
      case file:read_file(File) of
        {ok,Binary} ->
          Size = byte_size(Binary),
          UrlDir = get_url(Server),
          Url = <<UrlDir/binary, "/", File/binary>>,
          [{Hash,Size,ImageType,Url}];
        _ ->
          not_filed
      end;
    _ ->
      error
  end.

get_all_image_metadata(Server, Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(avatar_id)s,@(avatar_size)d,@(avatar_type)s,@(avatar_url)s from groupchat_users
  where chatgroup = %(Chat)s")) of
    {selected, []} ->
      not_exist;
    {selected, [<<>>]} ->
      not_filed;
    {selected, [{_AvaID,0,null,null}]} ->
      not_filed;
    {selected, [{_AvaID,_AvaSize,null,null}]} ->
      not_filed;
    {selected, [{_AvaID,_AvaSize,_AvaType,null}]} ->
      not_filed;
    {selected, [{_AvaID,0,_AvaType,_AvaUrl}]} ->
      not_filed;
    {selected,Meta} ->
      Meta;
    _ ->
      error
  end.

update_avatar(Server, User, Chat, AvatarID, AvatarType, AvatarSize, AvatarUrl) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set avatar_size = %(AvatarSize)d,
    avatar_type = %(AvatarType)s,
    avatar_id = %(AvatarID)s,
    avatar_url = %(AvatarUrl)s
  where username = %(User)s and chatgroup = %(Chat)s ")).

update_metadata(Server, User, AvatarID, AvatarType, AvatarSize, AvatarUrl) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set avatar_size = %(AvatarSize)d,
    avatar_type = %(AvatarType)s,
    avatar_url = %(AvatarUrl)s,
    avatar_id = %(AvatarID)s
  where username = %(User)s and parse_avatar = 'yes' ")).

update_parse_avatar_option(Server,User,Chat,Value) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set parse_avatar = %(Value)s
  where username = %(User)s and chatgroup = %(Chat)s ")).

update_metadata_user_put(Server, User, AvatarID, AvatarType, AvatarSize, Chat) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set avatar_size = %(AvatarSize)d,
    avatar_type = %(AvatarType)s,
    avatar_id = %(AvatarID)s,
    parse_vcard= (now() at time zone 'utc')
  where username = %(User)s and chatgroup = %(Chat)s ")).

update_metadata_user_put_by_id(Server, UserID, AvatarID, AvatarType, AvatarSize, Chat) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set avatar_size = %(AvatarSize)d,
    avatar_type = %(AvatarType)s,
    avatar_id = %(AvatarID)s,
    parse_vcard= (now() at time zone 'utc')
  where id = %(UserID)s and chatgroup = %(Chat)s ")).

update_data_user_put(Server, UserID, Data, Hash, Chat) ->
  Path = gen_mod:get_module_opt(Server,mod_http_fileserver,docroot),
  UrlDir = get_url(Server),
  TypeRaw = eimp:get_type(Data),
  Type = atom_to_binary(TypeRaw, latin1),
  Name = <<Hash/binary, ".", Type/binary >>,
  Url = <<UrlDir/binary, "/", Name/binary>>,
  File = <<Path/binary, "/" , Name/binary>>,
  file:write_file(binary_to_list(File), Data),
  OldMeta = get_image_metadata_by_id(Server, UserID, Chat),
  ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set
    avatar_id = %(Hash)s,
    parse_avatar = 'no',
    avatar_url = %(Url)s
  where id = %(UserID)s and chatgroup = %(Chat)s ")),
  check_old_meta(Server, OldMeta).

set_update_status(Server,Jid,Status) ->
  case ?SQL_UPSERT(Server, "groupchat_users_vcard",
    ["fullupdate=%(Status)s",
      "!jid=%(Jid)s"]) of
    ok ->
      ok;
    _Err ->
      {error, db_failure}
  end.

update_id_in_chats(Server,User,Hash,AvatarType,AvatarSize,AvatarUrl) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set avatar_id = %(Hash)s,
    avatar_url = %(AvatarUrl)s, avatar_size = %(AvatarSize)d, avatar_type = %(AvatarType)s, user_updated_at = (now() at time zone 'utc')
    where username = %(User)s and (avatar_id != %(Hash)s or avatar_id is null) and
    chatgroup not in (select jid from groupchats where anonymous = 'incognito')
     and parse_avatar = 'yes' ")) of
    {updated,Num} when Num > 0 ->
      ok;
    _ ->
      ok
  end.

update_avatar_url_chats(Server,User,Hash,_AvatarType,AvatarSize,AvatarUrl) ->
  ChatsToSend = select_chat_for_update(Server,User,AvatarUrl,Hash,AvatarSize),
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set avatar_url = %(AvatarUrl)s, user_updated_at = (now() at time zone 'utc')
    where username = %(User)s and (avatar_url != %(AvatarUrl)s or avatar_url is null) and avatar_id = %(Hash)s and avatar_size = %(AvatarSize)d and
    chatgroup not in (select jid from groupchats where anonymous = 'incognito')
     and parse_avatar = 'yes' ")) of
    {updated,Num} when Num > 0 andalso bit_size(AvatarUrl) > 0 ->
      send_notifications(ChatsToSend,User,Server),
      ok;
    _ ->
      ok
  end.

select_chat_for_update(Server,User,AvatarUrl,Hash,AvatarSize) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(chatgroup)s,@(avatar_url)s from groupchat_users
    where username = %(User)s and (avatar_url != %(AvatarUrl)s or avatar_url is null) and avatar_id = %(Hash)s and avatar_size = %(AvatarSize)d and
    chatgroup not in (select jid from groupchats where anonymous = 'incognito')
     and parse_avatar = 'yes' ")) of
    {selected, Chats} ->
      Chats;
    _ ->
      []
  end.

select_chat_for_update_nick(Server,User) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(chatgroup)s from groupchat_users
    where username = %(User)s and nickname='' and
    chatgroup not in (select jid from groupchats where anonymous = 'incognito')
    ")) of
    {selected, Chats} ->
      Chats;
    _ ->
      []
  end.

change_user_updated_at(Server,User) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set user_updated_at = (now() at time zone 'utc')
    where username = %(User)s and nickname='' and
    chatgroup not in (select jid from groupchats where anonymous = 'incognito')
    ")).

update_vcard_info(Server,User,GIVENFAMILYRaw,FNRaw,NICKNAMERaw,Photo) ->
  NICKNAME = trim(NICKNAMERaw),
  FN = trim(FNRaw),
  GIVENFAMILY = trim(GIVENFAMILYRaw),
  NickLength = string:length(NICKNAME),
  FNLength = string:length(FN),
  GivenLength = string:length(GIVENFAMILY),
  {Hash,Type} = get_hash_and_type(Photo),
  Filename = get_name_from_hash_and_type(Photo),
  case NickLength of
    _ when NickLength > 0 orelse FNLength > 0 orelse GivenLength > 0 ->
      case  ejabberd_sql:sql_query(
        Server,
        ?SQL("update groupchat_users_vcard set givenfamily=%(GIVENFAMILY)s, fn=%(FN)s, nickname=%(NICKNAME)s, image=%(Filename)s, hash=%(Hash)s, image_type=%(Type)s
    where jid = %(User)s and (givenfamily !=%(GIVENFAMILY)s or fn!=%(FN)s or nickname!=%(NICKNAME)s or image!=%(Filename)s)")) of
        {updated,0} ->
          ?SQL_UPSERT(Server, "groupchat_users_vcard",
            ["!jid=%(User)s",
              "givenfamily=%(GIVENFAMILY)s",
              "fn=%(FN)s",
              "hash=%(Hash)s",
              "nickname=%(NICKNAME)s",
              "image=%(Filename)s",
              "image_type=%(Type)s"
            ]),
          handle_vcard_photo(Server,Photo);
        {updated,Num} when Num > 0 ->
          handle_vcard_photo(Server,Photo),
          send_notifications_about_nick_change(Server,User),
          ok;
        _ ->
          ok
      end;
    _  ->
      ok
  end.

trim(String) ->
  case String of
    _ when String =/= undefined ->
      string:trim(String);
    _ ->
      <<"">>
  end.

check_old_meta(_Server,false)->
  ok;
check_old_meta(_Server,not_exist)->
  ok;
check_old_meta(_Server,not_filed)->
  ok;
check_old_meta(_Server,error)->
  ok;
check_old_meta(Server,Meta)->
  lists:foreach(fun(MetaEl) ->
  {Hash,_AvatarSize,AvatarType,_AvatarUrl} = MetaEl,
    case Hash of
      null ->
        ok;
      _ when AvatarType =/= null ->
        check_and_delete(Server, Hash, AvatarType);
      _ ->
        ok
    end end, Meta).

check_and_delete(Server, Hash, AvatarType) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(avatar_id)s from groupchat_users
    where avatar_id = %(Hash)s")) of
    {selected,[]} ->
      delete_file(Server, Hash, AvatarType);
    _ ->
      not_delete
  end.

delete_file(Server, Hash, AvatarType) ->
  Path = gen_mod:get_module_opt(Server,mod_http_fileserver,docroot),
  <<"image/",Type/binary>> = AvatarType,
  Name = <<Hash/binary, ".", Type/binary >>,
  File = <<Path/binary, "/" , Name/binary>>,
  file:delete(File).

get_vcard(LUser,Server) ->
  Chat = jid:to_string(jid:make(LUser,Server)),
  {selected,[{Name,Privacy,Index,Membership,Desc,_Message,_ContactList,_DomainList,ParentChat,Status}]} =
    mod_groupchat_chats:get_all_information_chat(Chat,Server),
  Parent = define_parent_chat(ParentChat),
  {selected,_Ct,MembersC} = mod_groupchat_sql:count_users(Server,Chat),
  Members = list_to_binary(MembersC),
  HumanStatus = case ParentChat of
                  <<"0">> ->
                    mod_groupchat_chats:define_human_status(Server, Chat, Status);
                  _ ->
                    <<"Private chat">>
                end,
  Avatar = get_avatar_from_pubsub(Chat,Server),
  [xmpp:encode(#vcard_temp{
    jabberid = Chat,
    nickname = Name,
    desc = Desc,
    index = Index,
    privacy = Privacy,
    membership = Membership,
    parent = Parent,
    status = HumanStatus,
    photo = Avatar,
    members = Members})].


define_parent_chat(<<"0">>) ->
  undefined;
define_parent_chat(ParentChat) ->
  ParentChat.

get_payload_from_pubsub(Chat,LServer,Node) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(payload)s from pubsub_item where nodeid = (select nodeid from pubsub_node where host = %(Chat)s and node = %(Node)s)")) of
    {selected,[{Payload}]} ->
      Payload;
    _ ->
      undefined
  end.

get_avatar_from_pubsub(Chat,LServer) ->
  Data = get_payload_from_pubsub(Chat,LServer,<<"urn:xmpp:avatar:data">>),
  case Data of
    undefined ->
      undefined;
    _ ->
      case xmpp:decode(fxml_stream:parse_element(Data)) of
        #avatar_data{data = Binary} ->
          get_type_and_create_photo_element(Chat,LServer,Binary);
        _ ->
          undefined
      end
  end.

get_type_and_create_photo_element(Chat,LServer,Binary) ->
  MetaData = get_payload_from_pubsub(Chat,LServer,<<"urn:xmpp:avatar:metadata">>),
  case MetaData of
    undefined ->
      undefined;
    _ ->
      case xmpp:decode(fxml_stream:parse_element(MetaData)) of
        #avatar_meta{info = [#avatar_info{type = Type}]} ->
          #vcard_photo{binval = Binary, type = Type};
        _ ->
          undefined
      end
  end.

handle_vcard_photo(_Server, undefined) ->
  ok;
handle_vcard_photo(Server,Photo) ->
  #vcard_photo{binval = Binval} = Photo,
  Path = gen_mod:get_module_opt(Server,mod_http_fileserver,docroot),
  Name = get_name_from_hash_and_type(Photo),
  Len = string:length(Name),
  case Name of
    _ when Len > 0 ->
      File = <<Path/binary, "/" , Name/binary>>,
      file:write_file(binary_to_list(File), Binval);
    _ ->
      ok
  end.

get_name_from_hash_and_type(undefined) ->
  <<>>;
get_name_from_hash_and_type(Photo) ->
  {Hash,TypeRaw} = get_hash_and_type(Photo),
  if
    Hash == <<>> orelse TypeRaw == <<>> ->
      <<>>;
    true ->
      <<"image/", Type/binary>> = TypeRaw,
      <<Hash/binary,$., Type/binary >>
  end.

get_hash(Binval) ->
  H = iolist_to_binary([io_lib:format("~2.16.0B", [X])
    || X <- binary_to_list(
      crypto:hash(sha, Binval))]),
  list_to_binary(string:to_lower(binary_to_list(H))).

get_hash_and_type(undefined) ->
  {<<>>,<<>>};
get_hash_and_type(Photo) ->
  #vcard_photo{type = TypeRaw0, binval = Binval} = Photo,
  Hash = case Binval of
           undefined -> <<>>;
           _ -> get_hash(Binval)
         end,
  TypeRaw = case TypeRaw0 of
               undefined -> <<>>;
               _ -> TypeRaw0
             end,
  {Hash,TypeRaw}.

get_url(Host) ->
  Url = gen_mod:get_module_opt(Host, ?MODULE, get_url),
  mod_http_upload:expand_host(Url, Host).

create_p2p_avatar(LServer,Chat,AvatarID1,AvatarType1,AvatarID2,AvatarType2)
  when is_binary(AvatarID1) == true andalso is_binary(AvatarID2) == true
  andalso is_binary(AvatarType1) == true andalso is_binary(AvatarType2) ->
  L1 = string:length(AvatarID1),
  L2 = string:length(AvatarID2),
  case L1 of
    0 ->
      ok;
    _ when L2 > 0 ->
      <<"image/", Type1/binary>> = AvatarType1,
      <<"image/", Type2/binary>> = AvatarType2,
      Path = gen_mod:get_module_opt(LServer,mod_http_fileserver,docroot),
      Name1 = <<AvatarID1/binary, ".", Type1/binary >>,
      Name2 = <<AvatarID2/binary, ".", Type2/binary >>,
      File1 = <<Path/binary, "/" , Name1/binary>>,
      File2 = <<Path/binary, "/" , Name2/binary>>,
      Filename = nick_generator:merge_avatar(File1,File2,Path),
      File = <<Path/binary, "/" , Filename/binary>>,
      case file:read_file(File) of
        {ok, F} ->
          publish_avatar(Chat, F, Filename);
        _ ->
          ok
      end;
    _ ->
      ok
  end;
create_p2p_avatar(_LServer,_Chat,_AvatarID1,_AvatarType1,_AvatarID2,_AvatarType2) ->
  ok.

%%put_avatar_into_pubsub(Chat,Data,Resource) ->
%%  TypeRaw = eimp:get_type(Data),
%%  Size = byte_size(Data),
%%  HashID = get_hash(Data),
%%  Type = atom_to_binary(TypeRaw, latin1),
%%  ImageType = <<"image/",Type/binary>>,
%%  AvatarInfo = #avatar_info{type = ImageType, bytes = Size, id = HashID},
%%  AvatarData = #avatar_data{data = Data},
%%  AvatarMeta = #avatar_meta{info = [AvatarInfo]},
%%  To = jid:from_string(Chat),
%%  FromGroupJID = jid:replace_resource(To,Resource),
%%  AvatarItems = #ps_item{id = HashID, sub_els = [xmpp:encode(AvatarData)]},
%%  MetaItems = #ps_item{id = HashID, sub_els = [xmpp:encode(AvatarMeta)]},
%%  PublishData = #pubsub{publish = #ps_publish{node = ?NS_AVATAR_DATA, items = [AvatarItems]}},
%%  PublishMetaData = #pubsub{publish = #ps_publish{node = ?NS_AVATAR_METADATA, items = [MetaItems]}},
%%  IQData = #iq{from = FromGroupJID,to = To,id = randoms:get_string(),type = set, sub_els = [PublishData], meta = #{}},
%%  IQMeta = #iq{from = FromGroupJID,to = To,id = randoms:get_string(),type = set, sub_els = [PublishMetaData], meta = #{}},
%%  Res = mod_pubsub:iq_sm(IQData),
%%  case Res of
%%    #iq{type = result} ->
%%      mod_pubsub:iq_sm(IQMeta);
%%    _ ->
%%      ok
%%  end .


publish_avatar(Chat, Data, FileName) when is_binary(Chat) ->
  publish_avatar(jid:from_string(Chat), Data, FileName);

publish_avatar(#jid{lserver = Server} = Chat, Data, FileName)->
  JIDinURL = gen_mod:get_module_opt(Server,mod_http_upload,jid_in_url),
  UserStr = make_user_string(Chat, JIDinURL),
  DocRoot1 = gen_mod:get_module_opt(Server, mod_http_upload, docroot),
  DocRoot2 = mod_http_upload:expand_home(str:strip(DocRoot1, right, $/)),
  DocRoot3 = mod_http_upload:expand_host(DocRoot2, Server),
  DocRoot = filename:absname(DocRoot3),
  AvatarDir = <<DocRoot/binary,$/,UserStr/binary,$/,"avatar">>,
  FullPath = filename:join(AvatarDir,FileName),
  case do_store_file(FullPath, Data, undefined, undefined) of
    ok ->
      UrlOpt =  case gen_mod:get_module_opt(Server,mod_http_upload,get_url) of
                  undefined ->
                    gen_mod:get_module_opt(Server,mod_http_upload,put_url);
                  Val -> Val
                end,
      Url = misc:expand_keyword(<<"@HOST@">>, str:strip(UrlOpt, right, $/), Server),
      AvatarUrl = <<Url/binary, "/",UserStr/binary,$/,"avatar",$/,FileName/binary>>,
      Size = byte_size(Data),
      HashID = get_hash(Data),
      Type = lists:last(binary:split(FileName,<<".">>)),
      ImageType = <<"image/",Type/binary>>,

      AvatarInfo = #avatar_info{type = ImageType, bytes = Size, id = HashID, url = AvatarUrl},
      AvatarMeta = #avatar_meta{info = [AvatarInfo]},
      MetaItems = #ps_item{id = HashID, sub_els = [xmpp:encode(AvatarMeta)]},
      PublishMetaData = #pubsub{publish = #ps_publish{node = ?NS_AVATAR_METADATA, items = [MetaItems]}},

      IQMeta = #iq{from = jid:replace_resource(Chat,<<"Group">>),
        to = jid:replace_resource(Chat,<<>>),
        id = randoms:get_string(),
        type = set,
        sub_els = [PublishMetaData],
        meta = #{}},
      mod_pubsub:iq_sm(IQMeta);
    Err ->
      Err
  end;

publish_avatar(_, _, _) ->
  ok.

%% block from mod_http_upload

-spec make_user_string(jid(), sha1 | node) -> binary().
make_user_string(#jid{luser = U, lserver = S}, sha1) ->
  str:sha(<<U/binary, $@, S/binary>>);
make_user_string(#jid{luser = U}, node) ->
  replace_special_chars(U).

-spec replace_special_chars(binary()) -> binary().
replace_special_chars(S) ->
  re:replace(S, <<"[^\\p{Xan}_.-]">>, <<$_>>,
    [unicode, global, {return, binary}]).

-spec do_store_file(file:filename_all(), binary(),
    integer() | undefined,
    integer() | undefined)
      -> ok | {error, term()}.
do_store_file(Path, Data, FileMode, DirMode) ->
  try
    ok = filelib:ensure_dir(Path),
    {ok, Io} = file:open(Path, [write, exclusive, raw]),
    Ok = file:write(Io, Data),
    ok = file:close(Io),
    if is_integer(FileMode) ->
      ok = file:change_mode(Path, FileMode);
      FileMode == undefined ->
        ok
    end,
    if is_integer(DirMode) ->
      RandDir = filename:dirname(Path),
      UserDir = filename:dirname(RandDir),
      ok = file:change_mode(RandDir, DirMode),
      ok = file:change_mode(UserDir, DirMode);
      DirMode == undefined ->
        ok
    end,
    ok = Ok % Raise an exception if file:write/2 failed.
  catch
    _:{badmatch, {error, Error}} ->
      {error, Error};
    _:Error ->
      {error, Error}
  end.
%% end block