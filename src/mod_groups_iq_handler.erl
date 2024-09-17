%%%-------------------------------------------------------------------
%%% File    : mod_groups_iq_handler.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Handle iq for group chats
%%% Created : 9 May 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_groups_iq_handler).
-author('andrey.gagarin@redsolution.com').
-behavior(gen_mod).
-behavior(gen_server).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-export([start/2, stop/1, depends/2, mod_options/1, disco_sm_features/5,
  init/1, handle_call/3, handle_cast/2, terminate/2]).
-export([process_groupchat/1,make_action/1]).

%% records
-record(state, {host = <<"">> :: binary()}).

start(Host, Opts) ->
  gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
  gen_mod:stop_child(?MODULE, Host).

depends(_Host, _Opts) ->
  [].

mod_options(_Host) -> [].

init([Host, _Opts]) ->
  register_iq_handlers(Host),
  register_hooks(Host),
  {ok, #state{host = Host}}.

terminate(_Reason, State) ->
  Host = State#state.host,
  unregister_hooks(Host),
  unregister_iq_handlers(Host).

register_iq_handlers(Host) ->
  gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_GROUPCHAT, ?MODULE, process_groupchat),
  gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_GROUPCHAT_DELETE, ?MODULE, process_groupchat),
  gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_GROUPCHAT_CREATE, ?MODULE, process_groupchat).

unregister_iq_handlers(Host) ->
  gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_GROUPCHAT),
  gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_GROUPCHAT_DELETE),
  gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_GROUPCHAT_CREATE).

register_hooks(Host) ->
  ejabberd_hooks:add(disco_sm_features, Host, ?MODULE, disco_sm_features, 50).

unregister_hooks(Host) ->
  ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE, disco_sm_features, 50).

handle_call(_Request, _From, _State) ->
  erlang:error(not_implemented).

handle_cast({groupchat_created,Server,User,Chat,Lang}, State) ->
  case mod_nick_avatar:get_avatar_file(Server) of
    {ok, FileName, Bin} ->
      mod_groups_vcard:publish_avatar(Chat, Bin, FileName);
    _ ->
      ok
  end,
  ejabberd_hooks:run(groupchat_created, Server, [Server,User,Chat,Lang]),
  {noreply, State};
handle_cast(#iq{} = Iq, State) ->
  make_action(Iq),
  {noreply, State};
handle_cast(_Request, State) ->
  {noreply, State}.

%%process_iq(#iq{to = To} = Iq) ->
%%  process_iq(mod_groups_sql:search_for_chat(To#jid.server,To#jid.user),Iq).
%%
%%process_iq({selected,[]},Iq) ->
%%  Iq;
%%process_iq({selected,[_Name]},Iq) ->
%%  make_action(Iq).

process_groupchat(#iq{type = set, sub_els = [#xabbergroupchat{xmlns = ?NS_GROUPCHAT_CREATE, sub_els = []}]} = IQ) ->
  xmpp:make_error(IQ, xmpp:err_bad_request());
process_groupchat(#iq{type = set, lang = Lang, to = To, from = From, sub_els = [#xabbergroupchat{xmlns = ?NS_GROUPCHAT_CREATE, sub_els = SubEls} = Create]} = IQ) ->
  Creator = From#jid.luser,
  Server = To#jid.lserver,
  Host = From#jid.lserver,
  DecodedCreate = xmpp:decode_els(Create),
  PeerToPeer = xmpp:get_subtag(DecodedCreate, #xabbergroup_peer{}),
  case PeerToPeer of
    false ->
      Result = ejabberd_hooks:run_fold(create_groupchat, Server, [], [Server,Creator,Host,SubEls]),
      case Result of
        {ok,Query,Chat,User} ->
          Proc = gen_mod:get_module_proc(Server, ?MODULE),
          gen_server:cast(Proc, {groupchat_created,Server,User,Chat,Lang}),
          xmpp:make_iq_result(IQ,Query);
        exist ->
          xmpp:make_error(IQ, xmpp:err_conflict());
        _ ->
          xmpp:make_error(IQ, xmpp:err_bad_request())
      end;
    #xabbergroup_peer{} ->
      Result = ejabberd_hooks:run_fold(groupchat_peer_to_peer,
        Server, [], [Server,jid:to_string(jid:remove_resource(From)),PeerToPeer]),
      case Result of
        {ok,Created} ->
          xmpp:make_iq_result(IQ, Created);
        {exist,ExistedChat} ->
          ExistedChatJID = jid:from_string(ExistedChat),
          NewSub = [#xabbergroupchat_x{jid = ExistedChatJID}],
          NewIq = xmpp:set_els(IQ,NewSub),
          xmpp:make_error(NewIq, xmpp:err_conflict());
        stop ->
          ok;
        _ ->
          xmpp:make_error(IQ, xmpp:serr_internal_server_error(<<"Internal server error">>,<<"en">>))
      end;
    _ ->
      xmpp:make_error(IQ, xmpp:serr_internal_server_error(<<"Internal server error">>,<<"en">>))
  end;
process_groupchat(#iq{type=get, to= To, from = From,
  sub_els = [#xabbergroupchat_search{name = Name, anonymous = Anon, description = Desc, model = Model}]} = Iq) ->
  Server = To#jid.lserver,
  UserHost = From#jid.lserver,
  UserJid = jid:to_string(jid:remove_resource(From)),
  Query = mod_groups_chats:search(Server,Name,Anon,Model,Desc,UserJid,UserHost),
  xmpp:make_iq_result(Iq,Query);
process_groupchat(#iq{from = From, to = To, type = set, sub_els = [#xabbergroupchat{xmlns = ?NS_GROUPCHAT_DELETE, cdata = Localpart}]} = IQ) ->
  Server = To#jid.lserver,
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:make(Localpart,Server)),
  Result = ejabberd_hooks:run_fold(delete_groupchat, Server, [], [Server, User, Chat]),
  case Result of
    ok ->
      xmpp:make_iq_result(IQ);
    {error,Error} ->
      xmpp:make_error(IQ, Error);
    _ ->
      xmpp:make_error(IQ, xmpp:err_internal_server_error())
  end;
process_groupchat(IQ) ->
  xmpp:make_error(IQ, xmpp:err_bad_request()).

make_action(#iq{lang = Lang, to = To, from = From, type = get, sub_els = [#xmlel{name = <<"query">>,
  attrs = [{<<"xmlns">>,<<"https://xabber.com/protocol/groups#block">>}],
  children = []}]} = Iq) ->
  Server = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  User = jid:to_string(jid:remove_resource(From)),
  RightToBlock = mod_groups_restrictions:is_permitted(<<"set-restrictions">>,User,Chat),
  case mod_groups_users:check_if_exist(Server,Chat,User) of
    true when RightToBlock == true ->
      ejabberd_router:route(xmpp:make_iq_result(Iq, mod_groups_block:query(To)));
    _ ->
      ejabberd_router:route(xmpp:make_error(Iq, xmpp:err_not_allowed("You do not have permission to see the list of blocked users.",Lang)))
  end;
make_action(#iq{to = To, type = set, sub_els = [#xmlel{name = <<"unblock">>,
  attrs = [{<<"xmlns">>,<<"https://xabber.com/protocol/groups#block">>}]}]} = Iq) ->
  Server = To#jid.lserver,
  Result = ejabberd_hooks:run_fold(groupchat_unblock_hook, Server, [], [Iq]),
  case Result of
    not_ok ->
      ejabberd_router:route(xmpp:make_error(Iq,xmpp:err_not_allowed()));
    ok ->
      ejabberd_router:route(xmpp:make_iq_result(Iq))
  end;
make_action(#iq{to = To, type = set, sub_els = [#xmlel{name = <<"block">>,
  attrs = [{<<"xmlns">>,<<"https://xabber.com/protocol/groups#block">>}]}]} = Iq) ->
  Server = To#jid.lserver,
  Result = ejabberd_hooks:run_fold(groupchat_block_hook, Server, [], [Iq]),
  case Result of
    not_ok ->
      ejabberd_router:route(xmpp:make_error(Iq,xmpp:err_not_allowed()));
    _ ->
      ejabberd_router:route(xmpp:make_iq_result(Iq))
  end;
make_action(#iq{type = get, sub_els = [#xmlel{name = <<"query">>,
  attrs = [{<<"xmlns">>, ?NS_VERSION}]}]} = Iq) ->
  Name = #xmlel{name = <<"name">>,children = [{xmlcdata, <<"XabberGroups">>}]},
  Version = #xmlel{name = <<"version">>,children = [{xmlcdata, <<"0.1">>}]},
  Result =   #xmlel{name = <<"query">>, attrs = [{<<"xmlns">>, ?NS_VERSION}],
    children = [Name, Version]
  },
  ejabberd_router:route(xmpp:make_iq_result(Iq,Result));
make_action(#iq{type = get, sub_els = [#xmlel{name = <<"query">>,
  attrs = [{<<"xmlns">>,<<"jabber:iq:last">>}]}]} = Iq) ->
  Result = mod_groups_vcard:iq_last(),
  ejabberd_router:route(xmpp:make_iq_result(Iq,Result));
make_action(#iq{type = get, sub_els = [#xmlel{name = <<"time">>,
  attrs = [{<<"xmlns">>,<<"urn:xmpp:time">>}]}]} = Iq) ->
  R = mod_time:process_local_iq(Iq),
  ejabberd_router:route(R);
make_action(#iq{type = result, sub_els = [#xmlel{name = <<"vCard">>,
  attrs = [{<<"xmlns">>,<<"vcard-temp">>}], children = _Children}]} = Iq) ->
  mod_groups_vcard:handle(Iq);
make_action(#iq{type = set, to = To, from = From,
  sub_els = [#xmlel{name = <<"update">>, attrs = [
  {<<"xmlns">>,?NS_GROUPCHAT}], children = _Children} = X]} = Iq) ->
  User = jid:to_string(jid:remove_resource(From)),
  Server = To#jid.lserver,
  Group = jid:to_string(jid:remove_resource(To)),
  case mod_groups_chats:handle_update_query(Server, Group, User, xmpp:decode(X)) of
    ok ->
      ejabberd_router:route(xmpp:make_iq_result(Iq));
    {error, Err} ->
      ejabberd_router:route(xmpp:make_error(Iq,Err))
  end;
make_action(#iq{type = set, sub_els = [#xmlel{name = <<"pubsub">>,
  attrs = [{<<"xmlns">>,<<"http://jabber.org/protocol/pubsub">>}]}]} = Iq) ->
  R = mod_groups_vcard:handle_pubsub(xmpp:decode_els(Iq)),
  ejabberd_router:route(R);
make_action(#iq{type = get, sub_els = [#xmlel{name = <<"pubsub">>,
  attrs = [{<<"xmlns">>,<<"http://jabber.org/protocol/pubsub">>}]}]} = Iq) ->
  R = mod_groups_vcard:handle_request(Iq),
  ejabberd_router:route(R);
make_action(#iq{type = set, sub_els = [#xmlel{name = <<"invite">>,
  attrs = [{<<"xmlns">>,<<"https://xabber.com/protocol/groups#invite">>}]}]} = Iq) ->
  #iq{from = From, to = To, sub_els = Sub} = Iq,
  Server = To#jid.lserver,
  Admin = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  DecEls = lists:map(fun(N)-> xmpp:decode(N) end, Sub),
  Invite = lists:keyfind(xabbergroupchat_invite,1,DecEls),
  #xabbergroupchat_invite{invite_jid = User, reason = _Reason, send = _Send} = Invite,
  Result = ejabberd_hooks:run_fold(groupchat_invite_hook, Server, [], [{Admin,Chat,Server,Invite}]),
  case Result of
    forbidden ->
      ejabberd_router:route(xmpp:make_error(Iq,xmpp:err_not_allowed(<<"You have no permission to invite">>,<<>>)));
    ok ->
      ejabberd_router:route(xmpp:make_iq_result(Iq));
    exist ->
      ResIq = case User of
                undefined ->
                  xmpp:make_error(Iq,xmpp:err_conflict(<<"User was already invited">>,<<>>));
                _ ->
                  xmpp:make_error(Iq,xmpp:err_conflict(<<"User ",User/binary," was already invited">>,<<>>))
              end,
      ejabberd_router:route(ResIq);
    not_ok ->
      ResIq = case User of
                undefined ->
                  xmpp:make_error(Iq,xmpp:err_not_allowed(<<"User is in ban list">>,<<>>));
                _ ->
                  xmpp:make_error(Iq,xmpp:err_not_allowed(<<"User ",User/binary," is in ban list">>,<<>>))
              end,
      ejabberd_router:route(ResIq)
  end;
make_action(#iq{type = get, sub_els = [#xmlel{name = <<"query">>,
  attrs = [{<<"xmlns">>,<<"https://xabber.com/protocol/groups#invite">>}]}]} = Iq) ->
  #iq{from = From, to = To} = Iq,
  Server = To#jid.lserver,
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  Query = case mod_groups_restrictions:is_permitted(<<"set-restrictions">>, User, Chat) of
            true ->
              mod_groups_invites:get_invited_users(Server, Chat);
            _ ->
              mod_groups_invites:get_invited_users(Server, Chat, User)
          end,
  ResIq = xmpp:make_iq_result(Iq,Query),
  ejabberd_router:route(ResIq);
make_action(#iq{to = To, type = get, sub_els = [#xmlel{name = <<"query">>,
  attrs = [{<<"xmlns">>,<<"http://jabber.org/protocol/disco#items">>}]}]} = Iq) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  Data = #xmlel{name = <<"item">>, attrs = [{<<"jid">>,Chat},{<<"node">>,<<"urn:xmpp:avatar:data">>}]},
  MetaData = #xmlel{name = <<"item">>, attrs = [{<<"jid">>,Chat},{<<"node">>,<<"urn:xmpp:avatar:metadata">>}]},
  Children = [Data,MetaData],
  Query = #xmlel{name = <<"query">>, attrs = [{<<"xmlns">>,<<"http://jabber.org/protocol/disco#items">>}],
  children = Children},
  ejabberd_router:route(xmpp:make_iq_result(Iq,Query));
make_action(#iq{type = set, sub_els = [#xmlel{name = <<"revoke">>,
  attrs = [{<<"xmlns">>,<<"https://xabber.com/protocol/groups#invite">>}]}]} = Iq) ->
  #iq{from = From, to = To,sub_els = Sub} = Iq,
  Server = To#jid.lserver,
  Admin = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  DecEls = lists:map(fun(N)-> xmpp:decode(N) end, Sub),
  Revoke = lists:keyfind(xabbergroupchat_revoke,1,DecEls),
  #xabbergroupchat_revoke{jid = User} = Revoke,
  case mod_groups_invites:revoke(Server,User,Chat,Admin) of
    ok ->
      ejabberd_hooks:run(revoke_invite, Server, [Chat, User]),
      ResIq = xmpp:make_iq_result(Iq),
      ejabberd_router:route(ResIq);
    _ ->
      Err = xmpp:err_item_not_found(),
      ejabberd_router:route(xmpp:make_error(Iq,Err))
  end;
make_action(#iq{to = To,type = get, sub_els = [#xmlel{name = <<"query">>,
  attrs = [{<<"xmlns">>,<<"http://jabber.org/protocol/disco#info">>}]}]} = Iq) ->
  ChatJID = jid:to_string(jid:tolower(jid:remove_resource(To))),
  Server = To#jid.lserver,
  {Name, Anonymous, _Search, Model, Desc, _ChatMessage, _Contacts,
    _Domains, _Parent, _Status} = mod_groups_chats:get_info(ChatJID, Server),
  Identity = #xmlel{name = <<"identity">>,
  attrs = [{<<"category">>,<<"conference">>},{<<"type">>,<<"groupchat">>},{<<"name">>,Name}]},
  FeatureList = [<<"urn:xmpp:avatar:metadata">>,<<"urn:xmpp:avatar:data">>,
    <<"jabber:iq:last">>,<<"urn:xmpp:time">>,<<"jabber:iq:version">>,<<"urn:xmpp:avatar:metadata+notify">>,
    <<"https://xabber.com/protocol/groups">>,<<"https://xabber.com/protocol/groups#voice-permissions">>,
  <<"http://jabber.org/protocol/disco#info">>,<<"http://jabber.org/protocol/disco#items">>,
    <<"http://jabber.org/protocol/caps">>,<<"http://jabber.org/protocol/chatstates">>],
  Features = lists:map(fun(N) ->
    #xmlel{name = <<"feature">>,
      attrs = [{<<"var">>,N}]} end, lists:sort(FeatureList)
  ),
  X = x_element_chat(Desc,Anonymous,Model),
  Els = [Identity]++Features++[X],
  Q = query_disco_info(Els),
  ejabberd_router:route(xmpp:make_iq_result(Iq,Q));
make_action(#iq{type = set, sub_els = [#xmlel{name = <<"query">>,
  attrs = [{<<"xmlns">>,<<"urn:xmpp:mam:2">>},{<<"queryid">>,_QID}]}]} = Iq) ->
  process_mam_iq(Iq);
make_action(#iq{type = set, sub_els = [#xmlel{name = <<"query">>,
  attrs = [{<<"xmlns">>,<<"urn:xmpp:mam:1">>},{<<"queryid">>,_QID}]}]} = Iq) ->
  process_mam_iq(Iq);
make_action(#iq{type = set, sub_els = [#xmlel{name = <<"query">>,
  attrs = [{<<"xmlns">>,<<"urn:xmpp:mam:2">>}]}]} = Iq) ->
  process_mam_iq(Iq);
make_action(#iq{type = set, sub_els = [#xmlel{name = <<"query">>,
  attrs = [{<<"xmlns">>,<<"urn:xmpp:mam:1">>}]}]} = Iq) ->
  process_mam_iq(Iq);
%%make_action(#iq{from = From, to = To, type = get,
%%  sub_els = [#xmlel{name = <<"query">>,
%%    attrs = [{<<"xmlns">>,?NS_XABBER_SYNCHRONIZATION},
%%      {<<"stamp">>,Stamp}]}]} = IQ) ->
%%  User = jid:to_string(jid:remove_resource(From)),
%%  Chat = jid:to_string(jid:remove_resource(To)),
%%  LServer = To#jid.lserver,
%%  Result = ejabberd_hooks:run_fold(synchronization_request, LServer, [],
%%    [LServer,User,Chat,Stamp]),
%%  case Result of
%%    {ok,Sync} ->
%%      ?DEBUG("Send iq ~p~n res ~p",[IQ,Sync]),
%%      ejabberd_router:route(xmpp:make_iq_result(IQ,Sync));
%%    _ ->
%%      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()))
%%  end;
make_action(#iq{from = UserJID, to = ChatJID, type = result,
  sub_els = [#pubsub{items = #ps_items{node = <<"urn:xmpp:avatar:metadata">>,
    items = [#ps_item{id = _Hash, sub_els = Subs}]}}]}) ->
  ?DEBUG("Catch pubsub meta ~p",[Subs]),
  try
    MD = lists:map(fun(E) -> xmpp:decode(E) end, Subs),
    Meta = lists:keyfind(avatar_meta,1,MD),
    mod_groups_vcard:handle_avatar_meta(ChatJID,UserJID,Meta)
  catch _:_ ->
    ok
  end;
make_action(#iq{from = UserJID, to = ChatJID, type = result,
  sub_els = [#pubsub{items = #ps_items{node = <<"urn:xmpp:avatar:data">>,
    items = [#ps_item{id = Hash, sub_els = Subs}]}}]}) ->
  ?DEBUG("Catch pubsub data result1 iq ~p",[Hash]),
  try
    MD = lists:map(fun(E) -> xmpp:decode(E) end, Subs),
    Data = lists:keyfind(avatar_data,1,MD),
    mod_groups_vcard:handle_avatar_data(ChatJID,UserJID,Hash,Data)
  catch _:_ ->
    ok
  end;
make_action(#iq{type = result, sub_els = [#xmlel{name = <<"pubsub">>,
  attrs = _Attrs, children = _Children}] = SubEls} = IQ) ->
  ?DEBUG("Catch pubsub result2 iq ~p",[IQ]),
  SubElsDec = lists:map(fun(El) -> xmpp:decode(El) end, SubEls),
  DECIQ = IQ#iq{sub_els = SubElsDec},
  make_action(DECIQ);
make_action(#iq{type = result} = IQ) ->
  ?DEBUG("Drop result iq ~p",[IQ]);
make_action(#iq{type = error} = IQ) ->
  ?DEBUG("Drop error iq ~p", [IQ]);
make_action(IQ) ->
  DecIQ = xmpp:decode_els(IQ),
  process_groupchat_iq(DecIQ).

process_groupchat_iq(#iq{type = set, sub_els = [#mam_query{}]} = Iq) ->
  process_mam_iq(Iq);
process_groupchat_iq(#iq{from = From, to = To, type = get,
  sub_els = [#xabber_retract_query{version = undefined,
    'less-than' = undefined}]} = IQ) ->
  case mod_groups_retract:get_version_reply(From, To) of
    {ok, Reply} ->
      ejabberd_router:route(xmpp:make_iq_result(IQ,Reply));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()))
  end,
  ignore;
process_groupchat_iq(#iq{from = From, to = To, type = get,
  sub_els = [#xabber_retract_query{version = Version, 'less-than' = Less}]} = IQ) ->
  Group = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  case mod_groups_retract:send_rewrite_archive(Server, From,
    Group, Version, Less) of
    {ok, CurrentVer} ->
      ejabberd_router:route(xmpp:make_iq_result(IQ,
        #xabber_retract_query{version=CurrentVer}));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()))
  end,
  ignore;
process_groupchat_iq(#iq{lang = Lang, from = From, to = To, type = set,
  sub_els = [#xabbergroup_kick{} = Kick]} = IQ) ->
  LServer = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  Admin = jid:to_string(jid:remove_resource(From)),
  case ejabberd_hooks:run_fold(groupchat_user_kick, LServer, [],
    [LServer,Chat,Admin,Kick,Lang]) of
    {error, Error} ->
      ejabberd_router:route(xmpp:make_error(IQ, Error));
    R when is_list(R) ->
      ejabberd_router:route(xmpp:make_iq_result(IQ));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_internal_server_error()))
  end,
  ignore;
process_groupchat_iq(#iq{from = From, to = To, type = get,
  sub_els = [#xabbergroupchat{xmlns = ?NS_GROUPCHAT_MEMBERS, id = ID,
    rsm = undefined, version = undefined, sub_els = []}]} = IQ) ->
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  LServer = To#jid.lserver,
  IsInChat = mod_groups_users:is_in_chat(LServer,Chat,User),
  case IsInChat of
    true ->
      Res = mod_groups_users:get_user_from_chat(LServer,Chat,User,ID),
      ejabberd_router:route(xmpp:make_iq_result(IQ,Res));
    _ ->
      Err = xmpp:make_error(IQ,xmpp:err_not_allowed()),
      ejabberd_router:route(Err)
  end;
process_groupchat_iq(#iq{from = From, to = To, type = get,
  sub_els = [#xabbergroupchat{xmlns = ?NS_GROUPCHAT_MEMBERS,
    version = Version, rsm = RSM, sub_els = []}]} = IQ) ->
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  LServer = To#jid.lserver,
  IsInChat = mod_groups_users:is_in_chat(LServer,Chat,User),
  case IsInChat of
    true ->
      Res = mod_groups_users:get_users_from_chat(LServer,Chat,User,RSM,Version),
      ejabberd_router:route(xmpp:make_iq_result(IQ,Res));
    _ ->
      Err = xmpp:make_error(IQ,xmpp:err_not_allowed()),
      ejabberd_router:route(Err)
  end;
process_groupchat_iq(#iq{lang = Lang, from = From, to = To, type = set,
  sub_els = [#xabbergroupchat{xmlns = ?NS_GROUPCHAT_MEMBERS,
    sub_els = [#xabbergroupchat_user_card{id = ID,
      nickname = Nickname, badge = Badge}]}]} = IQ) ->
  LServer = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  Admin = jid:to_string(jid:remove_resource(From)),
  case ejabberd_hooks:run_fold(groupchat_update_user_hook,
    LServer, [], [LServer,Chat,Admin,ID,Nickname,Badge,Lang]) of
    ok ->
      ejabberd_router:route(xmpp:make_iq_result(IQ));
    {error, Error} ->
      ejabberd_router:route(xmpp:make_error(IQ, Error));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:serr_internal_server_error()))
  end;
process_groupchat_iq(#iq{to = To, type = get, sub_els = [#vcard_temp{}]} = IQ) ->
  LUser = To#jid.luser,
  Server = To#jid.lserver,
  Vcard = mod_groups_vcard:get_vcard(LUser,Server),
  ejabberd_router:route(xmpp:make_iq_result(IQ,Vcard));
process_groupchat_iq(#iq{lang = Lang, type = get, from = From, to = To,
  sub_els = [#xabbergroupchat_query_rights{
    sub_els = [#xabbergroupchat_user_card{id = ID}]}]} = IQ)
  when ID == <<>> orelse ID == <<"">> ->
  User = jid:to_string(jid:remove_resource(From)),
  LServer = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  case ejabberd_hooks:run_fold(request_own_rights, LServer, [], [LServer,User,Chat,Lang]) of
    {error, Error} ->
      ejabberd_router:route(xmpp:make_error(IQ, Error));
    {ok,Form} ->
      ejabberd_router:route(xmpp:make_iq_result(IQ,Form));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:serr_internal_server_error()))
  end;
process_groupchat_iq(#iq{lang = Lang, type = get, from = From, to = To,
  sub_els = [#xabbergroupchat_query_rights{
    sub_els = [#xabbergroupchat_user_card{id = ID}]}]} = IQ) ->
  User = jid:to_string(jid:remove_resource(From)),
  LServer = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  case ejabberd_hooks:run_fold(request_change_user_settings, LServer, [],
    [LServer,User,Chat,ID,Lang]) of
    not_ok ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()));
    not_exist ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_item_not_found()));
    {ok,Form} ->
      ejabberd_router:route(xmpp:make_iq_result(IQ,Form));
    _ ->
      ejabberd_router:route(xmpp:make_iq_result(IQ))
  end;
process_groupchat_iq(#iq{lang = Lang, type = set, from = From, to = To,
  sub_els = [#xabbergroupchat_query_rights{
    sub_els = [#xdata{type = 'submit', fields = FS}]}]} = IQ) ->
  User = jid:to_string(jid:remove_resource(From)),
  LServer = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  IDEl = [Values|| #xdata_field{type = Type, var = Var, values = Values} <- FS,
    Var == <<"user-id">>, Type == 'hidden'],
  ID = list_to_binary(IDEl),
case ID of
  <<>> ->
    ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_item_not_found()));
  _ ->
    Result = ejabberd_hooks:run_fold(change_user_settings, LServer, FS,
      [LServer,User,Chat,ID,Lang]),
    case Result of
      {ok,Form} ->
        ejabberd_router:route(xmpp:make_iq_result(IQ,Form));
      not_ok ->
        ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()));
      not_exist ->
        ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_item_not_found()));
      bad_request ->
        ejabberd_router:route(xmpp:make_error(IQ,xmpp:err_bad_request()));
      _ ->
        ejabberd_router:route(xmpp:make_error(IQ,xmpp:err_internal_server_error()))
    end
end;
process_groupchat_iq(#iq{from = From, to = To, type = set, sub_els = [
  #xabber_retract_message{symmetric = true} = Retract]} = IQ) ->
  R = case mod_groups_retract:retract_message(From, To, Retract) of
        ok ->
          xmpp:make_iq_result(IQ);
        {error, not_found} ->
          xmpp:make_error(IQ, xmpp:err_item_not_found());
        {error, not_allowed} ->
          xmpp:make_error(IQ, xmpp:err_not_allowed());
        _ ->
          xmpp:make_error(IQ, xmpp:err_internal_server_error())
      end,
  ejabberd_router:route(R),
  ignore;
process_groupchat_iq(#iq{from = From, to = To, type = set, sub_els = [
  #xabber_retract_user{symmetric = true} = Retract]} = IQ) ->
  R = case mod_groups_retract:retract_user_messages(From, To, Retract) of
        ok ->
          xmpp:make_iq_result(IQ);
        _ ->
          xmpp:make_error(IQ, xmpp:err_not_allowed())
      end,
  ejabberd_router:route(R),
  ignore;
process_groupchat_iq(#iq{from = From, to = To, type = set, sub_els = [
  #xabber_retract_all{symmetric = true}]} = IQ) ->
  R = case mod_groups_retract:retract_all_messages(From, To) of
        ok ->
          xmpp:make_iq_result(IQ);
        _ ->
          xmpp:make_error(IQ, xmpp:err_not_allowed())
  end,
  ejabberd_router:route(R),
  ignore;
process_groupchat_iq(#iq{from = From, to = To, type = set, sub_els = [
  #xabber_replace{} = Replace]}=IQ) ->
  R = case mod_groups_retract:rewrite_message(From, To, Replace) of
        ok ->
          xmpp:make_iq_result(IQ);
        _ ->
          xmpp:make_error(IQ, xmpp:err_not_allowed())
      end,
  ejabberd_router:route(R),
  ignore;
process_groupchat_iq(#iq{lang = Lang, type = get, from = From, to = To,
  sub_els = [#xabbergroupchat{xmlns = ?NS_GROUPCHAT_DEFAULT_RIGHTS}]} = IQ) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  User = jid:to_string(jid:remove_resource(From)),
  Result = ejabberd_hooks:run_fold(groupchat_default_rights_form, Server, [],
    [User,Chat,Server,Lang]),
  case Result of
    {ok, Query} ->
      ejabberd_router:route(xmpp:make_iq_result(IQ, Query));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()))
  end;
process_groupchat_iq(#iq{lang = Lang, type = set, from = From, to = To,
  sub_els = [#xabbergroupchat{xmlns = ?NS_GROUPCHAT_DEFAULT_RIGHTS,
    sub_els = [#xdata{type = submit, fields = FS}]}]} = IQ) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  User = jid:to_string(jid:remove_resource(From)),
  Result = ejabberd_hooks:run_fold(set_groupchat_default_rights, Server, FS,
    [User,Chat,Server,Lang]),
  case Result of
    {ok, Query} ->
      ejabberd_router:route(xmpp:make_iq_result(IQ, Query));
    bad_request ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_bad_request()));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()))
  end;
process_groupchat_iq(#iq{type = get, from = From, to = To,
  sub_els = [#xabbergroupchat{xmlns = ?NS_GROUPCHAT_STATUS}]} = IQ) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  User = jid:to_string(jid:remove_resource(From)),
  Result = ejabberd_hooks:run_fold(group_status_info, Server, [], [User,Chat,Server]),
  case Result of
    {ok, Form} ->
      ejabberd_router:route(xmpp:make_iq_result(IQ,
        #xabbergroupchat{xmlns = ?NS_GROUPCHAT_STATUS, sub_els = [Form]}));
    {error, Err} ->
      ejabberd_router:route(xmpp:make_error(IQ, Err));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_bad_request()))
  end;
process_groupchat_iq(#iq{lang = Lang, type = set, from = From, to = To,
  sub_els = [#xabbergroupchat{xmlns = ?NS_GROUPCHAT_STATUS,
    sub_els = [#xdata{type = submit, fields = FSRaw}]}]} = IQ) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  User = jid:to_string(jid:remove_resource(From)),
  FS1 = mod_groups_chats:filter_fixed_fields(FSRaw),
  DecodedFS = mod_groups_chats:parse_status_query(FS1,Lang),
  case DecodedFS of
    {ok,FS} ->
      Result = ejabberd_hooks:run_fold(group_status_change, Server, [], [User,Chat,Server,FS]),
      case Result of
        {ok, Form, Status} ->
          ejabberd_hooks:run(groupchat_properties_changed,Server,[Server, Chat, User,
            [{status_changed, true}], Status]),
          ejabberd_router:route(xmpp:make_iq_result(IQ,
            #xabbergroupchat{xmlns = ?NS_GROUPCHAT_STATUS, sub_els = [Form]}));
        {error, Err} ->
          ejabberd_router:route(xmpp:make_error(IQ, Err));
        _ ->
          ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_bad_request()))
      end;
    {error, Err} ->
      ejabberd_router:route(xmpp:make_error(IQ, Err));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_bad_request()))
  end;
process_groupchat_iq(#iq{type = get, from = From, to = To,
  sub_els = [#xabbergroupchat{xmlns = ?NS_GROUPCHAT}]} = IQ) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  User = jid:to_string(jid:remove_resource(From)),
  Result = ejabberd_hooks:run_fold(groupchat_info, Server, [], [User,Chat,Server]),
  case Result of
    {ok, Form} ->
      ejabberd_router:route(xmpp:make_iq_result(IQ,
        #xabbergroupchat{xmlns = ?NS_GROUPCHAT, sub_els = [Form]}));
    {error, Err} ->
      ejabberd_router:route(xmpp:make_error(IQ, Err));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_bad_request()))
  end;
process_groupchat_iq(#iq{type = set, from = From, to = To,
  sub_els = [#xabbergroupchat{xmlns = ?NS_GROUPCHAT,
    sub_els = [#xdata{type = submit, fields = FS}]}]} = IQ) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  User = jid:to_string(jid:remove_resource(From)),
  Result = ejabberd_hooks:run_fold(groupchat_info_change, Server, [], [User,Chat,Server,FS]),
  case Result of
    {ok, Form, Status, Properties} ->
      ejabberd_hooks:run(groupchat_properties_changed,Server,[Server, Chat, User, Properties, Status]),
      ejabberd_router:route(xmpp:make_iq_result(IQ, #xabbergroupchat{xmlns = ?NS_GROUPCHAT, sub_els = [Form]}));
    {error, Err} ->
      ejabberd_router:route(xmpp:make_error(IQ, Err));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_bad_request()))
  end;
process_groupchat_iq(#iq{type = set, from = From, to = To, sub_els = [#xabbergroup_decline{}]} = IQ) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  User = jid:to_string(jid:remove_resource(From)),
  Result = ejabberd_hooks:run_fold(groupchat_decline_invite, Server, [], [User,Chat,Server]),
  case Result of
    ok ->
      ejabberd_router:route(xmpp:make_iq_result(IQ));
    {error,Error} ->
      ejabberd_router:route(xmpp:make_error(IQ,Error));
    _ ->
      Err = xmpp:err_internal_server_error(),
      ejabberd_router:route(xmpp:make_error(IQ,Err))
  end;
  process_groupchat_iq(#iq{type = result} = IQ) ->
  ?DEBUG("Drop result iq ~p",[IQ]);
process_groupchat_iq(#iq{type = error} = IQ) ->
  ?DEBUG("Drop error iq ~p", [IQ]);
process_groupchat_iq(IQ) ->
  ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_bad_request())).

-spec disco_sm_features({error, stanza_error()} | {result, [binary()]} | empty,
                                             jid(), jid(), binary(), binary()) ->
                                {error, stanza_error()} | {result, [binary()]}.
disco_sm_features({error, Err}, _From, _To, _Node, _Lang) ->
        {error, Err};
disco_sm_features(empty, _From, _To, <<"">>, _Lang) ->
        {result, [?NS_GROUPCHAT,?NS_GROUPCHAT_RETRACT,?NS_GROUPCHAT_RETRACT_HISTORY]};
disco_sm_features({result, Feats}, _From, _To, <<"">>, _Lang) ->
        {result, [?NS_GROUPCHAT_RETRACT_HISTORY|[?NS_GROUPCHAT_RETRACT|[?NS_GROUPCHAT|Feats]]]};
disco_sm_features(Acc, _From, _To, _Node, _Lang) ->
        Acc.


%% Internal Functions
x_element_chat(Desc,Anon,Model) ->
  DescField = xdata_field(<<"description">>,<<"Description">>,Desc),
  AnonField = xdata_field(<<"privacy">>,<<"Privacy">>,Anon),
  ModelField = xdata_field(<<"model">>,<<"Access model">>,Model),
  HiddenField = hidden_field(),
  Fields = [HiddenField,DescField,AnonField,ModelField],
  #xmlel{name = <<"x">>, attrs = [{<<"xmlns">>,<<"jabber:x:data">>},{<<"type">>,<<"result">>}],
    children = Fields}.

hidden_field() ->
  #xmlel{name = <<"field">>, attrs = [{<<"var">>,<<"FORM_TYPE">>},{<<"type">>,<<"hidden">>}],
    children = [#xmlel{name = <<"value">>,
      children = [{xmlcdata,<<"https://xabber.com/protocol/groups#info">>}]}]}.

xdata_field(Var,Label,Value) ->
  #xmlel{name = <<"field">>, attrs = [{<<"var">>,Var},{<<"label">>,Label}],
    children = [#xmlel{name = <<"value">>, children = [{xmlcdata,Value}]}]}.

query_disco_info(Items) ->
  {xmlel,<<"query">>,[{<<"xmlns">>,?NS_DISCO_INFO}],
    Items}.

process_mam_iq(#iq{from = From, lang = Lang, id = Id, to = To, meta = Meta, type = Type,
  sub_els = [SubEl]} = Iq) ->
  User = jid:to_string(jid:remove_resource(From)),
  Server = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  SubElD = xmpp:decode(SubEl),
  IQDecoded = #iq{from = To, lang = Lang, to = From, meta = Meta,
    sub_els = [SubElD], type = Type, id = Id},
  case mod_groups_users:check_if_exist(Server,Chat,User) of
    true ->
      NewSubEls = change_query(SubElD, Server, Chat, Lang),
      mod_mam:process_iq_v0_3(IQDecoded#iq{sub_els = NewSubEls});
    _ ->
      GlobalIndexes = mod_groups:get_option(Server, global_indexs),
      IsIndexed =  case lists:member(User,GlobalIndexes) of
                   true ->
                     mod_groups_chats:is_global_indexed(Server,Chat);
                   _ -> false
                 end,
      if
        IsIndexed ->
          mod_mam:process_iq_v0_3(IQDecoded);
        true ->
          ?DEBUG("not allowed",[]),
          xmpp:make_error(Iq, xmpp:err_not_allowed())
      end
  end.

change_query(QueryEl, Server, Chat, Lang) ->
  case mod_mam:parse_query(QueryEl, Lang) of
    {ok, Query} ->
      Q1 = replace_id_to_jid(Query, Server, Chat),
      %% Messages in archive are stored with "urn:xabber:chat" type.
      Q2 = lists:keydelete('conversation-type', 1, Q1),
      Fields = mam_query:encode(Q2),
      [QueryEl#mam_query{xdata =
      #xdata{type = 'submit', fields = Fields}}];
    {error, _Err} ->
      []
  end.

replace_id_to_jid(Query, Server, Chat) ->
  case lists:keyfind('with', 1, Query) of
    {_, Value} ->
      ID = jid:to_string(Value),
      JS = mod_groups_users:get_user_by_id(Server, Chat , ID),
      lists:keyreplace('with', 1, Query,
        {'with', jid:from_string(JS)});
    _ -> Query
  end.
