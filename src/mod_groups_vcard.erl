%%%-------------------------------------------------------------------
%%% File    : mod_groups_vcard.erl
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

-module(mod_groups_vcard).
-behavior(gen_mod).
-author('andrey.gagarin@redsolution.com').
-compile([{parse_transform, ejabberd_sql_pt}]).
-export([
  get_vcard/0,
  give_vcard/2,
  handle/1,
  iq_last/0,
  handle_pubsub/1,
  handle_request/1,
  change_nick_in_vcard/3,
  update_parse_avatar_option/4,
  get_photo_meta/3,
  get_all_image_metadata/2,
  maybe_delete_file/2,
  delete_group_avatar_file/1,
  make_chat_notification_message/3,
  get_pubsub_meta/0,
  handle_avatar_data/4,
  handle_avatar_meta/3,
  get_image_id/3,
  get_vcard/2,
  update_avatar/7,
  create_p2p_avatar/4,
  handle_iq/1,
  get_vcard_avatar_hash/2,
  set_update_status/3,
  update_chat_avatar_id/3
]).
-export([publish_avatar/3, make_http_request/6, store_user_avatar_file/3]).
-export([maybe_update_avatar/3]).
%% gen_mod behavior
-export([start/2, stop/1, mod_options/1, depends/2]).
-include("ejabberd.hrl").
-include("ejabberd_sql_pt.hrl").
-include("logger.hrl").
-include("xmpp.hrl").

-define(RESOURCE, <<"Group">>).
-define(AVATARS_PATH, <<"groups/mavatars">>).
-define(AVATAR_NAME_SALT, atom_to_binary(erlang:get_cookie(),latin1)).

start(_Host, _) ->
  ok.

stop(_Host) ->
  ok.

mod_options(_Host) -> [] .

depends(_, _) ->
  [{mod_http_upload, hard}].

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
    xmpp:make_error(Iq, xmpp:err_bad_request())
  end.

handle_decoded_request(Iq) ->
  #iq{id = Id,type = Type,lang = Lang, meta = Meta, from = From,to = To,sub_els = Decoded} = Iq,
  Pubsub = lists:keyfind(pubsub,1,Decoded),
  #pubsub{items = Items} = Pubsub,
  #ps_items{node = Node} = Items,
  Server = To#jid.lserver,
  UserJid = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  NewIq = #iq{from = To,to = To,id = Id,type = Type,lang = Lang,meta = Meta,sub_els = Decoded},
  Result = case Node of
    <<"urn:xmpp:avatar:data">> ->
      mod_pubsub:iq_sm(NewIq);
    <<"urn:xmpp:avatar:metadata">> ->
      mod_pubsub:iq_sm(NewIq);
    <<"http://jabber.org/protocol/nick">> ->
      mod_pubsub:iq_sm(NewIq);
    _ ->
      handle_decoded_request(Node, UserJid, Chat, Server, Items, Iq)
  end,
  Result#iq{from = To, to = From}.

handle_decoded_request(<<"urn:xmpp:avatar:data#",UserId/binary>> = Node,
    User, Chat, Server, Items, Iq) ->
  TargetUser = case UserId of
                 <<>> ->
                   User;
                 _ ->
                   mod_groups_users:get_user_by_id(Server , Chat, UserId)
            end,
  #ps_items{items = PSItems} = Items,
  case lists:keyfind(ps_item, 1, PSItems)of
    #ps_item{id = Hash} ->
      Data = get_avatar_data(Server, Hash, TargetUser, Node, Chat),
      check_data(Data,Iq);
    _ ->
      xmpp:make_error(Iq, xmpp:err_bad_request())
  end;
handle_decoded_request(<<"urn:xmpp:avatar:metadata#",UserId/binary>>,
    User, Chat, Server, Items, Iq) ->
  TargetUser = case UserId of
              <<>> ->
                User;
              _ ->
                mod_groups_users:get_user_by_id(Server , Chat, UserId)
            end,
  AvatarMeta = get_photo_meta(Server, TargetUser, Chat),
  case AvatarMeta of
    %% is not empty
    #avatar_meta{info = [#avatar_info{id = Hash}]} ->
      #avatar_meta{info = [#avatar_info{id = Hash}]} = AvatarMeta,
      #ps_items{items = PSItems} = Items,
      RItem = #ps_item{id = Hash, sub_els = [AvatarMeta]},
      RItems = #ps_items{items = [RItem], node = <<"urn:xmpp:avatar:metadata#">>},
      IqResult = xmpp:make_iq_result(Iq,#pubsub{items = RItems}),
      case lists:keyfind(ps_item, 1, PSItems) of
        false ->
          IqResult;
        #ps_item{id = Hash} ->
          IqResult;
        _ ->
          xmpp:make_error(Iq,xmpp:err_item_not_found())
      end;
    _ ->
      xmpp:make_error(Iq,xmpp:err_item_not_found())
  end;
handle_decoded_request(_, _, _, _, _, Iq) ->
  xmpp:make_error(Iq,xmpp:err_feature_not_implemented()).

check_data(not_exist,Iq) ->
  xmpp:make_error(Iq,xmpp:err_item_not_found());
check_data(not_filed,Iq) ->
  xmpp:make_error(Iq,xmpp:err_item_not_found());
check_data(error,Iq) ->
  xmpp:make_error(Iq,xmpp:err_internal_server_error());
check_data(Data,Iq) ->
  xmpp:make_iq_result(Iq,Data).

handle_pubsub(#iq{id = Id,type = Type,lang = Lang, meta = Meta, from = From, to = To,sub_els = Decoded} = Iq) ->
  FromGroupJID = jid:replace_resource(To,?RESOURCE),
  NewIq = #iq{from = FromGroupJID,to = To,id = Id,type = Type,lang = Lang,meta = Meta,sub_els = Decoded},
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  Permission = mod_groups_restrictions:is_permitted(<<"change-group">>,User,Chat),
  CanChangeAva = mod_groups_restrictions:is_permitted(<<"change-users">>,User,Chat),
  Pubsub = lists:keyfind(pubsub,1,Decoded),
  #pubsub{publish = Publish} = Pubsub,
  #ps_publish{node = Node, items = Items} = Publish,
  Item = lists:keyfind(ps_item,1,Items),
  UserId = mod_groups_users:get_user_id(Server,User,Chat),
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
                     from = jid:replace_resource(To,?RESOURCE),
                     to = jid:remove_resource(From),
                     id = randoms:get_string(),
                     sub_els = [Event],
                     meta = #{}
                   },
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
               SomeUser = mod_groups_users:get_user_by_id(Server,Chat,SomeUserId),
               case mod_groups_restrictions:validate_users(Server,Chat,User,SomeUser) of
                 ok when SomeUser =/= none ->
                   #ps_item{id = ItemId,sub_els = [Sub]} = Item,
                   #avatar_data{data = Data} = xmpp:decode(Sub),
                   update_data_user_put(Server, SomeUserId, Data, ItemId,Chat),
                   xmpp:make_iq_result(Iq);
                 _ ->
                   xmpp:make_error(Iq,xmpp:err_not_allowed(<<"You are not allowed to do it">>,Lang))
               end;
             <<"urn:xmpp:avatar:metadata#",SomeUserId/binary>> when CanChangeAva == true ->
               SomeUser = mod_groups_users:get_user_by_id(Server,Chat,SomeUserId),
               #ps_item{id = IdItem} = Item,
               case IdItem of
                 <<>> when SomeUser =/= none->
                   case mod_groups_restrictions:validate_users(Server,Chat,User,SomeUser) of
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
                       xmpp:make_error(Iq,xmpp:err_not_allowed(<<"You are not allowed to do it">>,Lang))
                   end;
                 _  when SomeUser =/= none ->
                   case mod_groups_restrictions:validate_users(Server,Chat,User,SomeUser) of
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
                         from = jid:replace_resource(To,?RESOURCE),
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
                       xmpp:make_error(Iq,xmpp:err_not_allowed(<<"You are not allowed to do it">>, Lang))
                   end;
                 _ ->
                   xmpp:make_error(Iq,xmpp:err_not_allowed(<<"You are not allowed to do it">>, Lang))
               end;
             _ ->
               xmpp:make_error(Iq,xmpp:err_not_allowed(<<"You are not allowed to do it">>, Lang))
           end,
  case Result of
    #iq{type = result} when Node == <<"urn:xmpp:avatar:metadata">> ->
      ejabberd_hooks:run(groupchat_avatar_changed,Server,[Server, Chat, User]);
    _ ->
      ok
  end,
  Result#iq{from = To, to = From}.

notificate_all(ChatJID,Message) ->
  Chat = jid:to_string(jid:remove_resource(ChatJID)),
  FromChat = jid:replace_resource(ChatJID,?RESOURCE),
  AllUsers = mod_groups_users:users_to_send(ChatJID#jid.lserver,Chat),
  mod_groups_messages:send_message(Message,AllUsers,FromChat).

change_nick_in_vcard(LUser,LServer,NewNick) ->
  OldVcard = hd(mod_vcard:get_vcard(LUser,LServer)),
  #vcard_temp{photo = OldPhoto} = xmpp:decode(OldVcard),
  NewVcard = #vcard_temp{photo = OldPhoto, nickname = NewNick},
  Jid = jid:make(LUser,LServer,<<>>),
  IqSet = #iq{from = Jid, type = set, id = randoms:get_string(), sub_els = [NewVcard]},
  mod_vcard:vcard_iq_set(IqSet).

iq_last() ->
#xmlel{name = <<"query">>, attrs = [{<<"xmlns">>,<<"jabber:iq:last">>},{<<"seconds">>,<<"0">>}]}.

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
  #iq{type = get, id = randoms:get_string(),
    sub_els = [#pubsub{items = #ps_items{node = <<"urn:xmpp:avatar:metadata">>}}]
  }.

get_pubsub_data(ID) ->
  #iq{type = get, id = randoms:get_string(),
    sub_els = [
      #pubsub{
        items = #ps_items{
          node = <<"urn:xmpp:avatar:data">>,
          items = [#ps_item{id = ID}]
        }
      }
    ]}.

-spec maybe_update_avatar(jid(), jid(), binary()) -> any().
maybe_update_avatar(User, Chat, Server) ->
  SUser = jid:to_string(jid:remove_resource(User)),
  SChat = jid:to_string(jid:remove_resource(Chat)),
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(parse_avatar)s from groupchat_users
    where username = %(SUser)s and chatgroup  = %(SChat)s and
    chatgroup not in (select jid from groupchats where anonymous = 'incognito')")) of
    {selected, [{<<"yes">>}]} ->
      From = jid:replace_resource(Chat, ?RESOURCE),
      ejabberd_router:route(From,jid:remove_resource(User), mod_groups_vcard:get_pubsub_meta());
    _ ->
      ok
  end.

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

handle_avatar_meta(ChatJID,UserJID,#avatar_meta{info = AvatarINFO}) ->
  LServer = ChatJID#jid.lserver,
  User = jid:to_string(jid:remove_resource(UserJID)),
  Chat = jid:to_string(jid:remove_resource(ChatJID)),
  case AvatarINFO of
    [] ->
      OldMeta = get_image_metadata(LServer, User, Chat),
      update_id_in_chats(LServer, User, <<>>, <<>>, 0, <<>>),
      maybe_delete_file(LServer, OldMeta);
    [#avatar_info{bytes = Size, id = ID, type = Type0, url = Url}] ->
      %% set default type
      Type = case Type0 of <<>> -> <<"image/png">>; _-> Type0 end,
      %% todo: get rid of the dependency on the file type
      OldMeta = get_image_metadata(LServer, User, Chat),
      case OldMeta of
        [{ID,_Size,_ImageType,_Url}] ->
          ok;
        _ ->
%%          check_old_meta(LServer, OldMeta),
          update_id_in_chats(LServer,User,ID,Type,Size,<<>>),
          maybe_delete_file(LServer, OldMeta),
          case Url of
            <<>> ->
              ejabberd_router:route(ChatJID,UserJID,get_pubsub_data(ID));
            _ ->
              download_user_avatar(LServer, User, ID, Type, Size, Url)
          end
      end;
    _ ->
      ok
  end;
handle_avatar_meta(_F,_T,false) ->
  ok.

handle_avatar_data(ChatJID,UserJID,ID,#avatar_data{data = Data}) ->
  Server = ChatJID#jid.lserver,
  User = jid:to_string(jid:remove_resource(UserJID)),
  Chat = jid:to_string(jid:remove_resource(ChatJID)),
  Meta = get_image_metadata(Server, User, Chat),
  case Meta of
    [{ID,AvaSize,AvaType,_AvaUrl}] ->
      store_user_avatar(Server, User, ID, AvaType, AvaSize, Data);
    _ ->
      ok
  end;
handle_avatar_data(_C,_U,_I,false) ->
  ok.

update_vcard(Server,User,D,_Chat) ->
  FN = set_value(D#vcard_temp.fn),
  Name = get_lf(D#vcard_temp.n),
  NickName = set_value(D#vcard_temp.nickname),
  Photo = D#vcard_temp.photo,
  update_vcard_info(Server, User, Name, FN, NickName, Photo).

download_user_avatar(Server, User, ID, Type, Size, Url) ->
  ?DEBUG("Download user avatar: ~p ~p ~n",[User, Url]),
  spawn(?MODULE,make_http_request,[Server, User, ID, Type, Size, Url]).

make_http_request(Server, User, ID, Type, Size, Url) ->
  Options = [{sync, false},{stream, self}],
  HttpOptions = [{timeout, 5000}, {autoredirect, false}], % 5 seconds.
  httpc:request(get, {binary_to_list(Url), []}, HttpOptions, Options),
  http_response_process(Server, User, ID, Type, Size, <<>>).

http_response_process(Server, User, ID, Type, Size, Data) ->
  receive
    {http, {_RequestId, stream_start, _Headers}} ->
      http_response_process(Server, User, ID, Type, Size, Data);
    {http, {_RequestId, stream, BinBodyPart}} ->
      NewData = <<Data/binary,BinBodyPart/binary>>,
      CurrSize = byte_size(NewData),
      if
        CurrSize > Size ->
          ?ERROR_MSG("download error: file too large",[]),
          exit(normal);
        true ->
          http_response_process(Server, User, ID, Type, Size, NewData)
      end;
    {http, {_RequestId, stream_end, _Headers}} ->
      store_user_avatar(Server, User, ID, Type, Size, Data),
      exit(normal);
    E ->
      ?ERROR_MSG("User avatar download error: ~p~n",[E]),
      exit(normal)
  after
    60000 -> exit(normal)
  end.

store_user_avatar(Server, User, ID, AvaType, AvaSize, Data) ->
  FileName = make_user_string(jid:from_string(User), salt),
  DocRoot = get_docroot(Server),
  FullPath = filename:join([DocRoot, ?AVATARS_PATH, FileName]),
  case do_store_file(FullPath, Data, undefined, undefined) of
    ok ->
      Url = get_root_url(Server),
      AvatarUrl = <<Url/binary, $/,?AVATARS_PATH/binary,$/,FileName/binary,"?v=",ID/binary>>,
      update_avatar_url_chats(Server,User,ID,AvaType,AvaSize,AvatarUrl),
      set_update_status(Server,User,<<"false">>);
    Err ->
      ?ERROR_MSG("Error storing user avatar: ~p ~p ~p",[User, FileName, Err]),
      Err
  end.

store_user_avatar_file(Server, Data, UserID) ->
  ID = get_hash(Data),
  Type = atom_to_binary(eimp:get_type(Data), latin1),
  Size = byte_size(Data),
  Salt = ?AVATAR_NAME_SALT,
  FileName = str:sha(<<UserID/binary, Salt/binary>>),
  DocRoot = get_docroot(Server),
  FullPath = filename:join([DocRoot, ?AVATARS_PATH, FileName]),
  case do_store_file(FullPath, Data, undefined, undefined) of
    ok ->
      Url = get_root_url(Server),
      AvatarUrl = <<Url/binary, $/,?AVATARS_PATH/binary,$/,FileName/binary,"?v=",ID/binary>>,
      #avatar_info{bytes = Size, id = ID, type = <<"image/",Type/binary>>, url = AvatarUrl};
    Err ->
      Err
  end.

%%send_notifications_about_nick_change(Server,User, OldNickname) ->
%%  ChatAndIds = select_chat_for_update_nick(Server,User),
%%  lists:foreach(fun(El) ->
%%    {Chat} = El,
%%    M = notification_message_about_nick(User, Server, Chat, OldNickname),
%%    mod_groups_system_message:send_to_all(Chat,M) end, ChatAndIds).

send_notifications(ChatAndIds,User,Server) ->
  lists:foreach(fun(El) ->
    {Chat,_Hash} = El,
    M = notification_message(User, Server, Chat),
    mod_groups_system_message:send_to_all(Chat,M) end, ChatAndIds).

notification_message(User, Server, Chat) ->
  ChatJID = jid:replace_resource(jid:from_string(Chat),?RESOURCE),
  ByUserCard = mod_groups_users:form_user_card(User,Chat),
  Version = mod_groups_users:current_chat_version(Server,Chat),
  X = #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE, version = Version, sub_els = [ByUserCard]},
  By = #xmppreference{type = <<"mutable">>, sub_els = [ByUserCard]},
  SubEls = [X,By],
  ID = randoms:get_string(),
  OriginID = #origin_id{id = ID},
  NewEls = [OriginID | SubEls],
  #message{from = ChatJID, to = ChatJID, type = headline, id = ID, body = [], sub_els = NewEls, meta = #{}}.

%%notification_message_about_nick(User, Server, Chat, OldNick) ->
%%  UserCard = mod_groups_users:form_user_card(User, Chat),
%%  NewNick = UserCard#xabbergroupchat_user_card.nickname,
%%  MsgTxt = <<OldNick/binary," is now known as ",NewNick/binary>>,
%%  ChatJID = jid:replace_resource(jid:from_string(Chat),?RESOURCE),
%%  Body = [#text{lang = <<>>,data = MsgTxt}],
%%  Version = mod_groups_users:current_chat_version(Server, Chat),
%%  X = #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE, version = Version,
%%    sub_els = [UserCard], type = <<"update">>},
%%  By = #xmppreference{type = <<"mutable">>, sub_els = [UserCard]},
%%  SubEls = [X,By],
%%  mod_groups_system_message:form_message(ChatJID,Body,SubEls).

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
  Meta = get_image_metadata_f(Server, User, Chat),
  Result = case Meta of
    not_exist ->
      #avatar_meta{};
    not_filed ->
      #avatar_meta{};
    error ->
      #avatar_meta{};
    _ ->
      [{Hash,AvatarSize,AvatarType,AvatarUrl}] = Meta,
      Info = #avatar_info{bytes = AvatarSize, type = AvatarType, id = Hash, url = AvatarUrl},
      #avatar_meta{info = [Info]}
  end,
  Result.

get_avatar_data(Server, Hash, User, Node, Chat) ->
  case get_image_metadata(Server, User, Chat) of
    [{Hash, _Size, _Type, AvaUrl}] ->
      Path = get_docroot(Server),
      Name = get_file_from_url(AvaUrl),
      File = filename:join([Path, ?AVATARS_PATH, Name]),
      get_avatar_data(File, Hash, Node);
    error ->
      error;
    _ ->
      get_vcard_avatar(Server, Hash, User, Node, Chat)
  end.

get_vcard_avatar(Server, Hash, User, Node, Chat) ->
  case mod_groups_chats:is_anonim(Server,Chat) of
    false ->
      get_vcard_avatar_data(Server, User, Hash,Node);
    _ ->
      error
  end.

get_vcard_avatar_data(Server, User, Hash, Node) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(image)s from groupchat_users_vcard
  where jid=%(User)s")) of
    {selected, []} ->
      not_exist;
    {selected, [<<>>]} ->
      not_filed;
    {selected,[{Name}]} ->
      Path = get_docroot(Server),
      File = filename:join([Path, ?AVATARS_PATH, Name]),
      get_avatar_data(File, Hash, Node);
    _ ->
      error
  end.

get_vcard_avatar_hash(Server,SJID) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(hash)s
       from groupchat_users_vcard where jid=%(SJID)s")) of
    {selected,[{Hash}]} -> Hash;
    _ -> <<>>
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
    {selected,Meta} ->
      Meta;
    _ ->
      error
  end.

get_image_metadata_f(Server, User, Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(avatar_id)s,@(avatar_size)d,@(avatar_type)s,@(avatar_url)s "
    " from groupchat_users where username=%(User)s and chatgroup = %(Chat)s")) of
    {selected, []} ->
      not_exist;
    {selected, [{_AvaID ,Size, _Type, Url}] = Meta}
      when Size > 0 andalso Url /= null ->
      Meta;
    {selected, [_Meta]} ->
      get_vcard_avatar(Server,Chat,User);
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

get_vcard_avatar(Server, Chat, User) ->
  case mod_groups_chats:is_anonim(Server,Chat) of
    false ->
      do_get_vcard_avatar(Server, User);
    _ -> error
  end.

do_get_vcard_avatar(Server, User) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(image)s,@(hash)s,@(image_type)s from groupchat_users_vcard
  where jid=%(User)s")) of
    {selected,[{Image,Hash,ImageType}]} when Image =/= null andalso
      Hash =/= null andalso ImageType =/= null ->
      DocRoot = get_docroot(Server),
      File = filename:join([DocRoot, ?AVATARS_PATH, Image]),
      case file:read_file(File) of
        {ok,Binary} ->
          Size = byte_size(Binary),
          UrlDir = get_root_url(Server),
          Url = <<UrlDir/binary, $/, ?AVATARS_PATH/binary, $/, Image/binary>>,
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
  Path = get_docroot(Server),
  RootUrl = get_root_url(Server),
  Salt = ?AVATAR_NAME_SALT,
  Name = str:sha(<<UserID/binary, Salt/binary>>),
  _Url = <<RootUrl/binary, $/, ?AVATARS_PATH/binary, $/, Name/binary,"?v=",Hash/binary>>,
  FilePath = filename:join([Path, ?AVATARS_PATH, Name]),
  do_store_file(FilePath, Data, undefined, undefined),
  OldMeta = get_image_metadata_by_id(Server, UserID, Chat),
  ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set
    avatar_id = %(Hash)s,
    parse_avatar = 'no',
    avatar_url = %(_Url)s
  where id = %(UserID)s and chatgroup = %(Chat)s ")),
  maybe_delete_file(Server, OldMeta).

set_update_status(Server,Jid,Status) ->
  case ?SQL_UPSERT(Server, "groupchat_users_vcard",
    ["fullupdate=%(Status)s",
      "!jid=%(Jid)s"]) of
    ok ->
      ok;
    _Err ->
      {error, db_failure}
  end.

%%get_update_status(Server,Jid) ->
%%  case ejabberd_sql:sql_query(
%%    Server,
%%    ?SQL("select @(fullupdate)s
%%       from groupchat_users_vcard where jid=%(Jid)s")) of
%%    {selected,[]} ->
%%      <<>>;
%%    {selected,[{Status}]} ->
%%      Status
%%  end.

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

update_vcard_info(Server, User, NameRaw, FNRaw, NicknameRaw, Photo) ->
  Nickname = trim(NicknameRaw),
  FN = trim(FNRaw),
  Name = trim(NameRaw),
  Length = string:length(Nickname) + string:length(FN)
    + string:length(Name),
  {Hash,Type} = get_hash_and_type(Photo),
  Filename = get_name_from_hash_and_type(Photo),
  UPSERT = fun() ->
      ?SQL_UPSERT_T("groupchat_users_vcard",
        ["!jid=%(User)s",
          "givenfamily=%(Name)s",
          "fn=%(FN)s",
          "hash=%(Hash)s",
          "nickname=%(Nickname)s",
          "image=%(Filename)s",
          "image_type=%(Type)s"
        ]) end,
  Fun = fun() ->
    case ejabberd_sql:sql_query_t(?SQL(
      "select COALESCE(givenfamily,'') as @(givenfamily)s,
      COALESCE(fn,'') as @(fn)s, COALESCE(nickname,'') as @(nickname)s,
      COALESCE(image,'') as @(filename)s
      from groupchat_users_vcard where jid = %(User)s")) of
      {selected, [{Name, FN, Nickname, Filename}]} ->
        ok;
      {selected, Data} ->
        OldNickname = nick(User, Data),
        UPSERT(),
        sql_update_auto_nickname_t(User, Nickname, Name, FN),
        {updated, OldNickname};
      _ -> ok
    end end,
  if
    Length > 0 ->
      case ejabberd_sql:sql_transaction(Server, Fun) of
        {atomic, {updated, OldNickname}} ->
          handle_vcard_photo(Server,Photo);
%%          send_notifications_about_nick_change(Server,User, OldNickname);
        _ -> ok
      end;
    true -> ok
  end.

sql_update_auto_nickname_t(User, Nickname, Name, FN) ->
  FinishNickname = nick(User, Nickname, Name, FN),
  ejabberd_sql:sql_query_t(
    ?SQL("update groupchat_users set auto_nickname = %(FinishNickname)s, "
    " user_updated_at = (now() at time zone 'utc') "
    " where username = %(User)s and nickname='' "
    " and auto_nickname != %(FinishNickname)s"
    " and chatgroup not in (select jid from groupchats "
    " where anonymous = 'incognito')")).

update_chat_avatar_id(Server,Chat,Hash) ->
  case ?SQL_UPSERT(Server, "groupchats",
    [
      "avatar_id=%(Hash)s",
      "!jid=%(Chat)s"
    ]) of
    ok ->
      ok;
    _Err ->
      {error, db_failure}
  end.

trim(String) ->
  case String of
    undefined -> <<>>;
    _ ->
      string:trim(String)
  end.

nick(User, []) -> User;
nick(User, [{Name, FN, Nickname, _}]) ->
  nick(User, Nickname, Name, FN).

nick(User, Nickname, Name, FN) ->
  if
    Nickname /= <<>> -> Nickname;
    Name /= <<>> -> Name;
    FN /= <<>> -> FN;
    true -> User
  end.


delete_group_avatar_file(Group) when is_binary(Group) ->
  delete_group_avatar_file(jid:from_string(Group));
delete_group_avatar_file(#jid{lserver = Server} = Group)->
  JIDinURL = gen_mod:get_module_opt(Server,mod_http_upload,jid_in_url),
  UserStr = make_user_string(Group, JIDinURL),
  DocRoot = get_docroot(Server),
  FullPath = filename:join([DocRoot, UserStr]),
  del_dir_r(FullPath).

maybe_delete_file(Server, Meta) when is_list(Meta)->
  lists:foreach(fun(MetaEl) ->
    {_Hash, _Size, _Type, Url} = MetaEl,
    if
      Url =/= null ->
        check_and_delete_file(Server, Url);
      true -> ok
    end
                end , Meta);
maybe_delete_file(_Server, _Meta) -> ok.

check_and_delete_file(Server, Url) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(avatar_id)s from groupchat_users
    where avatar_url = %(Url)s")) of
    {selected,[]} ->
      delete_file(Server, Url);
    _ ->
      ok
  end.

delete_file(Server,  Url) when is_binary(Url) andalso size(Url) > 0 ->
  Path = get_docroot(Server),
  Name = get_file_from_url(Url),
  File = filename:join([Path, ?AVATARS_PATH, Name]),
  file:delete(File);
delete_file(_Server,  _Url) -> ok.

del_dir_r(File) ->
  case filelib:is_dir(File) of
    true ->
      case file:list_dir_all(File) of
        {ok, Names} ->
          lists:foreach(fun(Name) ->
            del_dir_r(filename:join(File, Name))
                        end, Names);
        {error, _Reason} -> ok
      end,
      file:del_dir(File);
    _ -> file:delete(File)
  end.

get_vcard(LUser,Server) ->
  Chat = jid:to_string(jid:make(LUser,Server)),
  {Name, Privacy, Index, Membership, Desc, _ChatMessage, _Contacts,
    _Domains, ParentChat, Status} = mod_groups_chats:get_info(Chat, Server),
  Parent = define_parent_chat(ParentChat),
  Members = mod_groups_chats:count_users(Server,Chat),
  HumanStatus = case ParentChat of
                  <<"0">> ->
                    mod_groups_chats:define_human_status(Server, Chat, Status);
                  _ ->
                    <<"Private chat">>
                end,
  [xmpp:encode(#vcard_temp{
    jabberid = Chat,
    nickname = Name,
    desc = Desc,
    index = Index,
    privacy = Privacy,
    membership = Membership,
    parent = Parent,
    status = HumanStatus,
    members = Members})].


define_parent_chat(<<"0">>) ->
  undefined;
define_parent_chat(ParentChat) ->
  ParentChat.

handle_vcard_photo(_Server, undefined) ->
  ok;
handle_vcard_photo(Server,Photo) ->
  #vcard_photo{binval = Binval} = Photo,
  Path = get_docroot(Server),
  Name = get_name_from_hash_and_type(Photo),
  case Name of
    <<>> ->
      ok;
    _ ->
      File = filename:join([Path, ?AVATARS_PATH, Name]),
      file:write_file(binary_to_list(File), Binval)
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

get_docroot(Server) ->
  DocRoot1 = gen_mod:get_module_opt(Server, mod_http_upload, docroot),
  DocRoot2 = mod_http_upload:expand_home(str:strip(DocRoot1, right, $/)),
  DocRoot3 = mod_http_upload:expand_host(DocRoot2, Server),
  filename:absname(DocRoot3).

get_root_url(Server) ->
  UrlOpt =  case gen_mod:get_module_opt(Server,mod_http_upload,get_url) of
              undefined ->
                gen_mod:get_module_opt(Server,mod_http_upload,put_url);
              Val -> Val
            end,
  misc:expand_keyword(<<"@HOST@">>, str:strip(UrlOpt, right, $/), Server).

get_file_from_url(Url) ->
  Url1 = hd(binary:split(Url,<<$?>>)),
  Url2 = binary:split(Url1, <<$/>>,[global]),
  lists:last(Url2).


create_p2p_avatar(LServer,Chat, AvatarUrl1, AvatarUrl2)
  when is_binary(AvatarUrl1) andalso is_binary(AvatarUrl2)->
  L1 = size(AvatarUrl1),
  L2 = size(AvatarUrl2),
  if
    L1 > 0 andalso L2 > 0 ->
      Path = get_docroot(LServer),
      Name1 = get_file_from_url(AvatarUrl1),
      Name2 = get_file_from_url(AvatarUrl2),
      File1 = filename:join([Path, ?AVATARS_PATH, Name1]),
      File2 = filename:join([Path, ?AVATARS_PATH, Name2]),
      case eavatartools:merge_avatars(File1,File2) of
        {ok, Filename, Data} ->
          publish_avatar(Chat, Data, Filename);
        _ ->
          ok
      end;
    true ->
      ok
  end;
create_p2p_avatar(_LServer,_Chat,_AvatarID1,_AvatarID2) ->
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
  DocRoot = get_docroot(Server),
  FileName1 = make_user_string(Chat, salt),
  FullPath = filename:join([DocRoot, UserStr, "avatar", FileName1]),
  case do_store_file(FullPath, Data, undefined, undefined) of
    ok ->
      Url = get_root_url(Server),
      Size = byte_size(Data),
      HashID = get_hash(Data),
      Type = lists:last(binary:split(FileName,<<".">>)),
      ImageType = <<"image/",Type/binary>>,
      AvatarUrl = <<Url/binary, $/,UserStr/binary,$/,"avatar",$/,
        FileName1/binary,"?v=",HashID/binary>>,
      AvatarInfo = #avatar_info{type = ImageType, bytes = Size, id = HashID, url = AvatarUrl},
      AvatarMeta = #avatar_meta{info = [AvatarInfo]},
      MetaItems = #ps_item{id = HashID, sub_els = [xmpp:encode(AvatarMeta)]},
      PublishMetaData = #pubsub{publish = #ps_publish{node = ?NS_AVATAR_METADATA, items = [MetaItems]}},

      IQMeta = #iq{from = jid:replace_resource(Chat,?RESOURCE),
        to = jid:replace_resource(Chat,<<>>),
        id = randoms:get_string(),
        type = set,
        sub_els = [PublishMetaData],
        meta = #{}},
      mod_pubsub:iq_sm(IQMeta);
    Err ->
      ?ERROR_MSG("Error storing group avatar: ~p ~p ~p",[Chat, FullPath, Err]),
      Err
  end;

publish_avatar(_, _, _) ->
  ok.

%% block from mod_http_upload

-spec make_user_string(jid(), sha1 | node) -> binary().
make_user_string(#jid{luser = U, lserver = S}, salt) ->
  Salt = ?AVATAR_NAME_SALT,
  str:sha(<<U/binary, $@, S/binary, Salt/binary>>);
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
    {ok, Io} = file:open(Path, [write, raw]),
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