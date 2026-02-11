%%%-------------------------------------------------------------------
%%% File    : mod_groups_chats.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose :  Work with group chats
%%% Created : 19 Oct 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_groups_chats).
-author('andrey.gagarin@redsolution.com').
-behavior(gen_mod).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).
%% API
-export([start/2, stop/1, depends/2, mod_options/1]).

-export([get_all_groups_info/1, numbers_of_groups/1 ]).

-export([get_info/1, db_get_info/2]).

% Presence unsubscribed hook
-export([maybe_delete_group/3, delete_user_p2p_groups/3]).

%% Search
-export([search/7]).



-export([group_info_query/3, update_user_counter/1, is_anon/1, create_group_query/3, create_group/3, create_p2p_group/4,
  get_info/2, group_details/3, group_details/4, get_name/4, get_avatar/4,
  group_is_active/1,
  change_group_settings/4, change_group_info/4,
  delete_group_query/3, delete_group/1, change_pinned_query/4, change_pinned/3,
  delete_all_pinned/2]).


-define(DEFAULT_STATUS, <<"Discussion">>).

start(Host, _Opts) ->
  ejabberd_hooks:add(groups_user_left, Host, ?MODULE, maybe_delete_group, 35),
  ejabberd_hooks:add(groups_user_left, Host, ?MODULE, delete_user_p2p_groups, 40).

stop(Host) ->
  ejabberd_hooks:delete(groups_user_left, Host, ?MODULE, maybe_delete_group, 35),
  ejabberd_hooks:delete(groups_user_left, Host, ?MODULE, delete_user_p2p_groups, 40).

depends(_Host, _Opts) ->  [].

mod_options(_Host) -> [].

%%External

maybe_delete_group(Server, Group, _User)->
  Result =
    case get_info(Group, [parent]) of
      [Parent] when Parent /= <<"0">> ->
        delete_group(Group, true);
      _ ->
        case mod_groups:get_option(Server, remove_empty) of
          true ->
            case sql_get_user_count(Server, Group) of
              0 -> delete_group(Group, false);
              _ -> pass
            end;
          _ -> pass
        end
    end,
  case Result of
    pass ->
      case mod_groups_users:get_owners(Server, Group) of
        [] -> delete_group(Group, false);
        _ -> ok
      end;
    _ -> ok
  end,
  ok.

delete_user_p2p_groups(Server,  ParentChat, User) ->
  P2PGroups = sql_get_user_p2p_groups(Server, ParentChat, User),
  lists:foreach(fun(G)->
    delete_group(G, true)
                end, P2PGroups).


is_anon(Group) ->
  case get_info(Group, [privacy]) of
    [incognito] -> true;
    _ -> false
  end.

group_is_active(Group) ->
  {LUser, LServer, _} = jid:tolower(jid:from_string(Group)),
  case ejabberd_sm:get_user_info(LUser, LServer, <<"Group">>) of
    offline -> false;
    Info ->
      proplists:get_value(gstate, Info, false)
  end.

create_group_query(Server, UserJID, GroupEl) ->
  case check_create_query(Server, GroupEl) of
    ok ->
      User = jid:to_string(jid:remove_resource(UserJID)),
      create_group(Server, User, GroupEl);
    Err ->
      Err
  end.


create_group(_Server, <<>>, _GroupEl) ->
  error;
create_group(Server, Creator, GroupEl) ->
  #groups_group{info = Info1, settings = Settings1} = GroupEl,
  Info = case Info1 of
           undefined -> #groups_info{};
           _ -> Info1
         end,
  Settings = case Settings1 of
               undefined -> #groups_settings{};
               _ -> Settings1
             end,
  LocalPart = case GroupEl#groups_group.localpart of
                undefined -> create_localpart();
                V -> jid:nodeprep(str:strip(V))
              end,
  Name = set_value(LocalPart, Info#groups_info.name),
  Desc = set_value(<<>>, Info#groups_info.description),
  Privacy = set_value(public, GroupEl#groups_group.privacy),
  Membership = set_value(open, Settings#groups_settings.membership),
  Index = set_value(none, Settings#groups_settings.index),
  Contacts = set_value(#groups_contacts{},
    Settings#groups_settings.contacts),
  Domains = set_value(#groups_domains{},
    Settings#groups_settings.domains),
  Group = jid:to_string(jid:make(LocalPart,Server)),
  Status = ?DEFAULT_STATUS,
  case sql_create_group(Server, Group, Privacy, Membership, Name, Index, Desc,
    Contacts, Domains, Status, active, Creator, <<"0">>, LocalPart) of
    ok ->
      SInfo = #{name => Name, description => Desc, privacy => Privacy,
        membership => Membership, index => Index, messages => #groups_pinned{},
        contacts => Contacts, domains => Domains, parent => <<"0">>,
        user_count => 1, gstate => active, gstatus => Status},
      groups_sm:activate(Server, LocalPart, SInfo),
      mod_groups_users:add_user(Server, Creator, <<"owner">>, Group, <<"both">>, Creator),
      ejabberd_hooks:run(groups_add_owner, Server, [Server, Group, Creator, Creator]),
      Result = create_result_query(Group, Name, Desc, Privacy, Membership, Index,
        Settings#groups_settings.contacts, Settings#groups_settings.domains),
      {ok, Result, Group, Creator};
    _ ->
      {error, conflict}
  end.

create_p2p_group(LServer, Creator, InvitedID, ParentGroup) ->
  case mod_groups_users:check_if_exist(LServer, ParentGroup, Creator) of
    false ->
      {error, not_allowed};
    _ ->
      create_p2p_cpg(LServer, Creator, InvitedID, ParentGroup)
  end.

delete_group_query(LServer, UserJID, GroupJID) ->
  {GUser, GServer, _} = jid:tolower(GroupJID),
  case mod_xabber_entity:is_group(GUser, GServer) of
    true ->
      Group = jid:to_string(GroupJID),
      User = jid:to_string(jid:remove_resource(UserJID)),
      case mod_groups_users:is_owner(LServer, Group, User) of
        true -> delete_group(Group);
        _ -> {error, xmpp:err_not_allowed()}
      end;
    _ ->
      {error, xmpp:err_item_not_found()}
  end.

delete_group(Group) ->
  case get_info(Group, [parent]) of
    [<<"0">>] ->
      delete_group(Group, false);
    _ ->
      delete_group(Group, true)
  end.

get_info(Group, Keys) ->
  {LUser, LServer, _} = jid:tolower(jid:from_string(Group)),
  case ejabberd_sm:get_user_info(LUser, LServer, <<"Group">>) of
    offline -> error;
    Info ->
      [proplists:get_value(Key, Info, undefined) || Key <- Keys]
  end.

get_all_groups_info(Server) ->
  List = sql_get_all_groups_info(Server),
  lists:map(fun(Item)->
    {LocalPart, Name, Privacy, Index, Membership, Desc, Messages,
      Contacts, Domains, Parent, State, Status, Owner, Count, P2PUsers} = Item,
    {{LocalPart, Server, <<"Group">>},
      #{name => Name, description => Desc, privacy => Privacy,
        membership => Membership, index => Index, messages => Messages,
        contacts => Contacts, domains => Domains, parent => Parent,
        owner => Owner, gstate => State, gstatus => Status,
        user_count => Count, p2pusers => P2PUsers, group => true}}
            end, List).


group_info_query(Server, User, Group) ->
  IsAllowed = case get_info(Group, [membership]) of
                error -> false;
                [open] -> true;
                _ ->
                  mod_groups_users:is_in_group(Server, Group, User)
              end,
  case IsAllowed of
    true ->
      {ok, group_details(Server, User, Group,
        [{full, true}, {members, true}])};
    _ -> {error, xmpp:err_not_allowed()}
  end.

change_group_settings(Server, Group, User, Settings) ->
  case mod_groups_users:is_permitted(Server, Group, User,
    change_group_settings, false, []) of
    true ->
      change_group_settings(Server, Group, Settings);
    _ ->
      {error, xmpp:err_not_allowed()}
  end.

change_group_info(Server, Group, User, Iq) ->
  case mod_groups_users:is_permitted(Server, Group, User,
    change_group_info, true, []) of
    true ->
      change_group_info(Server, Group, Iq);
    _ ->
      {error, xmpp:err_not_allowed()}
  end.

change_pinned_query(Server, Group, User, PinnedMsg) ->
  case mod_groups_users:is_permitted(Server, Group, User,
    pin_messages, true, []) of
    true ->
      change_pinned(Server, Group, User, PinnedMsg);
    _ ->
      {error, xmpp:err_not_allowed()}
  end.

change_pinned(Server, Group, PinnedMsg) ->
  change_pinned(Server, Group, umdefined, PinnedMsg).

change_pinned(Server, Group, User, PinnedMsg) ->
  [Pinned]= get_info(Group, [messages]),
  Msgs = case PinnedMsg of
           #groups_pinned_message{id = ID, status = remove} ->
             lists:keydelete(ID, #groups_pinned_message.id,
               Pinned#groups_pinned.messages);
           M -> [M | Pinned#groups_pinned.messages]
         end,
  NewPinned = #groups_pinned{messages = Msgs},
  sql_update_pinned(Server, Group, NewPinned),
  groups_sm:update_group_session_info(Group, #{messages => NewPinned}),
  ejabberd_hooks:run(groups_pinned_changed,
    Server, [Server, Group, User, NewPinned]),
  ok.

delete_all_pinned(Server, Group) ->
  Pinned = #groups_pinned{messages = []},
  sql_update_pinned(Server, Group, Pinned),
  groups_sm:update_group_session_info(Group, #{messages => Pinned}),
  ejabberd_hooks:run(groups_pinned_changed,
    Server, [Server, Group, umdefined, Pinned]),
  ok.


numbers_of_groups(LServer) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(count(*))d from groupchats where %(LServer)H")) of
    {selected,[{Count}]} ->  Count;
    _ -> 0
  end.

update_user_counter(Group) ->
  {_LUser, LServer, _} = jid:tolower(jid:from_string(Group)),
  Count = sql_get_user_count(LServer, Group),
  groups_sm:update_group_session_info(Group, #{user_count => Count}).

%%Internal

check_create_query(Server, GroupEl) ->
  LocalPart = case GroupEl#groups_group.localpart of
                B when is_binary(B) ->
                  case jid:nodeprep(str:strip(B)) of
                    error -> <<>>;
                    LP -> LP
                  end;
                A -> A
              end,
  case LocalPart of
    undefined ->
      ok;
    <<>> ->
      {error, bad_request};
    _ ->
      case mod_xabber_entity:is_exist_anywhere(LocalPart, Server) of
        false ->
          check_create_query(GroupEl);
        true ->
          {error, conflict}
      end
  end.

check_create_query(#groups_group{settings = Settings, privacy = Privacy}) ->
  Membership = case Settings of
                 #groups_settings{membership = M} -> M;
                 V -> V
               end,
  case lists:member('undefined', [Membership, Privacy]) of
    true ->
      {error, bad_request};
    _ ->
      ok
  end.

create_p2p_cpg(LServer, Creator, InvitedID, ParentGroup) ->
  case get_type_and_parent(ParentGroup) of
    {ok, incognito, <<>>} ->
      create_p2p_ciu(LServer, Creator, InvitedID, ParentGroup);
    _ -> {error, not_allowed}
  end.

create_p2p_ciu(LServer, Creator, InvitedID, ParentGroup) ->
  case mod_groups_users:check_invited_to_p2p(LServer,
    ParentGroup, InvitedID) of
    false ->
      {error, not_allowed};
    Creator ->
      {error, bad_request};
    User ->
      create_p2p_cp2p(LServer, Creator, User, ParentGroup)
  end.

create_p2p_cp2p(LServer, Creator, Invited, ParentGroup) ->
  P2PGroup = sql_get_p2p_chat(LServer, ParentGroup, Creator, Invited),
  create_p2p_exists(P2PGroup, LServer, Creator, Invited, ParentGroup).

create_p2p_exists(not_found, LServer, Creator, Invited, ParentGroup) ->
  do_create_p2p_group(LServer, Creator, Invited, ParentGroup);
create_p2p_exists(P2PGroup, LServer, Creator, Invited, ParentGroup) ->
  CreatorSub = mod_groups_users:user_subscription(LServer, Creator, P2PGroup),
  InvitedSub = mod_groups_users:user_subscription(LServer, Invited, P2PGroup),
  if
    InvitedSub == <<"none">>; InvitedSub == <<"wait">> ->
      send_invite_to_p2p(LServer, Creator, Invited, P2PGroup, ParentGroup);
    true ->
      ok
  end,
  if
    CreatorSub == <<"none">>; CreatorSub == <<"wait">> ->
      GroupName = case get_info(P2PGroup, [p2pusers, name]) of
                    [undefined, undefined ] -> <<"Private chat">>;
                    [[], Name] -> Name;
                    [Users, _] ->
                      proplists:get_value(Invited, Users);
                    _ -> <<"Private chat">>
                  end,
      Created = create_result_query(P2PGroup, GroupName,
        <<"Private chat">>, incognito, private, none,
        #groups_contacts{}, #groups_domains{}),
      {ok, Created};
    true ->
      {exists, P2PGroup}
  end.

do_create_p2p_group(Server, Creator, Invited, ParentGroup) ->
%%  Create group.
  LocalPart = create_localpart(),
  Group = <<LocalPart/binary,"@", Server/binary>>,
  CreatorNick = mod_groups_users:get_nick_in_chat(Server, Creator, ParentGroup),
  InvitedNick = mod_groups_users:get_nick_in_chat(Server, Invited, ParentGroup),
  GroupName = <<CreatorNick/binary," and ", InvitedNick/binary, " chat">>,
  P2PUsers = [{Creator, CreatorNick}, {Invited, InvitedNick}],
  Desc = <<"Private chat">>,
  Privacy = incognito,
  Membership = private,
  Index = none,
  sql_create_group(Server, Group, Privacy, Membership, GroupName, Index, Desc,
    #groups_contacts{}, #groups_domains{}, ?DEFAULT_STATUS,
    active, Creator, ParentGroup, LocalPart),
  Info = #{name => GroupName, description => Desc, privacy => Privacy,
    membership => Membership, index => Index, message => 0,
    contacts => #groups_contacts{}, domains => #groups_domains{},
    parent => ParentGroup, user_count => 0, gstate => active,
    gstatus => ?DEFAULT_STATUS, p2pusers => P2PUsers},
  groups_sm:activate(Server, LocalPart, Info),
  Info1 = add_user_to_peer_to_peer_chat(Server, Invited, Group, ParentGroup),
  Info2 = add_user_to_peer_to_peer_chat(Server, Creator, Group, ParentGroup),
%%  mod_groups_vcard:create_p2p_avatar(Server, Group, element(3,Info1), element(3,Info2)),
%%  Send invite.
  send_invite_to_p2p(Server, Creator, Group, ParentGroup, Invited,
    CreatorNick, InvitedNick),
%%  Return response.
  Created = create_result_query(Group, InvitedNick, Desc,
    Privacy, Membership, Index, #groups_contacts{}, #groups_domains{}),
  InvitedAvatar = mod_groups_vcard:get_user_avatar(Server, Invited, ParentGroup),
  Created1= Created#groups_group{info = Created#groups_group.info#groups_info{
    avatar = InvitedAvatar}},
  {ok, Created1}.

send_invite_to_p2p(LServer, Creator, Invited, Group, ParentGroup) ->
  CreatorNick = mod_groups_users:get_nick_in_chat(LServer, Creator, ParentGroup),
  InvitedNick = mod_groups_users:get_nick_in_chat(LServer, Invited, ParentGroup),
  send_invite_to_p2p(LServer, Creator, Group, ParentGroup, Invited, CreatorNick,
    InvitedNick).

send_invite_to_p2p(LServer, Creator, Group, ParentGroup, Invited,
    CreatorNick, InvitedNick) ->
  Avatar = mod_groups_vcard:get_user_avatar(LServer, Creator, ParentGroup),
  GroupSettings = #groups_settings{membership = private, index = none},
  GroupInfo = #groups_info{name = CreatorNick, description = <<"Private chat">>,
    avatar = Avatar},
  GroupEl = #groups_group{parent = jid:from_string(ParentGroup),
    privacy = incognito, info = GroupInfo, settings = GroupSettings},
  GroupJID = jid:from_string(Group),
  [ParentGroupName] = get_info(ParentGroup, [name]),
  Text = <<"You was invited to ",Group/binary," Please add it to the contacts to join a group chat">>,
  Reason = <<CreatorNick/binary,
    " from ",ParentGroupName/binary, " invited you to chat privately."
    " If you accept this invitation, you won't see each other's real XMPP IDs."
    " You will be known as ", InvitedNick/binary
  >>,
  Invite = #groups_invite{reason = Reason, jid = GroupJID},
  Message = #message{
    type = chat,
    id = randoms:get_string(),
    from = jid:replace_resource(GroupJID, <<"Group">>),
    to = jid:from_string(Invited),
    body = [#text{lang = <<>>,data = Text}],
    sub_els = [Invite, GroupEl]},
  ejabberd_router:route(Message).

delete_group(Group, IsP2P) ->
  {LocalPart, LServer,_} = jid:tolower(jid:from_string(Group)),
  case IsP2P of
    false ->
      lists:foreach(fun(G)->
        delete_group(G, true)
                    end,
        sql_get_dependent_groups(LServer, Group));
    _ -> ok
  end,
  groups_sm:deactivate(LServer,LocalPart),
  AllUserMeta = mod_groups_vcard:get_all_image_metadata(LServer, Group),
  mod_groups_users:unsubscribe_all_for_delete(LServer, Group),
  mod_groups_messages:delete_all_sessions(Group),
  sql_delete_group(LServer, Group),
%%  delete archive
  mod_mam:remove_user(LocalPart, LServer),
%%  delete user avatars
  mod_groups_vcard:maybe_delete_file(LServer,AllUserMeta),
%%  delete group avatar
  mod_groups_vcard:delete_group_avatar_file(Group),
  ejabberd_hooks:run(groups_group_removed, LServer, [LServer,  Group]).

group_details(Server, User, Group) ->
  group_details(Server, User, Group, [{full, true}]).

group_details(Server, User, Group, Opts) ->
  Data = get_info(Group),
  group_details(Data, Server, User, Group, Opts).

group_details(error, _Server, _User, _Group, _Opts) ->
  error;
group_details(Data, Server, User, Group, Opts) ->
  {Name, Privacy, Index, Membership, Desc, Messages, Contacts,
    Domains, Parent, State, Status} = Data,
  Present = case proplists:get_value(present, Opts) of
              true when Status == inactive -> 0;
              true -> mod_groups_messages:get_present(Group);
              _ -> undefined
            end,
  ParentJID = case Parent of
                <<"0">> -> undefined;
                _ -> jid:from_string(Parent)
              end,
  Name1 = get_name(Group, User, Parent, Name),
  {Desc1, Index1, Contacts1, Domains1, Avatar1} =
    case proplists:get_value(full, Opts) of
      true ->
        Avatar = get_avatar(Server, Group, User, Parent),
        {Desc, Index, Contacts, Domains, Avatar};
      _ ->
        {undefined, undefined, undefined, undefined, undefined}
    end,
  MembersCount = case proplists:get_value(members, Opts) of
                   true ->
                     case count_users(Server, Group) of
                       [Count] -> Count;
                       _ -> undefined
                     end;
                   _ ->
                     undefined
                 end,
  Info = #groups_info{name = Name1, description = Desc1,
    status = Status, avatar = Avatar1},
  Settings = #groups_settings{membership = Membership, index = Index1,
    state = State, contacts = Contacts1, domains = Domains1},
  #groups_group{parent = ParentJID, privacy = Privacy, info = Info,
    settings = Settings, pinned = Messages,
    present = Present, members = MembersCount}.

get_info(Group)->
  {LUser, LServer, _} = jid:tolower(jid:from_string(Group)),
  case ejabberd_sm:get_user_info(LUser, LServer, <<"Group">>) of
    offline -> error;
    Info ->
      Name = proplists:get_value(name, Info),
      Desc = proplists:get_value(description, Info),
      Privacy = proplists:get_value(privacy, Info),
      Membership = proplists:get_value(membership, Info),
      Index = proplists:get_value(index, Info),
      Messages = proplists:get_value(messages, Info),
      Contacts = proplists:get_value(contacts, Info),
      Domains = proplists:get_value(domains, Info),
      Parent = proplists:get_value(parent, Info),
      State = proplists:get_value(gstate, Info),
      Status = proplists:get_value(gstatus, Info),
      {Name, Privacy, Index, Membership, Desc, Messages, Contacts,
        Domains, Parent, State, Status}
  end.

get_name(_Group, _User, <<"0">>, Name) ->
  Name;
get_name(_Group, undefined, _Parent, Name) ->
  Name;
get_name(Group, User, _Parent, _Name)->
  [Users] = get_info(Group, [p2pusers]),
  {_, Name1} = hd(lists:keydelete(User, 1, Users)),
  Name1.

get_avatar(Server, Group, _User, <<"0">>) ->
  mod_groups_vcard:get_group_avatar(Server, Group);
get_avatar(Server, Group, undefined, _Parent) ->
  mod_groups_vcard:get_group_avatar(Server, Group);
get_avatar(Server, Group, User, _Parent)->
  [Users] = get_info(Group, [p2pusers]),
  {User2, _} = hd(lists:keydelete(User, 1, Users)),
  mod_groups_vcard:get_user_avatar(Server, User2, Group).

change_group_info(Server, Group, #iq{type = get}) ->
  {Name, _, _, _, Desc, _, _,
    _, _, _, Status} = get_info(Group),
  Avatar = mod_groups_vcard:get_group_avatar(Server, Group),
  #groups_info{name = Name, description = Desc,
    status = Status, avatar = Avatar};
change_group_info(Server, Group, Iq) ->
  #iq{sub_els = [GroupInfo]} = Iq,
  #groups_info{avatar = NewAvatar} = GroupInfo,
  case NewAvatar of
    undefined ->
      update_group_info(Server, Group, GroupInfo);
    _ ->
      change_group_avatar(Server, Group, NewAvatar, Iq),
      ignore
  end.

update_group_info(Server, Group, GroupInfo) ->
  #groups_info{name = NewName, description = NewDesc,
    status = NewStatus} = GroupInfo,
  Avatar = mod_groups_vcard:get_group_avatar(Server, Group),
  {CurName, _Privacy, Index, Mbrshp, CurDesc, _Msgs,
    Cs, Ds, _Parent, State, CurStatus} =
    db_get_info(Server, Group),
  Result =
  case {NewName, NewDesc, NewStatus} of
    {undefined, undefined, undefined} ->
      #groups_info{name = CurName, description = CurDesc,
        status = CurStatus, avatar = Avatar};
    _ ->
      Values = [{NewName, CurName}, {NewDesc, CurDesc},
        {NewStatus, CurStatus}],
      [Name, Desc, Status] =
        lists:map(fun({undefined, Cur}) -> Cur;
          ({New, _}) -> New
                  end, Values),
      NewInfo = #{name => Name, description => Desc,
        membership => Mbrshp, index => Index, gstatus => Status,
        contacts => Cs, domains => Ds, gstate => State},
      sql_update_group(Server, Group, NewInfo),
      groups_sm:update_group_session_info(Group, NewInfo),
      #groups_info{name = Name, description = Desc,
        status = Status, avatar = Avatar}
  end,
  ejabberd_hooks:run(groups_group_changed, Server, [Server, Group, State]),
  Result.

change_group_avatar(Server, Group, NewAvatar, Iq) ->
  #groups_avatar{info = NewInfo, data = Data} = NewAvatar,
  CurAvatar = mod_groups_vcard:get_group_avatar(Server, Group),
  CurID = case CurAvatar of
            #groups_avatar{info = #avatar_info{id = V}} ->
              V;
            _ -> <<>>
          end,
  case NewInfo#avatar_info.id of
    CurID ->
      {Name, _, _, _, Desc, _, _,
        _, _, _, Status} = get_info(Group),
      Info = #groups_info{name = Name, description = Desc,
        status = Status, avatar = CurAvatar},
      ejabberd_router:route(xmpp:make_iq_result(Iq, Info));
    _ ->
      case Data of
        #avatar_data{data = _B64} ->
          %% todo: save to file
          Err = xmpp:make_error(Iq,
            xmpp:err_feature_not_implemented()),
          ejabberd_router:route(Err);
        _ ->
          mod_groups_vcard:download_avatar(Server, Group,
            <<>>, NewInfo, Iq)
      end
  end.

change_group_settings(_Server, Group, undefined) ->
  {_, _, Index, Mbrshp, _, _, Contacts,
    Domains, _, State, _} = get_info(Group),
  #groups_settings{membership = Mbrshp, index = Index,
    state = State, contacts = Contacts, domains = Domains};
change_group_settings(Server, Group, Settings) ->
  {Name, _Privacy, CurIndex, CurMbrshp, Desc, _Messages,
    CurCs, CurDs, _Parent, CurState, Status} = db_get_info(Server, Group),
  #groups_settings{index = NewIndex, state = NewState,
    membership = NewMbrshp, contacts = NewCs,
    domains = NewDs} = Settings,
  Values = [{NewMbrshp, CurMbrshp}, {NewIndex, CurIndex},
    {NewState, CurState}, {NewCs, CurCs}, {NewDs, CurDs}],
  [Mbrshp, Index, State, Cs, Ds] =
    lists:map(fun({undefined, Cur}) -> Cur;
      ({New, _}) -> New
              end, Values),
  NewInfo = #{name => Name, description => Desc,
    membership => Mbrshp, index => Index, gstatus => Status,
    contacts => Cs, domains => Ds, gstate => State},
  sql_update_group(Server, Group, NewInfo),
  groups_sm:update_group_session_info(Group, NewInfo),
  ejabberd_hooks:run(groups_group_changed, Server, [Server, Group, State]),
  if
    NewState == inactive andalso CurState == active->
      mod_groups_messages:delete_all_sessions(Group);
    true ->
      ok
  end,
  #groups_settings{index = Index, state = State,
    membership = Mbrshp, contacts = Cs,
    domains = Ds}.


db_get_info(Server, Group) ->
  sql_get_info(Server, Group).

get_type_and_parent(Group) ->
  case get_info(Group, [privacy, parent]) of
    [Privacy, <<"0">>] ->
      {ok, Privacy, <<>>};
    [Privacy, Parent] ->
      {ok, Privacy, Parent};
    _ ->
      {error, notexist}
  end.

count_users(Server, Group) ->
  {LUser, LServer, _} = jid:tolower(jid:from_string(Group)),
  case ejabberd_sm:get_user_info(LUser, LServer, <<"Group">>) of
    offline -> 0;
    Info ->
      case proplists:get_value(user_count, Info, false) of
        false ->
          ?ERROR_MSG("User counter in memory is not available: ~p",
            [Group]),
          sql_get_user_count(Server, Group);
        V -> V
      end
  end.

add_user_to_peer_to_peer_chat(Server, User, P2PGroup, ParentGroup) ->
  mod_groups_users:add_user_to_p2p_group(Server, User, P2PGroup, ParentGroup).

create_localpart() ->
  S = list_to_binary(
    [randoms:get_alphanum_string(2),randoms:get_string(),
      randoms:get_alphanum_string(3)]),
  case jid:nodeprep(S) of
    error -> create_localpart();
    LP -> LP
  end.

create_result_query(Group, Name, Desc, Privacy, Membership,
    Index, Contacts, Domains) ->
  Info = #groups_info{name = Name, description = Desc},
  Settings = #groups_settings{
    membership = Membership,
    index = Index,
    contacts = Contacts,
    domains = Domains,
    state = active },
  #groups_group{jid = jid:from_string(Group), privacy = Privacy,
    info = Info, settings = Settings}.

set_value(Default, undefined) -> Default;
set_value(_Default, Value) -> Value.


sql_create_group(Server, JID, Privacy, Membership, Name, Index, Desc,
    Contacts, Domains, Status, State, Creator, ParentGroup, LocalPart) ->
  SPrivacy = erlang:atom_to_binary(Privacy, utf8),
  SMembership = erlang:atom_to_binary(Membership, utf8),
  SIndex = erlang:atom_to_binary(Index, utf8),
  SState = erlang:atom_to_binary(State, utf8),
  SDomains = misc:term_to_expr(Domains),
  SContacts = misc:term_to_expr(Contacts),
  case ejabberd_sql:sql_query(
    Server,
    ?SQL_INSERT(
      "groupchats",
      ["name=%(Name)s",
        "server_host=%(Server)s",
        "anonymous=%(SPrivacy)s",
        "localpart=%(LocalPart)s",
        "jid=%(JID)s",
        "searchable=%(SIndex)s",
        "model=%(SMembership)s",
        "description=%(Desc)s",
        "contacts=%(SContacts)s",
        "domains=%(SDomains)s",
        "status=%(Status)s",
        "state=%(SState)s",
        "parent_chat=%(ParentGroup)s",
        "owner=%(Creator)s"])) of
    {updated,_N} ->
      ok;
    _ ->
      {error, conflict}
  end.

sql_get_p2p_chat(LServer, ParentChat, User1, User2) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(jid)s from groupchats where parent_chat = %(ParentChat)s "
    " and (select count(*) from groupchat_users where "
    " username in (%(User1)s,%(User2)s) and chatgroup = jid) = 2 "
    " and %(LServer)H")) of
    {selected,[{Chat}]} ->
      Chat;
    _ ->
      not_found
  end.

sql_get_dependent_groups(LServer, Chat) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(jid)s from groupchats
    where parent_chat = %(Chat)s and %(LServer)H")) of
    {selected, Groups} -> [G || {G} <- Groups];
    _ ->
      []
  end.

sql_delete_group(LServer, Chat) ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from groupchats where jid=%(Chat)s and %(LServer)H")
  ).

sql_update_group(Server, SJID, NewInfo) ->
  #{name := Name, description := Desc, membership := Membership,
    index := Index, contacts := Contacts, gstate := State,
    domains := Domains, gstatus := Status} = NewInfo,
  SMembership = erlang:atom_to_binary(Membership, utf8),
  SIndex = erlang:atom_to_binary(Index, utf8),
  SState = erlang:atom_to_binary(State, utf8),
  SDomains = misc:term_to_expr(Domains),
  SContacts = misc:term_to_expr(Contacts),
  case ?SQL_UPSERT(Server, "groupchats",
    ["name=%(Name)s",
      "description=%(Desc)s",
      "model=%(SMembership)s",
      "searchable=%(SIndex)s",
      "contacts=%(SContacts)s",
      "domains=%(SDomains)s",
      "state=%(SState)s",
      "status=%(Status)s",
      "!jid=%(SJID)s"]) of
    ok ->
      ok;
    _Err ->
      {error, db_failure}
  end.


sql_get_info(Server, Group) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(name)s, @(anonymous)s, @(searchable)s, "
    " @(model)s, @(description)s, @(messages)s, @(contacts)s, "
    " @(domains)s, @(parent_chat)s, @(state)s, @(status)s "
    " from groupchats where jid=%(Group)s and %(Server)H")) of
    {selected,[{Name, SPrivacy, SIndex, SMembership, Desc,
      SMessages, SContacts, SDomains, SParent, SState, Status}]} ->
      Messages = case SMessages of
                   null -> #groups_pinned{};
                   _ -> ejabberd_sql:decode_term(SMessages)
                 end,
      Parent = case SParent of
                 <<>> -> <<"0">>;
                 null -> <<"0">>;
                 _ -> SParent
               end,
      Contacts = case SContacts of
                   null -> #groups_contacts{};
                   _ -> ejabberd_sql:decode_term(SContacts)
                 end,
      Domains = case SDomains of
                  null -> #groups_domains{};
                  _ -> ejabberd_sql:decode_term(SDomains)
                end,
      Privacy = erlang:binary_to_existing_atom(SPrivacy, utf8),
      Membership = erlang:binary_to_existing_atom(SMembership, utf8),
      Index = erlang:binary_to_existing_atom(SIndex, utf8),
      State = erlang:binary_to_existing_atom(SState, utf8),
      {Name, Privacy, Index, Membership, Desc, Messages,
        Contacts, Domains, Parent, State, Status};
    _ -> error
  end.

sql_get_all_groups_info(LServer) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(localpart)s, @(name)s, @(anonymous)s, @(searchable)s, "
    " @(model)s, @(description)s, @(messages)s, @(contacts)s, "
    " @(domains)s, @(parent_chat)s, @(state)s, @(status)s, @(owner)s, "
    " @((select count(*) from groupchat_users "
    " where chatgroup = t.jid and subscription = 'both'))d,"
    " (select @(STRING_AGG(username||'::'||nickname,';;'))s from groupchat_users "
    " where chatgroup = t.jid and t.parent_chat != '0')"
    " from groupchats t where %(LServer)H")) of
    {selected, List} ->
      lists:map(fun(Item)->
        {LocalPart, Name, SPrivacy, SIndex, SMembership, Desc, SMessages,
          SContacts, SDomains, SParent, SState, Status, Owner, Count, SP2PUsers} = Item,
        P2PUsers = case SP2PUsers of
                      null -> [];
                      _ ->
                        [list_to_tuple(binary:split(I,<<"::">>)) ||
                          I <- binary:split(SP2PUsers, <<";;">>)]
                    end,
        Messages = case SMessages of
                     null -> #groups_pinned{};
                     _ -> ejabberd_sql:decode_term(SMessages)
                   end,
        Parent = case SParent of
                   <<>> -> <<"0">>;
                   null -> <<"0">>;
                   _ -> SParent
                   end,
        Contacts = case SContacts of
                     null -> #groups_contacts{};
                     _ -> ejabberd_sql:decode_term(SContacts)
                   end,
        Domains = case SDomains of
                    null -> #groups_domains{};
                    _ -> ejabberd_sql:decode_term(SDomains)
                   end,
        Privacy = erlang:binary_to_existing_atom(SPrivacy, utf8),
        Membership = erlang:binary_to_existing_atom(SMembership, utf8),
        Index = erlang:binary_to_existing_atom(SIndex, utf8),
        State = erlang:binary_to_existing_atom(SState, utf8),
        {LocalPart, Name, Privacy, Index, Membership, Desc, Messages,
          Contacts, Domains, Parent, State, Status, Owner, Count, P2PUsers}
                end, List);
    _ -> []
  end.

sql_update_pinned(Server, Group, Pinned) ->
  SPinned = misc:term_to_expr(Pinned),
  ?SQL_UPSERT(Server, "groupchats",
    [ "messages=%(SPinned)s",
      "!jid=%(Group)s"]).

sql_get_user_p2p_groups(LServer, ParentChat, User)->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(jid)s from groupchats where parent_chat = %(ParentChat)s "
    " and (select true from groupchat_users where "
    " username =%(User)s and chatgroup = jid) "
    " and %(LServer)H")) of
    {selected, Groups} -> [G || {G} <- Groups];
    _ ->
      []
  end.

sql_get_user_count(LServer,Chat) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(count(*))d from groupchat_users "
    " where chatgroup = %(Chat)s and subscription = 'both'")) of
    {selected,[{Num}]} -> Num;
    _ -> 0
  end.

%%%%
%%  Search for group chats
%%%%
search(Server,Name,Anonymous,Model,Desc,UserJid,UserHost)->
  NameS = set_value(<<>>,Name),
  AnonymousS = set_value(<<>>,Anonymous),
  ModelS = set_value(<<>>,Model),
  DescS = set_value(<<>>,Desc),
  {selected,_Titles,Rows} =
    search_and_count_chats(Server,NameS,AnonymousS,ModelS,DescS,UserJid,UserHost),
  Children = lists:map(fun(N) ->
    [ChatJidQ,NameQ,AnonymousQ,ModelQ,DescQ,ContactListQ,DomainListQ,Count] = N,
    item_chat(ChatJidQ,NameQ,AnonymousQ,ModelQ,DescQ,ContactListQ,DomainListQ,Count) end,
    Rows
  ),
  query(Children).

search_and_count_chats(Server,Name,Anonymous,_Model,Desc,UserJid,UserHost) ->
  ejabberd_sql:sql_query(
    Server,
    [<<"select chatgroup,name,anonymous,model,description,contacts,domains,count(*)
    from groupchat_users inner join groupchats on jid=chatgroup
    where chatgroup IN ((select jid from groupchats
    where model='open' and (
    name like '%">>,Name,<<"%' and anonymous like '%">>,Anonymous,<<"%' and description like '%">>,Desc,<<"%'
    )
    EXCEPT select chatgroup from groupchat_block
    where blocked = '">>,UserJid,<<"' or blocked = '">>,UserHost,<<"')
   UNION (select jid from groupchats where model='member-only' and (
    name like '%">>,Name,<<"%' and anonymous like '%">>,Anonymous,<<"%' and description like '%">>,Desc,<<"%'
    )
   INTERSECT select chatgroup from groupchat_users where username = '">>,UserJid,<<"'))
   GROUP BY chatgroup,name,anonymous,model,description,contacts,domains ORDER BY chatgroup DESC">>
    ]).

query(Children) ->
  #xmlel{name = <<"query">>, attrs = [{"xmlns",?NS_GROUPS}], children = Children}.

item_chat(ChatJidQ,NameQ,AnonymousQ,ModelQ,DescQ,_ContactListQ,_DomainListQ,Count) ->
  #xmlel{name = <<"item">>, children =
  [
    #xmlel{name = <<"jid">>, children = [{xmlcdata,ChatJidQ}]},
    #xmlel{name = <<"name">>, children = [{xmlcdata,NameQ}]},
    #xmlel{name = <<"anonymous">>, children = [{xmlcdata,AnonymousQ}]},
    #xmlel{name = <<"model">>, children = [{xmlcdata,ModelQ}]},
    #xmlel{name = <<"description">>, children = [{xmlcdata,DescQ}]},
    #xmlel{name = <<"member-count">>, children = [{xmlcdata,Count}]}
  ]}.
%%%%
%%  End of search for group chats
%%%%
