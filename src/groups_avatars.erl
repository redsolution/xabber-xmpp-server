%%%-------------------------------------------------------------------
%%% File    : groups_avatars.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : Manage avatars in Groups.
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

-module(groups_avatars).
-author('ilya.kalashnikov@redsolution.com').
-compile([{parse_transform, ejabberd_sql_pt}]).
-behavior(gen_mod).
-behaviour(gen_server).

-include("ejabberd_sql_pt.hrl").
-include("logger.hrl").
-include("xmpp.hrl").

%% gen_mod, gen_server
-export([start/2, stop/1, depends/2, mod_options/1]).
-export([init/1, handle_call/3, handle_cast/2,
  handle_info/2, terminate/2, code_change/3]).

%% API
-export([
  handle_request/1,
  get_all_image_metadata/2,
  maybe_delete_file/2,
  delete_group_avatar_file/1,
  handle_avatar_data/4,
  handle_avatar_meta/3,
  handle_vcard/3,
  get_image_id/3,
  get_vcard/2,
  update_avatar/7,
  create_p2p_avatar/4,
  handle_pubsub_iq/1,
  get_group_avatar/2
]).
-export([make_group_avatar/2, store_user_avatar_file/5]).
-export([maybe_update_avatar/3, async_maybe_update_avatar/3]).

-export([send_pep_msg/3, async_send_pep_msg/3, async_send_pep_msg/2,
  request_vcard/2, request_pubsub_metadata/2]).
-export([download_avatar/5, do_http_request/5]).
-export([get_user_avatar/3, user_update_avatar/5, group_avatar_url/2,
  process_pubsub_event/1]).

-record(state, {host :: binary()}).

-define(RESOURCE, <<"Group">>).
-define(AVATARS_PATH, <<"groups/mavatars">>).
-define(AVATAR_NAME_SALT, atom_to_binary(erlang:get_cookie(),latin1)).

%%====================================================================
%% gen_mod callbacks
%%====================================================================
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
  %% run task once for all hosts
  Hosts = lists:sort(ejabberd_config:get_myhosts()),
  case Hosts of
    [Host | _] ->
      erlang:send_after(timer:minutes(10), self(),
        'delete_zombie_requests');
    _ ->
      ok
  end,
  {ok, #state{host = Host}}.

init_db() ->
  catch ets:new(groups_avatar_requests, [named_table, public,
    {read_concurrency, true}, {heir, erlang:group_leader(), none}]).

handle_call(_Call, _From, State) ->
  {noreply, State}.

handle_cast(Msg, State) ->
  ?WARNING_MSG("unexpected cast: ~p", [Msg]),
  {noreply, State}.


handle_info({delete_as, User}, State) ->
  ?DEBUG("Deleting the avatar request for ~p", [User]),
  ets:delete(groups_avatar_requests, User),
  {noreply, State};
handle_info('delete_zombie_requests', State) ->
  ?DEBUG("Deleting forgotten avatar requests", []),
  TS = erlang:system_time(second) - 600,
  MatchSpec = [{{'_', '$2', '_', '_'}, [{'<', '$2', TS}], [true]}],
  ets:select_delete(groups_avatar_requests, MatchSpec),
  erlang:send_after(timer:minutes(10),
    self(), 'delete_zombie_requests'),
  {noreply, State};
handle_info(Info, State) ->
  ?WARNING_MSG("unexpected info: ~p", [Info]),
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
%%====================================================================

get_user_avatar(Server, User, Group)->
  Data = case sql_get_image_info(Server, User, Group) of
           error -> undefined;
           D1 -> D1
         end,
  case Data of
    {Hash, AvatarSize, AvatarType, AvatarUrl} ->
      #groups_avatar{info = #avatar_info{bytes = AvatarSize,
        type = AvatarType, id = Hash, url = AvatarUrl}};
    _ -> undefined
  end.

user_update_avatar(Server, Group, User, Iq, undefined) ->
  OldMeta = get_image_metadata(Server, User, Group),
  sql_user_update_avatar_info(Server, Group, User, <<>>, <<>>, 0, <<>>),
  maybe_delete_file(Server, OldMeta),
  ejabberd_router:route(xmpp:make_iq_result(Iq)),
  groups_notifications:user_avatar_changed(Server, Group, User),
  ok;
user_update_avatar(Server, Group, User, Iq,
    #groups_avatar{info = Info, data = _Data}) ->
  #avatar_info{bytes = Size, url = Url} = Info,
  MaxSize = mod_groups:get_option(Server, avatar_max_size),
  if
    Size > MaxSize ->
      Txt = <<"File too large. The maximum file size is ",
        MaxSize/binary,"bytes">>,
      ejabberd_router:route(xmpp:make_error(Iq,
        xmpp:err_not_acceptable(Txt, <<>>)));
    true ->
      case Url of
        <<>> ->
          %%todo: implement it
          ejabberd_router:route(xmpp:make_error(Iq,
            xmpp:err_feature_not_implemented()));
        _ ->
          download_avatar(Server, Group, User, Info, Iq)
      end
  end.

sql_user_update_avatar_info(Server, Group, User, ID, ImgType, Size, Url) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set avatar_size = %(Size)d,
    avatar_type = %(ImgType)s,
    avatar_id = %(ID)s,
    use_user_avatar = false,
    avatar_url = %(Url)s,
    user_updated_at = (now() at time zone 'utc')
  where username = %(User)s and chatgroup = %(Group)s ")).

sql_get_image_info(Server, User, Group) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(avatar_id)s,@(avatar_size)d,@(avatar_type)s,@(avatar_url)s "
    " from groupchat_users where username=%(User)s and chatgroup = %(Group)s")) of
    {selected, [{_AvaID , Size, _Type, Url} = Meta] }
      when Size > 0 andalso Url /= null ->
      Meta;
    _ ->
      error
  end.

download_avatar(Server, Group , User, AvatarInfo, Iq) ->
  ?DEBUG("Download avatar: user ~p, group ~p ~n",[User, Group]),
  spawn(?MODULE, do_http_request,[Server, Group , User, AvatarInfo, Iq]).

do_http_request(Server, Group , User, AvatarInfo, Iq) ->
  #avatar_info{bytes = Size, url = Url} = AvatarInfo,
  Options = [{sync, false},{stream, self}],
  HttpOptions = [{timeout, 5000}, {autoredirect, false}], % 5 seconds.
  httpc:request(get, {binary_to_list(Url), []}, HttpOptions, Options),
  http_response_process(Server, Group , User, AvatarInfo, Iq, Size, <<>>).

http_response_process(Server, Group , User, AvatarInfo, Iq, Size, Data) ->
  receive
    {http, {_RequestId, stream_start, _Headers}} ->
      http_response_process(Server, Group , User, AvatarInfo, Iq, Size, Data);
    {http, {_RequestId, stream, BinBodyPart}} ->
      NewData = <<Data/binary,BinBodyPart/binary>>,
      CurrSize = byte_size(NewData),
      MaxSize = mod_groups:get_option(Server, avatar_max_size),
      if
        CurrSize > Size orelse CurrSize > MaxSize ->
          ?ERROR_MSG("Avatar download error: file too large",[]),
          MSB = integer_to_binary(MaxSize),
          Txt = <<"File too large. The maximum file size is ", MSB/binary," bytes">>,
          return_error(Server, User, Iq, err_not_acceptable, Txt),
          exit(normal);
        true ->
          http_response_process(Server, Group , User, AvatarInfo, Iq, Size, NewData)
      end;
    {http, {_RequestId, stream_end, _Headers}} ->
      store_avatar(Server, Group , User, AvatarInfo, Iq, Data),
      exit(normal);
    E ->
      ?ERROR_MSG("Avatar download error: ~p~n",[E]),
      return_error(Server, User, Iq, err_bad_request, <<"Avatar download error">>),
      exit(normal)
  after
    60000 -> exit(normal)
  end.

return_error(_Server, _User, #iq{lang = Lang} = Iq, ErrFun, Txt) ->
  Err = apply(xmpp, ErrFun, [Txt, Lang]),
  ejabberd_router:route(xmpp:make_error(Iq, Err));
return_error(Server, User, _, _, _) ->
  del_avatar_request(Server, User).

%% Group Avatar
store_avatar(Server, Group, <<>>, AvatarInfo, Iq, Data) ->
  store_group_avatar(Server, AvatarInfo, Group, Iq, Data);
%% User avatar
store_avatar(Server, Group , User, AvatarInfo, Iq, Data) ->
  store_user_avatar(Server, Group , User, AvatarInfo, Iq, Data).

store_group_avatar(Server, AvatarInfo, Group, Iq, Data)->
  case publish_group_avatar(Server, Group, AvatarInfo, Data) of
    error ->
      ER = xmpp:make_error(Iq, xmpp:err_internal_server_error()),
      ejabberd_router:route(ER);
    Info ->
      Avatar = #groups_avatar{info = Info},
      GI = #groups_info{avatar = Avatar},
      ejabberd_router:route(xmpp:make_iq_result(Iq, GI)),
      send_pep_msg(Server, Group)
  end.

publish_group_avatar(Server, Group, AvatarInfo, Data) ->
  GroupJID = jid:from_string(Group),
  #avatar_info{id = ID} = AvatarInfo,
  {FileName, UserStr, Url} = group_avatar_opts(Group, ID),
  DocRoot = get_docroot(Server),
  FullPath = filename:join([DocRoot, UserStr, "avatar", FileName]),
  case do_store_file(FullPath, Data, undefined, undefined) of
    ok ->
%%      Size = byte_size(Data),
%%      ID = get_hash(Data),
      Info = AvatarInfo#avatar_info{url = Url},
      AvatarMeta = xmpp:encode(#avatar_meta{info = [Info]}),
      LBJID = jid:tolower(GroupJID),
      case mod_pubsub:publish_item(LBJID, Server,
        ?NS_AVATAR_METADATA, GroupJID, ID, [AvatarMeta]) of
        {result, _} -> Info;
        {error, StanzaErr} ->
          ?ERROR_MSG("Error piblish group avatar: ~p", [StanzaErr]),
          error
      end;
    Err ->
      ?ERROR_MSG("Error storing group avatar file: ~p ~p ~p",
        [Group, FullPath, Err]),
      error
  end.

make_group_avatar(Server, Group)->
  case mod_nick_avatar:get_avatar_file(Server) of
    {ok, FileName, Bin} ->
      Size = byte_size(Bin),
      HashID = get_hash(Bin),
      Ext = lists:last(binary:split(FileName,<<".">>)),
      ImageType = <<"image/",Ext/binary>>,
      AvatarInfo = #avatar_info{type = ImageType, bytes = Size,
        id = HashID},
      publish_group_avatar(Server, Group, AvatarInfo, Bin);
    _ ->
      ok
  end.

store_user_avatar(Server, <<>> , User, AvatarInfo, _Iq, Data) ->
  del_avatar_request(Server, User),
  store_user_auto_avatar(Server, User, AvatarInfo, Data);
store_user_avatar(Server, Group , User, AvatarInfo, Iq, Data) ->
  UserId = groups_members:get_user_id(Server, User, Group),
  #avatar_info{id = ID, type = ImgType, bytes = Size} = AvatarInfo,
%%  Hash = base64:encode(crypto:hash(sha, Data)),
  Url = update_data_user_put(Server, UserId, Data, ID),
  OldMeta = get_image_metadata(Server, User, Group),
  sql_user_update_avatar_info(Server, Group, User, ID, ImgType, Size, Url),
  maybe_delete_file(Server, OldMeta),
  NewInfo = AvatarInfo#avatar_info{url = Url},
  ejabberd_router:route(xmpp:make_iq_result(Iq,
    #groups_user{id = UserId, avatar = #groups_avatar{info = NewInfo}})),
  groups_notifications:user_avatar_changed(Server, Group, User).

update_data_user_put(Server, UserID, Data, Hash) ->
  Path = get_docroot(Server),
  RootUrl = get_root_url(Server),
  Salt = ?AVATAR_NAME_SALT,
  Name = str:sha(<<UserID/binary, Salt/binary>>),
  Url = <<RootUrl/binary, $/, ?AVATARS_PATH/binary, $/, Name/binary,"?v=",Hash/binary>>,
  FilePath = filename:join([Path, ?AVATARS_PATH, Name]),
  do_store_file(FilePath, Data, undefined, undefined),
  Url.

group_avatar_url(Group, ID) ->
  {_, _, AvaUrl} = group_avatar_opts(Group, ID),
  AvaUrl.

group_avatar_opts(Group, ID) ->
  GroupJID = jid:from_string(Group),
  Server = GroupJID#jid.lserver,
  JIDinURL = gen_mod:get_module_opt(Server, mod_http_upload, jid_in_url),
  Url = get_root_url(Server),
  UserStr = make_user_string(GroupJID, JIDinURL),
  FileName = make_user_string(GroupJID, salt),
  AvaUrl = <<Url/binary,$/,UserStr/binary,$/,"avatar",$/,
    FileName/binary,"?v=",ID/binary>>,
  {FileName, UserStr, AvaUrl}.

send_pep_msg(Server, Group, UserJID) ->
  spawn(?MODULE, async_send_pep_msg,[Server, Group, UserJID]).

async_send_pep_msg(Server, Group, UserJID) ->
  case groups_groups:get_info(Group, [parent, p2pusers]) of
    [<<"0">>, _] ->
      case get_group_avatar(Server, Group) of
        undefined -> ok;
        #groups_avatar{info = Info} ->
          GroupJID = jid:from_string(Group),
          NodeId = Info#avatar_info.id,
          Metadata = #avatar_meta{info = [Info]},
          send_avatar_meta(GroupJID, UserJID, NodeId, Metadata)
      end;
    [_, P2PUsers] ->
      send_p2p_avatar(Server, Group, UserJID, P2PUsers);
    _ ->
      ok
  end.

send_pep_msg(Server, Group) ->
  spawn(?MODULE, async_send_pep_msg,[Server, Group]).

async_send_pep_msg(Server, Group) ->
  case groups_groups:get_info(Group, [parent, p2pusers]) of
    [<<"0">>, _] ->
      case get_group_avatar(Server, Group) of
        undefined -> ok;
        #groups_avatar{info = Info} ->
          GroupJID = jid:from_string(Group),
          NodeId = Info#avatar_info.id,
          Metadata = #avatar_meta{info = [Info]},
          Users = groups_members:users_to_send(Server, Group),
          lists:foreach(fun(UserJID) ->
            send_avatar_meta(GroupJID, UserJID, NodeId, Metadata)
                        end, Users)
      end;
    [_, P2PUsers] ->
      Users = groups_members:users_to_send(Server, Group),
      lists:foreach(fun(UserJID) ->
        send_p2p_avatar(Server, Group, UserJID, P2PUsers)
                    end, Users);
    _ ->
      ok
  end.

send_p2p_avatar(Server, Group, User, Names)->
  UserS = jid:to_string(jid:remove_resource(User)),
  {User2S, _} = hd(lists:keydelete(UserS, 1, Names)),
  GroupJID = jid:from_string(Group),
  case get_user_avatar(Server, User2S, Group) of
    #groups_avatar{info = Info} ->
      Metadata = #avatar_meta{info = [Info]},
      ID = Info#avatar_info.id,
      send_avatar_meta(GroupJID, User, ID, Metadata);
    _ ->
      send_avatar_meta(GroupJID, User, <<>>, #avatar_meta{})
  end.

send_avatar_meta(GroupJID, UserJID, AvatarID, Metadata)->
  Item = #ps_item{id = AvatarID, sub_els = [Metadata]},
  Items = #ps_items{node = ?NS_AVATAR_METADATA, items = [Item]},
  Event = #ps_event{items = Items},
  M = #message{type = headline,
    from = GroupJID,
    to = UserJID,
    id = randoms:get_string(),
    sub_els = [Event],
    meta = #{}
  },
  ejabberd_router:route(M).

get_group_avatar(Server, Group)->
  case get_chat_meta_nodeid(Server, Group) of
    no_avatar -> undefined;
    NodeId ->
      case get_chat_meta(Server, Group, NodeId) of
        no_avatar -> undefined;
        {Payload, _} ->
          Meta = xmpp:decode(fxml_stream:parse_element(Payload)),
          case Meta#avatar_meta.info of
            [] -> undefined;
            L -> #groups_avatar{info = hd(L)}
          end
      end
  end.

request_vcard(Group, User) ->
  case groups_groups:is_anon(Group) of
    false -> send_iq(Group, User, [#vcard_temp{}]);
    _ -> ok
  end.

request_pubsub_metadata(Group, User) ->
  case groups_groups:is_anon(Group) of
    false ->
      case get_avatar_request(User) of
        false ->
          add_avatar_request(User),
          do_request_pubsub_metadata(Group, User);
        _ -> ok
      end;
    _ -> ok
  end.

process_pubsub_event(#message{sub_els = [Event], from = From, to = To}) ->
  #ps_event{items = ItemsEl} = Event,
  Metadata = try
               #ps_items{items = Items, node = Node} = ItemsEl,
               case Node of
                 <<"urn:xmpp:avatar:metadata">> ->
                   #ps_item{sub_els = Els} = hd(Items),
                   xmpp:decode(hd(Els));
                 _ -> undefined
               end
             catch
               _:_  -> undefined
             end,
  case Metadata of
    #avatar_meta{} ->
      User = jid:to_string(jid:remove_resource(From)),
      case get_avatar_request(User) of
        false ->
          add_avatar_request(User),
          groups_avatars:handle_avatar_meta(
            jid:replace_resource(To,<<"Group">>),
            jid:remove_resource(From),
            Metadata);
        _ -> ok
      end;
    _ ->
      ok
  end.

do_request_pubsub_metadata(Group, User) ->
  Query = #pubsub{items = #ps_items{node = ?NS_AVATAR_METADATA}},
  send_iq(Group, User, [Query]).

request_pubsub_data(Group, User, ID) ->
  Query = #pubsub{
    items = #ps_items{
      node = ?NS_AVATAR_DATA,
      items = [#ps_item{id = ID}]}},
  send_iq(Group, User, [Query]).

send_iq(Group, User, SubEls) ->
  From = jid:replace_resource(jid:from_string(Group), ?RESOURCE),
  To = jid:from_string(User),
  Iq = #iq{from = From, to = To, type = get,
    id = randoms:get_string(), sub_els = SubEls},
  ejabberd_router:route(Iq).

handle_avatar_meta(GroupJID, UserJID, #avatar_meta{info = []}) ->
  Server = GroupJID#jid.lserver,
  User = jid:to_string(jid:remove_resource(UserJID)),
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  del_avatar_request(Server, User),
  case get_image_metadata(Server, User, Group) of
    {<<>>, _, _, _ } -> ok;
    OldMeta ->
      update_avatar_in_groups(Server, User, <<>>, <<>>, 0, <<>>),
      maybe_delete_file(Server, OldMeta)
  end;
handle_avatar_meta(GroupJID, UserJID, #avatar_meta{info = [AvatarINFO]}) ->
  #avatar_info{bytes = Size, id = ID, type = _Type0,
    url = Url} = AvatarINFO,
  Server = GroupJID#jid.lserver,
  MaxSize = mod_groups:get_option(Server, avatar_max_size),
  if
    Size > MaxSize ->
      ok;
    true ->
      User = jid:to_string(jid:remove_resource(UserJID)),
      case groups_for_update(Server, User, ID) of
        [] ->
          del_avatar_request(Server, User);
        _ ->
          case Url of
            <<>> ->
              Group = jid:to_string(jid:remove_resource(GroupJID)),
              update_avatar_request(User,AvatarINFO),
              request_pubsub_data(Group, User, ID);
            _ ->
              download_avatar(Server, <<>> , User, AvatarINFO, undefined)
          end
      end
  end;
handle_avatar_meta(_, _, _) ->
  ok.

handle_avatar_data(GroupJID, UserJID, ID, #avatar_data{data = Data}) ->
  Server = GroupJID#jid.lserver,
  User = jid:to_string(jid:remove_resource(UserJID)),
  case get_avatar_request(User) of
    {User, _, ID, AvatarInfo} ->
      store_user_avatar(Server, <<>> , User, AvatarInfo, undefined, Data);
    _ ->
      ok
  end;
handle_avatar_data(_C, _U, _I, false) ->
  ok.


update_avatar_in_groups(Server, User, Hash, ImgType, Size, Url) ->
  Groups = groups_for_update(Server, User, Hash),
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set avatar_id = %(Hash)s,"
    " avatar_url = %(Url)s, avatar_size = %(Size)d, "
    " avatar_type = %(ImgType)s, user_updated_at = (now() at time zone 'utc') "
    " where username = %(User)s and avatar_id IS DISTINCT FROM %(Hash)s "
    " and use_user_avatar ")) of
    {updated, Num} when Num > 0 ->
      send_notifications(Groups, User, Server),
      ok;
    _ ->
      ok
  end.

groups_for_update(Server, User, Hash) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(chatgroup)s from groupchat_users "
    " where username = %(User)s and avatar_id IS DISTINCT FROM %(Hash)s "
    " and use_user_avatar ")) of
    {selected, Result} -> [Group || {Group} <- Result];
    _ ->
      []
  end.

send_notifications(Groups, User, Server) ->
  lists:foreach(
    fun(Group) ->
      groups_notifications:user_avatar_changed(Server, Group, User)
    end, Groups).


add_avatar_request(User) ->
  ets:insert(groups_avatar_requests,
    {User, erlang:system_time(second), <<>>, #avatar_info{}}).

get_avatar_request(User)->
  case ets:lookup(groups_avatar_requests, User) of
    [Result] -> Result;
    _->
      false
  end.

update_avatar_request(User, AvatarInfo) ->
  case ets:lookup(groups_avatar_requests, User) of
    [_Result] ->
      ID = AvatarInfo#avatar_info.id,
      TS = erlang:system_time(second),
      ets:delete(groups_avatar_requests, User),
      ets:insert(groups_avatar_requests,{User, TS, ID, AvatarInfo}),
      ok;
    _->
      false
  end.

del_avatar_request(Server, User) ->
  Proc = gen_mod:get_module_proc(Server, ?MODULE),
  erlang:send_after(timer:seconds(10), Proc, {delete_as, User}).

%% deprecated
%%---------------------------------------------------------
handle_vcard(Server, User, VCard) ->
  FN = set_value(VCard#vcard_temp.fn),
  Name = case VCard#vcard_temp.n of
           undefined -> <<>>;
           N ->
             Given = set_value(N#vcard_name.given),
             Family = set_value(N#vcard_name.family),
             str:join([Given,Family], <<" ">>)
         end,
  NickName = set_value(VCard#vcard_temp.nickname),
  update_vcard_info(Server, User, Name, FN, NickName).

update_vcard_info(_Server, _User, <<>>, <<>>, <<>>) ->
  ok;
update_vcard_info(Server, User, Name, FN, Nickname) ->
  UPSERT = fun() ->
    ?SQL_UPSERT_T("groupchat_user_profile",
      ["!jid=%(User)s",
        "givenfamily=%(Name)s",
        "fn=%(FN)s",
        "nickname=%(Nickname)s"
      ]) end,
  Fun = fun() ->
    case ejabberd_sql:sql_query_t(?SQL(
      "select COALESCE(givenfamily,'') as @(givenfamily)s,
      COALESCE(fn,'') as @(fn)s, COALESCE(nickname,'') as @(nickname)s,
      from groupchat_user_profile where jid = %(User)s")) of
      {selected, [{Name, FN, Nickname}]} ->
        ok;
      {selected, Data} ->
        UPSERT(),
        sql_update_auto_nickname_t(User, Nickname, Name, FN),
        {updated, Data};
      _ -> ok
    end end,
  ejabberd_sql:sql_transaction(Server, Fun).

sql_update_auto_nickname_t(User, Nickname, Name, FN) ->
  FinishNickname = nick(User, Nickname, Name, FN),
  ejabberd_sql:sql_query_t(
    ?SQL("update groupchat_users set auto_nickname = %(FinishNickname)s, "
    " user_updated_at = (now() at time zone 'utc') "
    " where username = %(User)s and nickname='' "
    " and auto_nickname != %(FinishNickname)s"
    " and chatgroup not in (select jid from groupchats "
    " where anonymous = 'incognito')")).

nick(User, Nickname, Name, FN) ->
  if
    Nickname /= <<>> -> Nickname;
    Name /= <<>> -> Name;
    FN /= <<>> -> FN;
    true -> User
  end.

set_value(undefined) -> <<>>;
set_value(Value) -> string:trim(Value).
%%--------------------------------------------------------------------------

get_image_metadata(Server, User, Group) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(avatar_id)s,@(avatar_size)d,@(avatar_type)s,"
    " @(avatar_url)s from groupchat_users "
    " where username=%(User)s and chatgroup = %(Group)s")) of
    {selected, []} -> not_exist;
    {selected, [Meta]} -> replace_null(Meta);
    _ ->
      error
  end.

store_user_auto_avatar(Server, User, AvatarInfo, Data) ->
  FileName = make_user_string(jid:from_string(User), salt),
  DocRoot = get_docroot(Server),
  FullPath = filename:join([DocRoot, ?AVATARS_PATH, FileName]),
  case do_store_file(FullPath, Data, undefined, undefined) of
    ok ->
      #avatar_info{id = ID, type = ImgType, bytes = Size} = AvatarInfo,
      RootUrl = get_root_url(Server),
      Url = <<RootUrl/binary, $/,?AVATARS_PATH/binary,$/,FileName/binary,"?v=",ID/binary>>,
      update_avatar_in_groups(Server, User, ID, ImgType, Size, Url);
    Err ->
      ?ERROR_MSG("Error storing user avatar: ~p ~p ~p",[User, FileName, Err]),
      Err
  end.

get_vcard(User, Server) ->
  Chat = jid:to_string(jid:make(User,Server)),
  {Name, Privacy, Index, Membership, Desc, _ChatMessage, _Contacts,
    _Domains, ParentChat, _State, Status} = groups_groups:get_info(Chat),
  Members =  case groups_groups:get_info(Chat, [user_count]) of
               error -> 0;
               [C] -> C
             end,
  Parent = case ParentChat of <<"0">> -> <<>>; _ -> ParentChat end,
  [xmpp:encode(#vcard_temp{
    jabberid = Chat,
    nickname = Name,
    desc = Desc,
    index = atom_to_binary(Index, utf8),
    privacy = atom_to_binary(Privacy, utf8),
    membership = atom_to_binary(Membership, utf8),
    parent = Parent,
    status = Status,
    members = integer_to_binary(Members)})].

maybe_delete_file(Server, Meta) when is_list(Meta)->
  lists:foreach(fun(I) ->
    maybe_delete_file(Server, I)
                end , Meta);
maybe_delete_file(Server, {_, _, _, Url}) ->
  check_and_delete_file(Server, Url);
maybe_delete_file(_, _) -> ok.

check_and_delete_file(_Server, null) ->
  ok;
check_and_delete_file(_Server, <<>>) ->
  ok;
check_and_delete_file(Server, Url) ->
  Url1 = hd(binary:split(Url,<<$?>>)),
  LikeUrl = <<Url1/binary,"%">>,
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(avatar_id)s from groupchat_users
    where avatar_url like %(LikeUrl)s")) of
    {selected,[]} ->
      delete_file(Server, Url);
    _ ->
      ok
  end.

replace_null(List) when is_list(List) ->
  lists:map(fun(I) -> replace_null(I) end, List);
replace_null(Tuple) ->
  List = lists:map(fun(null) -> <<>> ;
    (V) -> V end, tuple_to_list(Tuple)),
  list_to_tuple(List).

handle_pubsub_iq(#iq{type = get} = Iq) ->
  handle_request(Iq);
handle_pubsub_iq(Iq) ->
  xmpp:make_error(Iq, xmpp:err_not_allowed()).

handle_request(Iq) ->
  try xmpp:decode_els(Iq) of
    DecodedIQ ->
      handle_decoded_request(DecodedIQ)
  catch _:_ ->
    xmpp:make_error(Iq, xmpp:err_bad_request())
  end.

handle_decoded_request(Iq) ->
  #iq{from = From,to = To,sub_els = Decoded} = Iq,
  Pubsub = lists:keyfind(pubsub,1,Decoded),
  #pubsub{items = Items} = Pubsub,
  #ps_items{node = Node} = Items,
  NewIq = Iq#iq{from = To},
  Result = case Node of
             <<"urn:xmpp:avatar:data">> ->
               xmpp:make_error(Iq, xmpp:err_item_not_found());
             <<"urn:xmpp:avatar:metadata">> ->
               Group = jid:to_string(jid:remove_resource(To)),
               case groups_groups:get_info(Group, [parent]) of
                 [<<"0">>] ->
                   mod_pubsub:iq_sm(NewIq);
                 [_] ->
                   ps_result_p2p_group(Iq);
                 _ ->
                   xmpp:make_error(Iq, xmpp:err_item_not_found())
               end;
             <<"http://jabber.org/protocol/nick">> ->
               mod_pubsub:iq_sm(NewIq);
             _ ->
               xmpp:make_error(Iq, xmpp:err_item_not_found())
           end,
  Result#iq{from = To, to = From}.

ps_result_p2p_group(Iq) ->
  #iq{from = UserJID, to = GroupJID} = Iq,
  Server =GroupJID#jid.lserver,
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  User = jid:to_string(jid:remove_resource(UserJID)),
  [Users] = groups_groups:get_info(Group, [p2pusers]),
  {User2, _} = hd(lists:keydelete(User, 1, Users)),
  #groups_avatar{info = Info} = get_user_avatar(Server, User2, Group),
  Metadata = #avatar_meta{info = [Info]},
  ID = Info#avatar_info.id,
  Item = #ps_item{id = ID, sub_els = [Metadata]},
  Items = #ps_items{node = ?NS_AVATAR_METADATA, items = [Item]},
  xmpp:make_iq_result(Iq, #pubsub{items = Items}).

-spec maybe_update_avatar(binary(), binary(), binary()) -> any().
maybe_update_avatar(Server, Group, User) ->
  case get_avatar_request(User)of
    false ->
      add_avatar_request(User),
      spawn(?MODULE, async_maybe_update_avatar,[Server, Group, User]);
    _ ->
      ok
  end.

-spec async_maybe_update_avatar(binary(), binary(), binary()) -> any().
async_maybe_update_avatar(Server, Group, User) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(use_user_avatar)b from groupchat_users "
    " where username = %(User)s and chatgroup  = %(Group)s and "
    "'public' = (select anonymous from groupchats  "
    " where jid = %(Group)s)")) of
    {selected, [{true}]} ->
      do_request_pubsub_metadata(Group, User);
    _ ->
      ok
  end.

store_user_avatar_file(Server, Group, User, UserID, Data) ->
  ID = get_hash(Data),
  Url = update_data_user_put(Server, UserID, Data, ID),
  Type = atom_to_binary(eimp:get_type(Data), latin1),
  Size = byte_size(Data),
  sql_user_update_avatar_info(Server, Group, User, ID, Type, Size, Url).

get_chat_meta_nodeid(Server,Chat)->
  Node = ?NS_AVATAR_METADATA,
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

get_all_image_metadata(Server, Group) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(avatar_id)s,@(avatar_size)d,"
    " @(avatar_type)s,@(avatar_url)s from groupchat_users "
    " where chatgroup = %(Group)s")) of
    {selected, Result} ->  Result;
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


delete_group_avatar_file(Group) when is_binary(Group) ->
  delete_group_avatar_file(jid:from_string(Group));
delete_group_avatar_file(#jid{lserver = Server} = Group)->
  JIDinURL = gen_mod:get_module_opt(Server,mod_http_upload,jid_in_url),
  UserStr = make_user_string(Group, JIDinURL),
  DocRoot = get_docroot(Server),
  FullPath = filename:join([DocRoot, UserStr]),
  del_dir_r(FullPath).

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

get_hash(Binval) ->
  H = iolist_to_binary([io_lib:format("~2.16.0B", [X])
    || X <- binary_to_list(
      crypto:hash(sha, Binval))]),
  list_to_binary(string:to_lower(binary_to_list(H))).

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


create_p2p_avatar(Server, Group, AvatarUrl1, AvatarUrl2)
  when is_binary(AvatarUrl1) andalso is_binary(AvatarUrl2)->
  L1 = size(AvatarUrl1),
  L2 = size(AvatarUrl2),
  if
    L1 > 0 andalso L2 > 0 ->
      Path = get_docroot(Server),
      Name1 = get_file_from_url(AvatarUrl1),
      Name2 = get_file_from_url(AvatarUrl2),
      File1 = filename:join([Path, ?AVATARS_PATH, Name1]),
      File2 = filename:join([Path, ?AVATARS_PATH, Name2]),
      case eavatartools:merge_avatars(File1,File2) of
        {ok, FileName, Data} ->
          Size = byte_size(Data),
          HashID = get_hash(Data),
          Ext = lists:last(binary:split(FileName,<<".">>)),
          ImageType = <<"image/",Ext/binary>>,
          Info = #avatar_info{type = ImageType, bytes = Size,
            id = HashID},
          publish_group_avatar(Server, Group, Info, Data);
        _ ->
          ok
      end;
    true ->
      ok
  end;
create_p2p_avatar(_LServer,_Chat,_AvatarID1,_AvatarID2) ->
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