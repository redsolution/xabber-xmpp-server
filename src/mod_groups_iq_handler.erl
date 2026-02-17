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
-export([start/2, stop/1, depends/2, mod_options/1,
  init/1, handle_call/3, handle_cast/2, terminate/2]).
-export([process_iq_local/1, process_iq_sm/1, make_action/1]).


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
  {ok, #state{host = Host}}.

terminate(_Reason, State) ->
  Host = State#state.host,
  unregister_iq_handlers(Host).

register_iq_handlers(Host) ->
  gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_GROUPS, ?MODULE, process_iq_sm),
  gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_GROUPS, ?MODULE, process_iq_local).

unregister_iq_handlers(Host) ->
  gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_GROUPS),
  gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_GROUPS).

handle_call(_Request, _From, _State) ->
  erlang:error(not_implemented).

handle_cast({group_created, Server, User, Group}, State) ->
  mod_groups_vcard:make_group_avatar(Server, Group),
  ejabberd_hooks:run(groups_group_created, Server, [Server, User, Group]),
  {noreply, State};
handle_cast(#iq{type = error}, State) ->
  {noreply, State};
handle_cast(#iq{type = result, sub_els = [#pubsub{}]} = Iq, State) ->
  process_pubsub(Iq),
  {noreply, State};
handle_cast(#iq{type = result, sub_els = [#vcard_temp{}]} = Iq, State) ->
  process_vcard(Iq),
  {noreply, State};
handle_cast(#iq{type = get, sub_els = [#disco_info{}]} = Iq, State) ->
  process_disco_info(Iq),
  {noreply, State};
handle_cast(#iq{} = Iq, State) ->
  ?INFO_MSG("IQ ~p",[Iq]),
%%  make_action(Iq),
  {noreply, State};
handle_cast(_Request, State) ->
  {noreply, State}.

%%Add owner
process_iq_sm(#iq{type = get, sub_els = [#groups_owner{}]} = Iq) ->
  xmpp:make_error(Iq, xmpp:err_bad_request());
process_iq_sm(#iq{sub_els = [#groups_owner{id = undefined}]} = Iq) ->
  xmpp:make_error(Iq, xmpp:err_bad_request());
process_iq_sm(#iq{sub_els = [#groups_owner{id = <<>>}]} = Iq) ->
  xmpp:make_error(Iq, xmpp:err_bad_request());
%% Group Members
process_iq_sm(#iq{type = set, sub_els = [#groups_members{id = undefined}]} = Iq)->
  xmpp:make_error(Iq, xmpp:err_bad_request());
process_iq_sm(#iq{type = set, sub_els = [#groups_members{id = <<"">>}]} = Iq)->
  xmpp:make_error(Iq, xmpp:err_bad_request());
process_iq_sm(#iq{type = set, sub_els = [#groups_members{members = []}]} = Iq)->
  xmpp:make_error(Iq, xmpp:err_bad_request());
%% Invite user
process_iq_sm(#iq{type = get, sub_els = [#groups_invite{}]} = Iq) ->
  xmpp:make_error(Iq, xmpp:err_bad_request());
%% Revoke invite
process_iq_sm(#iq{type = get, sub_els = [#groups_revoke{}]} = Iq) ->
  xmpp:make_error(Iq, xmpp:err_bad_request());
%% List of invitations
process_iq_sm(#iq{type = set, sub_els = [#groups_invites{}]} = Iq) ->
  xmpp:make_error(Iq, xmpp:err_bad_request());
%% Block users/domains
process_iq_sm(#iq{type = set, sub_els = [#groups_block{jids = []}]} = Iq) ->
  xmpp:make_error(Iq, xmpp:err_bad_request());
%% Unblock users/domains
process_iq_sm(#iq{type = get, sub_els = [#groups_unblock{}]} = Iq) ->
  xmpp:make_error(Iq, xmpp:err_bad_request());
process_iq_sm(#iq{type = set, sub_els = [#groups_unblock{jid = undefined}]} = Iq) ->
  xmpp:make_error(Iq, xmpp:err_bad_request());
%% Kick user
process_iq_sm(#iq{type = get, sub_els = [#groups_kick{}]} = Iq) ->
  xmpp:make_error(Iq, xmpp:err_bad_request());
process_iq_sm(#iq{type = set, sub_els = [#groups_kick{jid = undefined}]} = Iq) ->
  xmpp:make_error(Iq, xmpp:err_bad_request());
%% Pin/unpin message
process_iq_sm(#iq{type = get, sub_els = [#groups_pinned_message{}]} = Iq) ->
  xmpp:make_error(Iq, xmpp:err_bad_request());
%% Decline invite
process_iq_sm(#iq{type = get, sub_els = [#groups_decline{}]} = Iq) ->
  xmpp:make_error(Iq, xmpp:err_bad_request());
process_iq_sm(#iq{type = set, sub_els = [#groups_decline{}]} = Iq) ->
  {Server, Group, User} = host_group_user(Iq),
  R = process_iq_sm(set, Iq#iq.sub_els, Server, Group, User),
  return_result(R, Iq);
%% Group Info Query
process_iq_sm(#iq{type = set, sub_els = [#groups_details{}]} = Iq) ->
  xmpp:make_error(Iq, xmpp:err_bad_request());
process_iq_sm(#iq{type = Type, sub_els = [#groups_details{}]} = Iq) ->
  {Server, Group, User} = host_group_user(Iq),
  R = process_iq_sm(Type, Iq#iq.sub_els, Server, Group, User),
  return_result(R, Iq);
%% Change Group Info
process_iq_sm(#iq{sub_els = [#groups_info{}]} = Iq) ->
  case check_from_to(Iq) of
    {Server, Group, User} ->
      R = mod_groups_chats:change_group_info(Server, Group, User, Iq),
      return_result(R, Iq);
    _ ->
      xmpp:make_error(Iq, xmpp:err_not_allowed())
  end;
%% Change Group member
process_iq_sm(#iq{type = set, sub_els = [#groups_members{}]} = Iq) ->
  case check_from_to(Iq) of
    {Server, Group, User} ->
      R = mod_groups_users:update_member_query(Server, Group, User, Iq),
      return_result(R, Iq);
    _ ->
      xmpp:make_error(Iq, xmpp:err_not_allowed())
  end;
process_iq_sm(#iq{type = Type, sub_els = Els} = Iq) ->
  case check_from_to(Iq) of
    {Server, Group, User} ->
      R = process_iq_sm(Type, Els, Server, Group, User),
      return_result(R, Iq);
    _ ->
      xmpp:make_error(Iq, xmpp:err_not_allowed())
  end.

%%Add owner
process_iq_sm(set, [#groups_owner{id = MemberID}], Server, Group, User) ->
  case mod_groups_users:add_owner(Server, Group, User, MemberID) of
    {error, not_allowed} ->
      {error, xmpp:err_not_allowed()};
    {error, not_found} ->
      {error, xmpp:err_item_not_found()};
    _ ->
      ok
  end;

%% Group Info Query
process_iq_sm(get, [#groups_details{}], Server, Group, User) ->
  case mod_groups_chats:group_info_query(Server, User, Group) of
    {ok, Info} ->
      Info;
    Err ->
      Err
  end;


%% Change Group Settings
process_iq_sm(Type,[#groups_settings{} = S], Server, Group, User) ->
  Settings = case Type of
               get -> undefined;
               _ -> S
             end,
  mod_groups_chats:change_group_settings(Server, Group, User, Settings);

%% Block users/domains
process_iq_sm(get, [#groups_block{}], Server, Group, User) ->
  mod_groups_block:block_list(Server, Group, User);
process_iq_sm(set, [#groups_block{jids = JIDs}], Server, Group, User) ->
  mod_groups_block:block(Server, Group, User, JIDs);

%% Unblock users/domains
process_iq_sm(set, [#groups_unblock{jid = JID}], Server, Group, User) ->
  mod_groups_block:unblock(Server, Group, User, JID);

%% Kick user
process_iq_sm(set, [#groups_kick{jid = JID}], Server, Group, User) ->
  mod_groups_block:kick(Server, Group, User, JID);

%% Group Members
process_iq_sm(get, [#groups_members{id = ID, version = Ver, xdata = Filters}],
    Server, Group, User) ->
  case ID of
    undefined ->
      mod_groups_users:get_group_members(Server, Group, User,
        undefined, Ver, Filters);
    _ ->
      mod_groups_users:get_group_member(Server, Group, User, ID)
  end;
%%process_iq_sm(set, [#groups_members{id = ID, members = [UserCard]}],
%%    Server, Group, User) ->
%%  mod_groups_users:update_member_query(Server, Group, User,
%%    ID, UserCard);

%% Invite user
process_iq_sm(set, [#groups_invite{} = Invite], Server, Group, User) ->
  mod_groups_invites:invite_user(Server, Group, User, Invite);

%% Revoke invite
process_iq_sm(set, [#groups_revoke{jid = JID}], Server, Group, User) ->
  JIDS = jid:to_string(jid:remove_resource(JID)),
  mod_groups_invites:revoke(Server, Group, User, JIDS);

%% Decline invite
process_iq_sm(set, [#groups_decline{}], Server, Group, User) ->
  mod_groups_invites:revoke(Server, Group, User);

%% List of invitations
process_iq_sm(get, [#groups_invites{}], Server, Group, User) ->
  mod_groups_invites:get_invites(Server, Group, User);

%% Pin/unpin message
process_iq_sm(set, [#groups_pinned_message{} = P ], Server, Group, User) ->
  mod_groups_chats:change_pinned_query(Server, Group, User, P);

%% Not implemented
process_iq_sm(Type, SubEls, _Server, _Group, _User) ->
  ?INFO_MSG("~p ~p",[Type, SubEls]),
  {error, xmpp:err_feature_not_implemented()}.


%% Create Group
process_iq_local(#iq{type = get, sub_els = [#groups_create{}]} = IQ) ->
  xmpp:make_error(IQ, xmpp:err_bad_request());
process_iq_local(#iq{type = set, sub_els = [
  #groups_create{group = undefined, p2p = undefined}]} = IQ) ->
  xmpp:make_error(IQ, xmpp:err_bad_request());
process_iq_local(#iq{type = set, sub_els = [
  #groups_create{group = GroupEl, p2p = undefined}]} = IQ) ->
  UserJID= IQ#iq.from,
  {_, Server, _} = jid:tolower(IQ#iq.to),
  case mod_groups_chats:create_group_query(Server, UserJID, GroupEl) of
    {ok, GroupElR, Group, User} ->
      Proc = gen_mod:get_module_proc(Server, ?MODULE),
      gen_server:cast(Proc, {group_created, Server, User, Group}),
      xmpp:make_iq_result(IQ, GroupElR);
    {error, conflict} ->
      xmpp:make_error(IQ, xmpp:err_conflict());
    _ ->
      xmpp:make_error(IQ, xmpp:err_bad_request())
  end;
process_iq_local(#iq{type = set, sub_els = [
  #groups_create{group = undefined, p2p = P2P}]} = IQ) ->
  #groups_p2p{parent = ParentGroupJID, with = InvitedID} = P2P,
  Creator = jid:to_string(jid:remove_resource(IQ#iq.from)),
  ParentGroup =  jid:to_string(jid:remove_resource(ParentGroupJID)),
  {_, Server, _} = jid:tolower(IQ#iq.to),
  Result = mod_groups_chats:create_p2p_group(Server, Creator,
    InvitedID, ParentGroup),
  case Result of
    {ok, Created} ->
      xmpp:make_iq_result(IQ, Created);
    {exists, Group} ->
      GroupJID = jid:from_string(Group),
      NewIq = xmpp:set_els(IQ, [#groups_group{jid = GroupJID}]),
      xmpp:make_error(NewIq, xmpp:err_conflict());
    {error, not_allowed} ->
      xmpp:make_error(IQ, xmpp:err_not_allowed());
    {error, bad_request} ->
      xmpp:make_error(IQ, xmpp:err_bad_request());
    _ ->
      xmpp:make_error(IQ, xmpp:err_internal_server_error())
  end;
%%process_iq_local(#iq{type=get, to= To, from = From,
%%  sub_els = [#groups_search{name = Name, anonymous = Anon,
%%    description = Desc, model = Model}]} = Iq) ->
%%  Server = To#jid.lserver,
%%  UserHost = From#jid.lserver,
%%  UserJid = jid:to_string(jid:remove_resource(From)),
%%  Query = mod_groups_chats:search(Server,Name,Anon,Model,Desc,UserJid,UserHost),
%%  xmpp:make_iq_result(Iq,Query);
process_iq_local(#iq{from = From, to = To, type = set,
  sub_els = [#groups_delete{group = GroupJID}]} = IQ) ->
  Server = To#jid.lserver,
  case mod_groups_chats:delete_group_query(Server, From, GroupJID) of
    {error, Err} ->
      xmpp:make_error(IQ, Err);
    _ ->
      xmpp:make_iq_result(IQ)
  end;
process_iq_local(IQ) ->
  xmpp:make_error(IQ, xmpp:err_bad_request()).

make_action(#iq{type = set, sub_els = [#mam_query{}]} = Iq) ->
  process_mam_iq(Iq);
make_action(#iq{sub_els = [#mam_query{}]} = Iq) ->
  xmpp:make_error(Iq, xmpp:err_bad_request());
make_action(#iq{type = Type, from = From, sub_els = Els} = Iq) ->
  case check_from_to(Iq) of
    {Server, Group, User} ->
      R = make_action(Type, Els, Server, Group, User, From),
      return_result(R, Iq);
    _ ->
      xmpp:make_error(Iq, xmpp:err_not_allowed())
  end.

make_action(get, [#retract_query{version = undefined, 'less-than' = undefined}],
    Server, Group, _User, _UserJID) ->
  mod_groups_retract:get_version_reply(Server, Group);
make_action(get, [#retract_query{version = Version, 'less-than' = Less}],
    Server, Group, _User, UserJID) ->
  CurrentVer =  mod_groups_retract:send_rewrite_archive(Server, UserJID,
    Group, Version, Less),
  #retract_query{version=CurrentVer};
make_action(set, [#retract_message{symmetric = true, id = ID}],
    Server, Group, User, _) ->
  case mod_groups_retract:retract_message(Server, Group, User, ID) of
    ok -> ok;
    {error, not_found} ->
      {error, xmpp:err_item_not_found()};
    {error, not_allowed} ->
      {error, xmpp:err_not_allowed()};
    _ ->
      {error, xmpp:err_internal_server_error()}
  end;
make_action(set, [#retract_user{symmetric = true, id =ID}],
    Server, Group, User, _) ->
  case mod_groups_retract:retract_user_messages(
    Server, Group, User, ID) of
    ok -> ok;
    _ -> {error, xmpp:err_not_allowed()}
  end;
make_action(set, [#retract_all{symmetric = true}],
    Server, Group, User, _) ->
  case mod_groups_retract:retract_all_messages(
    Server, Group, User) of
    ok -> ok;
    _ -> {error, xmpp:err_not_allowed()}
  end;
make_action(set, [#replace{} = Replace], Server, Group, User, _) ->
  case mod_groups_retract:rewrite_message(
    Server, Group, User, Replace) of
    ok -> ok;
    _ -> {error, xmpp:err_not_allowed()}
  end;
make_action(Type, SubEls, _, _, _, _) ->
  ?INFO_MSG("~p ~p",[Type, SubEls]),
  {error, xmpp:err_bad_request()}.

process_mam_iq(#iq{from = From, to = To, lang = Lang,
  sub_els = [Query]} = Iq) ->
  User = jid:to_string(jid:remove_resource(From)),
  Server = To#jid.lserver,
  Group = jid:to_string(jid:remove_resource(To)),
  case mod_groups_users:check_if_exist(Server, Group, User) of
    true ->
      QueryD = xmpp:decode(Query),
      case change_query(QueryD, Server, Group, Lang) of
        {error, Err} ->
          ejabberd_router:route(xmpp:make_error(Iq, Err));
        SubEls ->
          mod_mam:process_iq_v0_3(Iq#iq{from = To, to = From,
            sub_els = SubEls})
      end;
    _ ->
      ejabberd_router:route(
        xmpp:make_error(Iq, xmpp:err_not_allowed()))
  end,
  ignore.

process_pubsub(#iq{from = UserJID, to = GroupJID,
  sub_els = [#pubsub{items = #ps_items{node = ?NS_AVATAR_METADATA,
    items = [#ps_item{id = _Hash, sub_els = SubEls}]}}]}) ->
  try
    MD = lists:map(fun(E) -> xmpp:decode(E) end, SubEls),
    Meta = lists:keyfind(avatar_meta,1,MD),
    mod_groups_vcard:handle_avatar_meta(GroupJID, UserJID, Meta)
  catch _:_ ->
    ok
  end;
process_pubsub(#iq{from = UserJID, to = GroupJID,
  sub_els = [#pubsub{items = #ps_items{node = ?NS_AVATAR_DATA,
    items = [#ps_item{id = Hash, sub_els = SubEls}]}}]}) ->
  try
    MD = lists:map(fun(E) -> xmpp:decode(E) end, SubEls),
    Data = lists:keyfind(avatar_data,1,MD),
    mod_groups_vcard:handle_avatar_data(GroupJID, UserJID,
      Hash, Data)
  catch _:_ ->
    ok
  end;
process_pubsub(_) -> ok.

process_vcard(#iq{sub_els = [Vcard]} = Iq ) ->
  {Server, _Group, User} = host_group_user(Iq),
  mod_groups_vcard:handle_vcard(Server, User, Vcard).

process_disco_info(Iq) ->
  Group = jid:to_string(jid:remove_resource(Iq#iq.to)),
  [Privacy] = mod_groups_chats:get_info(Group, [privacy]),
  Info = mod_groups_discovery:client_disco_info(Privacy),
  Result = xmpp:make_iq_result(Iq, Info),
  ejabberd_router:route(Result).

host_group_user(Pkt) ->
  User = jid:to_string(jid:remove_resource(xmpp:get_from(Pkt))),
  GroupJID = jid:remove_resource(xmpp:get_to(Pkt)),
  {GroupJID#jid.lserver, jid:to_string(GroupJID), User}.

check_from_to(Pkt) ->
  {Server, Group, User} = host_group_user(Pkt),
  {GUser, _, _} = jid:tolower(jid:from_string(Group)),
  case mod_xabber_entity:get_entity_type(GUser, Server) of
    group ->
      case mod_groups_users:check_if_exist(Server, Group, User) of
        true -> {Server, Group, User};
        _ -> false
      end;
    _ ->
      false
  end.

change_query(QueryEl, Server, Chat, Lang) ->
  case mod_mam:parse_query(QueryEl, Lang) of
    {ok, Query} ->
      case replace_id_to_jid(Query, Server, Chat) of
        error ->
          {error, xmpp:err_bad_request()};
        Q1 ->
          %% Messages in archive are stored with "urn:xabber:chat" type.
          Q2 = lists:keydelete('conversation-type', 1, Q1),
          Fields = mam_query:encode(Q2),
          [QueryEl#mam_query{xdata =
          #xdata{type = 'submit', fields = Fields}}]
      end;
    Err ->
      Err
  end.

replace_id_to_jid(Query, Server, Group) ->
  case lists:keyfind('with', 1, Query) of
    {_, Value} ->
      ID = jid:to_string(Value),
      case mod_groups_users:get_user_by_id(Server, Group, ID) of
        none -> error;
        JS ->
          lists:keyreplace('with', 1, Query,
            {'with', jid:from_string(JS)})
      end;
    _ -> Query
  end.

return_result(ignore, _Iq) -> ignore;
return_result({error, Err}, Iq) -> xmpp:make_error(Iq, Err);
return_result(Result, Iq) when is_tuple(Result) ->
  xmpp:make_iq_result(Iq, Result);
return_result(_, Iq) -> xmpp:make_iq_result(Iq).