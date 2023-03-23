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
-export([process_groupchat/1,process_iq/1,make_action/1]).

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
  case nick_generator:get_avatar_file(Server) of
    {ok, FileName, Bin} ->
      mod_groups_vcard:publish_avatar(Chat, Bin, FileName);
    _ ->
      ok
  end,
  ejabberd_hooks:run(groupchat_created, Server, [Server,User,Chat,Lang]),
  {noreply, State};
handle_cast(_Request, State) ->
  {noreply, State}.

process_iq(#iq{to = To} = Iq) ->
  process_iq(mod_groups_sql:search_for_chat(To#jid.server,To#jid.user),Iq).

process_iq({selected,[]},Iq) ->
  Iq;
process_iq({selected,[_Name]},Iq) ->
  make_action(Iq).

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
  Query = mod_groups_inspector:search(Server,Name,Anon,Model,Desc,UserJid,UserHost),
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
  ChatJid = jid:to_string(jid:remove_resource(To)),
  IsOwner = mod_groups_restrictions:is_owner(Server,ChatJid,User),
  case mod_groups_restrictions:is_permitted(<<"change-group">>,User,ChatJid) of
    true ->
      Xa = xmpp:decode(X),
      NewOwner = Xa#xabbergroupchat_update.owner,
      case NewOwner of
        undefined ->
          case mod_groups_inspector:update_chat(Server,To,ChatJid,User,Xa) of
            ok ->
              ejabberd_router:route(xmpp:make_iq_result(Iq));
            {error, Err} ->
              ejabberd_router:route(xmpp:make_error(Iq,Err))
          end;
        _  when IsOwner == yes->
          Expires = <<"0">>,
          Rule1 = <<"owner">>,
          IssuedBy = User,
          mod_groups_restrictions:insert_rule(Server,ChatJid,NewOwner,Rule1,Expires,IssuedBy),
          mod_groups_restrictions:delete_rule(Server,ChatJid,User,<<"owner">>)
      end;
    _ ->
      ejabberd_router:route(xmpp:make_error(Iq,xmpp:err_not_allowed()))
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
              mod_groups_inspector:get_invited_users(Server, Chat);
            _ ->
              mod_groups_inspector:get_invited_users(Server, Chat, User)
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
  case mod_groups_inspector:revoke(Server,User,Chat,Admin) of
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
  {selected,[{Name,Anonymous,_Search,Model,Desc,_Message,_ContactList,_DomainList}]} =
    mod_groups_sql:get_information_of_chat(ChatJID,Server),
  Identity = #xmlel{name = <<"identity">>,
  attrs = [{<<"category">>,<<"conference">>},{<<"type">>,<<"groupchat">>},{<<"name">>,Name}]},
  FeatureList = [<<"urn:xmpp:avatar:metadata">>,<<"urn:xmpp:avatar:data">>,
    <<"jabber:iq:last">>,<<"urn:xmpp:time">>,<<"jabber:iq:version">>,<<"urn:xmpp:avatar:metadata+notify">>,
    <<"https://xabber.com/protocol/groups">>,<<"https://xabber.com/protocol/groups#voice-permissions">>,
  <<"http://jabber.org/protocol/disco#info">>,<<"http://jabber.org/protocol/disco#items">>,
    <<"http://jabber.org/protocol/caps">>],
  Features = lists:map(fun(N) ->
    #xmlel{name = <<"feature">>,
      attrs = [{<<"var">>,N}]} end, lists:sort(FeatureList)
  ),
  X = x_element_chat(Desc,Anonymous,Model),
  Els = [Identity]++Features++[X],
  Q = query_disco_info(Els),
  ejabberd_router:route(xmpp:make_iq_result(Iq,Q));
make_action(#iq{type = set, sub_els = [#xmlel{name = <<"query">>, attrs = [{<<"xmlns">>,<<"urn:xmpp:mam:2">>},{<<"queryid">>,_QID}]}]} = Iq) ->
  process_mam_iq(Iq);
make_action(#iq{type = set, sub_els = [#xmlel{name = <<"query">>, attrs = [{<<"xmlns">>,<<"urn:xmpp:mam:1">>},{<<"queryid">>,_QID}]}]} = Iq) ->
  process_mam_iq(Iq);
make_action(#iq{type = set, sub_els = [#xmlel{name = <<"query">>, attrs = [{<<"xmlns">>,<<"urn:xmpp:mam:2">>}]}]} = Iq) ->
  process_mam_iq(Iq);
make_action(#iq{type = set, sub_els = [#xmlel{name = <<"query">>, attrs = [{<<"xmlns">>,<<"urn:xmpp:mam:1">>}]}]} = Iq) ->
  process_mam_iq(Iq);
make_action(#iq{from = From, to = To, type = get,
  sub_els =
  [#xmlel{name = <<"query">>, attrs = [{<<"xmlns">>,?NS_XABBER_SYNCHRONIZATION},{<<"stamp">>,Stamp}]}]} = IQ) ->
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  LServer = To#jid.lserver,
  Result = ejabberd_hooks:run_fold(synchronization_request, LServer, [], [LServer,User,Chat,Stamp]),
  case Result of
    {ok,Sync} ->
      ?DEBUG("Send iq ~p~n res ~p",[IQ,Sync]),
      ejabberd_router:route(xmpp:make_iq_result(IQ,Sync));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()))
  end;
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
make_action(#iq{type = result, sub_els = [#xmlel{name = <<"pubsub">>, attrs = _Attrs, children = _Children}] = SubEls} = IQ) ->
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
  sub_els = [#xabber_retract_query{version = undefined, 'less-than' = undefined}]} = IQ) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  CheckUser = mod_groups_users:check_user(Server,jid:to_string(jid:remove_resource(From)),Chat),
  case CheckUser of
    not_exist ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()));
    _ ->
      Version = mod_groups_retract:get_version(Server,Chat),
      ejabberd_router:route(xmpp:make_iq_result(IQ, #xabber_retract_query{version=Version}))
  end,
  ignore;
process_groupchat_iq(#iq{from = From, to = To, type = get,
  sub_els = [#xabber_retract_query{version = Version, 'less-than' = Less}]} = IQ) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  FromChat = jid:replace_resource(To,<<"Group">>),
  Server = To#jid.lserver,
  Result = ejabberd_hooks:run_fold(retract_query, Server, [], [{Server,From,Chat,Version,Less}]),
    case Result of
      ok ->
        ejabberd_router:route(xmpp:make_iq_result(IQ)),
        ignore;
      too_much ->
        CurrentVersion = mod_groups_retract:get_version(Server,Chat),
        Invalidate = #xabber_retract_invalidate{version = CurrentVersion},
        ejabberd_router:route(#message{from = FromChat, to = From, id = randoms:get_string(), type = headline, sub_els = [Invalidate]}),
        ejabberd_router:route(xmpp:make_iq_result(IQ)),
        ignore;
      _ ->
        ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed())),
        ignore
    end;
process_groupchat_iq(#iq{lang = Lang, from = From, to = To, type = set, sub_els = [#xabbergroup_kick{} = Kick]} = IQ) ->
  LServer = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  Admin = jid:to_string(jid:remove_resource(From)),
  case ejabberd_hooks:run_fold(groupchat_user_kick, LServer, [], [LServer,Chat,Admin,Kick,Lang]) of
    {error, Error} ->
      ejabberd_router:route(xmpp:make_error(IQ, Error));
    R when is_list(R) ->
      ejabberd_router:route(xmpp:make_iq_result(IQ));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_internal_server_error()))
  end,
  ignore;
process_groupchat_iq(#iq{from = From, to = To, type = get, sub_els = [#xabbergroupchat{xmlns = ?NS_GROUPCHAT_MEMBERS, id = ID, rsm = undefined, version = undefined, sub_els = []}]} = IQ) ->
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
process_groupchat_iq(#iq{from = From, to = To, type = get, sub_els = [#xabbergroupchat{xmlns = ?NS_GROUPCHAT_MEMBERS, version = Version, rsm = RSM, sub_els = []}]} = IQ) ->
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
process_groupchat_iq(#iq{lang = Lang, from = From, to = To, type = set, sub_els = [#xabbergroupchat{xmlns = ?NS_GROUPCHAT_MEMBERS, sub_els = [#xabbergroupchat_user_card{id = ID, nickname = Nickname, badge = Badge}]}]} = IQ) ->
  LServer = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  Admin = jid:to_string(jid:remove_resource(From)),
case ejabberd_hooks:run_fold(groupchat_update_user_hook, LServer, [], [LServer,Chat,Admin,ID,Nickname,Badge,Lang]) of
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
process_groupchat_iq(#iq{lang = Lang, type = get, to = To, sub_els = [#xabbergroupchat_query_rights{sub_els = [], restriction = []}]} = IQ) ->
    Chat = jid:to_string(jid:remove_resource(To)),
  {selected,_Tables,Permissions} = mod_groups_restrictions:show_permissions(To#jid.lserver,Chat),
  TranslatedPermissions = lists:map(fun(N) ->
    [Name,Desc,Type,Action] = N,
    [Name,translate:translate(Lang,Desc),Type,Action] end, Permissions
  ),
  ejabberd_router:route(xmpp:make_iq_result(IQ,query_chat(TranslatedPermissions)));
process_groupchat_iq(#iq{type = set, from = From, to = To, sub_els = [#xabbergroupchat_query_rights{sub_els = [], restriction = Restrictions } = Query]} = IQ) ->
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  Permission = mod_groups_restrictions:is_permitted(<<"change-group">>,User,Chat),
  Result = case Permission of
             true when Restrictions =/= [] ->
               mod_groups_default_restrictions:restrictions(Query,IQ);
             _ ->
               xmpp:err_not_allowed()
           end,
  ejabberd_router:route(Result);
process_groupchat_iq(#iq{lang = Lang, type = get, from = From, to = To, sub_els = [#xabbergroupchat_query_rights{sub_els = [#xabbergroupchat_user_card{id = ID}]}]} = IQ) when ID == <<>> orelse ID == <<"">> ->
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
process_groupchat_iq(#iq{lang = Lang, type = get, from = From, to = To, sub_els = [#xabbergroupchat_query_rights{sub_els = [#xabbergroupchat_user_card{id = ID}]}]} = IQ) ->
  User = jid:to_string(jid:remove_resource(From)),
  LServer = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  case ejabberd_hooks:run_fold(request_change_user_settings, LServer, [], [LServer,User,Chat,ID,Lang]) of
    not_ok ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()));
    not_exist ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_item_not_found()));
    {ok,Form} ->
      ejabberd_router:route(xmpp:make_iq_result(IQ,Form));
    _ ->
      ejabberd_router:route(xmpp:make_iq_result(IQ))
  end;
process_groupchat_iq(#iq{lang = Lang, type = set, from = From, to = To, sub_els = [#xabbergroupchat_query_rights{sub_els = [#xdata{type = 'submit', fields = FS}]}]} = IQ) ->
  User = jid:to_string(jid:remove_resource(From)),
  LServer = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  IDEl = [Values|| #xdata_field{type = Type, var = Var, values = Values} <- FS, Var == <<"user-id">>, Type == 'hidden'],
  ID = list_to_binary(IDEl),
case ID of
  <<>> ->
    ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_item_not_found()));
  _ ->
    Result = ejabberd_hooks:run_fold(change_user_settings, LServer, FS, [LServer,User,Chat,ID,Lang]),
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
process_groupchat_iq(#iq{from = From, to = To, type = set, sub_els = [#xabber_retract_message{id = ID, symmetric = true, by = By}]} = IQ) ->
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  Version = mod_groups_retract:get_version(Server,Chat) + 1,
  Retract = #xabber_retract_message{
    symmetric = true,
    id = ID,
    by = By,
    conversation = jid:remove_resource(To),
    version = Version,
    xmlns = ?NS_XABBER_REWRITE_NOTIFY
  },
  Result = ejabberd_hooks:run_fold(retract_message, Server, [], [{Server,User,Chat,ID,Retract,Version}]),
  case Result of
    ok ->
      ejabberd_router:route(xmpp:make_iq_result(IQ));
    no_message ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_item_not_found()));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()))
  end;
process_groupchat_iq(#iq{from = From, to = To, type = set, sub_els = [#xabber_retract_user{symmetric = true, id = ID}]} = IQ) ->
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  Version = mod_groups_retract:get_version(Server,Chat) + 1,
  Retract = #xabber_retract_user{
    id = ID,
    symmetric = true,
    conversation = jid:remove_resource(To),
    by = jid:remove_resource(From),
    version = Version,
    xmlns = ?NS_XABBER_REWRITE_NOTIFY
  },
  Result = ejabberd_hooks:run_fold(retract_user, Server, [], [{Server,User,Chat,ID,Retract,Version}]),
  case Result of
    ok ->
      ejabberd_router:route(xmpp:make_iq_result(IQ));
    no_user ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_item_not_found()));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()))
  end;
process_groupchat_iq(#iq{from = From, to = To, type = set, sub_els = [#xabber_retract_all{symmetric = true}]} = IQ) ->
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  Version = mod_groups_retract:get_version(Server,Chat) + 1,
  Retract = #xabber_retract_all{
    symmetric = true,
    conversation = jid:remove_resource(To),
    version = Version,
    xmlns = ?NS_XABBER_REWRITE_NOTIFY
  },
  Result = ejabberd_hooks:run_fold(retract_all, Server, [], [{Server,User,Chat,<<"0000">>,Retract,Version}]),
  case Result of
    ok ->
      ejabberd_router:route(xmpp:make_iq_result(IQ));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()))
  end;
process_groupchat_iq(#iq{from = From, to = To, type = set, sub_els = [#xabber_replace{id = IDInt, xabber_replace_message = #xabber_replace_message{body = Text, sub_els = SubEls}}]}=IQ) ->
  ID = integer_to_binary(IDInt),
  User = jid:to_string(jid:remove_resource(From)),
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  Version = mod_groups_retract:get_version(Server,Chat) + 1,
  NewEls = filter_from_server_stanzas(SubEls),
  Replaced = #replaced{stamp = erlang:timestamp()},
  StanzaID = #stanza_id{id = ID, by = jid:remove_resource(To)},
  NewMessage = #xabber_replace_message{replaced = Replaced, stanza_id = StanzaID, body = Text, sub_els = NewEls},
  Replace = #xabber_replace{
    xabber_replace_message = NewMessage,
    id = IDInt,
    version = Version,
    conversation = jid:remove_resource(To),
    xmlns = ?NS_XABBER_REWRITE_NOTIFY
  },
  Result = ejabberd_hooks:run_fold(replace_message, Server, [], [{Server,User,Chat,ID,Text,Replace,Version}]),
  case Result of
    ok ->
      xmpp:make_iq_result(IQ);
    _ ->
      xmpp:make_error(IQ, xmpp:err_not_allowed())
  end;
process_groupchat_iq(#iq{lang = Lang, type = get, from = From, to = To, sub_els = [#xabbergroupchat{xmlns = ?NS_GROUPCHAT_DEFAULT_RIGHTS}]} = IQ) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  User = jid:to_string(jid:remove_resource(From)),
  Result = ejabberd_hooks:run_fold(groupchat_default_rights_form, Server, [], [User,Chat,Server,Lang]),
  case Result of
    {ok, Query} ->
      ejabberd_router:route(xmpp:make_iq_result(IQ, Query));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()))
  end;
process_groupchat_iq(#iq{lang = Lang, type = set, from = From, to = To, sub_els = [#xabbergroupchat{xmlns = ?NS_GROUPCHAT_DEFAULT_RIGHTS, sub_els = [#xdata{type = submit, fields = FS}]}]} = IQ) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  User = jid:to_string(jid:remove_resource(From)),
  Result = ejabberd_hooks:run_fold(set_groupchat_default_rights, Server, FS, [User,Chat,Server,Lang]),
  case Result of
    {ok, Query} ->
      ejabberd_router:route(xmpp:make_iq_result(IQ, Query));
    bad_request ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_bad_request()));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_not_allowed()))
  end;
process_groupchat_iq(#iq{type = get, from = From, to = To, sub_els = [#xabbergroupchat{xmlns = ?NS_GROUPCHAT_STATUS}]} = IQ) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  User = jid:to_string(jid:remove_resource(From)),
  Result = ejabberd_hooks:run_fold(group_status_info, Server, [], [User,Chat,Server]),
  case Result of
    {ok, Form} ->
      ejabberd_router:route(xmpp:make_iq_result(IQ, #xabbergroupchat{xmlns = ?NS_GROUPCHAT_STATUS, sub_els = [Form]}));
    {error, Err} ->
      ejabberd_router:route(xmpp:make_error(IQ, Err));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_bad_request()))
  end;
process_groupchat_iq(#iq{lang = Lang, type = set, from = From, to = To, sub_els = [#xabbergroupchat{xmlns = ?NS_GROUPCHAT_STATUS, sub_els = [#xdata{type = submit, fields = FSRaw}]}]} = IQ) ->
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
          ejabberd_hooks:run(groupchat_properties_changed,Server,[Server, Chat, User, [{status_changed, true}], Status]),
          ejabberd_router:route(xmpp:make_iq_result(IQ, #xabbergroupchat{xmlns = ?NS_GROUPCHAT_STATUS, sub_els = [Form]}));
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
process_groupchat_iq(#iq{type = get, from = From, to = To, sub_els = [#xabbergroupchat{xmlns = ?NS_GROUPCHAT}]} = IQ) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  User = jid:to_string(jid:remove_resource(From)),
  Result = ejabberd_hooks:run_fold(groupchat_info, Server, [], [User,Chat,Server]),
  case Result of
    {ok, Form} ->
      ejabberd_router:route(xmpp:make_iq_result(IQ, #xabbergroupchat{xmlns = ?NS_GROUPCHAT, sub_els = [Form]}));
    {error, Err} ->
      ejabberd_router:route(xmpp:make_error(IQ, Err));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_bad_request()))
  end;
process_groupchat_iq(#iq{type = set, from = From, to = To, sub_els = [#xabbergroupchat{xmlns = ?NS_GROUPCHAT, sub_els = [#xdata{type = submit, fields = FS}]}]} = IQ) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  User = jid:to_string(jid:remove_resource(From)),
  Result = ejabberd_hooks:run_fold(groupchat_info_change, Server, [], [User,Chat,Server,FS]),
  case Result of
    {ok, Form, Status, Properties} ->
      ejabberd_hooks:run(groupchat_properties_changed,Server,[Server, Chat, User, Properties, Status]),
      ejabberd_hooks:run(groupchat_changed,Server,[Server,Chat,Status,User]),
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

filter_from_server_stanzas(Els) ->
  NewEls = lists:filter(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"archived">> andalso NS == ?NS_MAM_TMP);
      (Name == <<"time">> andalso NS == ?NS_UNIQUE);
      (Name == <<"origin-id">> andalso NS == ?NS_SID_0);
      (Name == <<"stanza-id">> andalso NS == ?NS_SID_0) ->
        try xmpp:decode(El) of
          #mam_archived{} ->
            false;
          #unique_time{} ->
            false;
          #origin_id{} ->
            false;
          #stanza_id{} ->
            false
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          true
      end
    end, Els),
  NewEls.

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

query_chat(Items) ->
  {xmlel,<<"query">>,[{<<"xmlns">>,<<"https://xabber.com/protocol/groups#rights">>}],
    items(Items,[])}.

query_disco_info(Items) ->
  {xmlel,<<"query">>,[{<<"xmlns">>,?NS_DISCO_INFO}],
    Items}.

items([],Acc)->
  Acc;
items(Users,Acc) ->
  [User|Rest] = Users,
  items(Rest,[item(User)|Acc]).


item(User) ->
  [Name,TranslatedName,Type,Action] = User,
  case Action of
    null ->
      {xmlel,Type,[{<<"name">>,Name},{<<"translation">>,TranslatedName}],[]};
    _ ->
      {xmlel,Type,[{<<"name">>,Name},{<<"translation">>,TranslatedName},{<<"expires">>,Action}],[]}
  end.

process_mam_iq(#iq{from = From, lang = Lang, id = Id, to = To, meta = Meta, type = Type,
  sub_els = [SubEl]} = Iq) ->
  User = jid:to_string(jid:remove_resource(From)),
  Server = To#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(To)),
  IsRestrictedToRead = mod_groups_restrictions:is_restricted(<<"read-messages">>,User,Chat),
  SubElD = xmpp:decode(SubEl),
  IQDecoded = #iq{from = To, lang = Lang, to = From, meta = Meta, sub_els = [SubElD], type = Type, id = Id},
  Query = get_query(SubElD,Lang),
  With = proplists:is_defined(with, Query),
  case mod_groups_users:check_if_exist(Server,Chat,User) of
    true when IsRestrictedToRead == false andalso With =/= false ->
      WithValue = jid:to_string(proplists:get_value(with, Query)),
      M1 = change_id_to_jid(SubElD,Server,Chat,WithValue),
      IQDecoded2 = #iq{from = To, lang = Lang, to = From, meta = Meta, sub_els = [M1], type = Type, id = Id},
      mod_mam:process_iq_v0_3(IQDecoded2);
    true when IsRestrictedToRead == false andalso With == false ->
      mod_mam:process_iq_v0_3(IQDecoded);
    _ ->
      GlobalIndexes = mod_groups_presence:get_global_index(Server),
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

get_query(SubEl,Lang)->
  case mod_mam:parse_query(SubEl, Lang) of
    {ok, Query} ->
      Query;
    {error, _Err} ->
      []
  end.


change_id_to_jid(Query,Server,Chat,ID) ->
  JID = mod_groups_users:get_user_by_id(Server,Chat,ID),
  OldXData = Query#mam_query.xdata,
  NewFields = [
    #xdata_field{type = 'hidden', var = <<"FORM_TYPE">>, values = [Query#mam_query.xmlns]},
    #xdata_field{var = <<"with">>, values = [JID]}
  ],
  NewXData = OldXData#xdata{fields = NewFields},
  Query#mam_query{xdata = NewXData}.
