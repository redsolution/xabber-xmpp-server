%%%-------------------------------------------------------------------
%%% File    : mod_groups_chats.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%  Purpose : Notifications in Groups
%%% Created : 22 Jan 2026 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% @copyright (C) 2026, Redsolution

%%%-------------------------------------------------------------------
-module(groups_notifications).
-author('ilya.kalashnikov@redsolution.com').
-behavior(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").

%% gen_mod
-export([start/2, stop/1, depends/2, mod_options/1]).

%% Hooks
-export([group_created/3, group_changed/3, pinned_changed/4,
  user_changed/4, user_avatar_changed/3, user_join/2, user_left/3]).
%% API
-export([send_present/3]).


%% gen_mod

start(Host, _Opts) ->
  ejabberd_hooks:add(groups_group_created, Host, ?MODULE, group_created, 10),
  ejabberd_hooks:add(groups_group_changed, Host, ?MODULE, group_changed, 20),
  ejabberd_hooks:add(groups_pinned_changed, Host, ?MODULE, pinned_changed, 10),
  ejabberd_hooks:add(groups_user_changed, Host, ?MODULE, user_changed, 25),
  ejabberd_hooks:add(groups_presence_subscribed, Host, ?MODULE, user_join, 80),
  ejabberd_hooks:add(groups_user_left, Host, ?MODULE, user_left, 60).

stop(Host) ->
  ejabberd_hooks:delete(groups_group_created, Host, ?MODULE, group_created, 10),
  ejabberd_hooks:delete(groups_group_changed, Host, ?MODULE, group_changed, 20),
  ejabberd_hooks:delete(groups_pinned_changed, Host, ?MODULE, pinned_changed, 10),
  ejabberd_hooks:delete(groups_update_user, Host, ?MODULE, user_changed, 25),
  ejabberd_hooks:delete(groups_presence_subscribed, Host, ?MODULE, user_join, 80),
  ejabberd_hooks:delete(groups_user_left, Host, ?MODULE, user_left, 60).

depends(_Host, _Opts) ->  [].

mod_options(_Opts) -> [].


%% Hooks

group_created(Server, User, Group) ->
  system_message(create, Server, Group, User).

group_changed(Server, Group, State) ->
  Users = mod_groups_users:users_to_send(Server, Group),
  case State of
    active ->
      send_notice(Users, Group, [full]);
    _ ->
      [Privacy] = mod_groups_chats:get_info(Group, [privacy]),
      Settings = #groups_settings{state = inactive},
      GroupEl = #groups_group{privacy = Privacy,
        settings = Settings},
      GroupJID = jid:from_string(Group),
      lists:foreach(fun(User) ->
        do_send_notice(GroupJID, User, GroupEl)
                    end, Users)
  end,
  maybe_send_to_index(Server, Group).

pinned_changed(Server, Group, User, Messages) ->
  Members = mod_groups_users:users_to_send(Server, Group),
  [Privacy] = mod_groups_chats:get_info(Group, [privacy]),
  GroupEl = #groups_group{privacy = Privacy, pinned = Messages},
  GroupJID = jid:from_string(Group),
  lists:foreach(fun(Member) ->
    do_send_notice(GroupJID, Member, GroupEl)
                end, Members),
  case User of
    undefinde -> ok;
    _ -> system_message(pinned, Server, Group, User)
  end.

user_changed(Server, Group, User, OldCard) ->
  UserCard = mod_groups_users:user_card(User, Group),
  system_message(update, Server, Group, User, UserCard, OldCard).

user_avatar_changed(Server, Group, User) ->
  system_message(user_avatar, Server, Group, User).

user_left(Server, Group, User) ->
  Users = mod_groups_users:users_to_send(Server, Group),
  send_notice(Users, Group, [members, present]),
  system_message(left, Server, Group, User).

user_join(Acc, {Server, UserJID, Group}) ->
  ?INFO_MSG("JOIN ~p ~p ~p",[Server, UserJID, Group]),
  Users = mod_groups_users:users_to_send(Server, Group),
  send_notice(Users, Group, [members, present]),
  User = jid:to_string(jid:remove_resource(UserJID)),
  system_message(join, Server, Group, User),
  Acc.

%% API
send_present(Group, Users, Present) ->
  [Privacy, Members] = mod_groups_chats:get_info(Group,
    [privacy, user_count]),
  GroupEl = #groups_group{privacy = Privacy, members = Members,
    present = Present},
  GroupJID = jid:from_string(Group),
  lists:foreach(fun(Member) ->
    do_send_notice(GroupJID, Member, GroupEl)
                end, Users).

%% Internal

send_notice(Users, Group, Opts) ->
  GroupJID = jid:replace_resource(jid:from_string(Group), <<"Group">>),
  Server = GroupJID#jid.lserver,
  GroupEl =  case mod_groups_chats:group_details(Server,
    undefined, Group, Opts) of
               %% Happens when deleting a group
               error -> #groups_group{};
               El -> El
              end,
  Full = proplists:get_value(full, Opts, false),
  IsP2P = case GroupEl#groups_group.parent of
            undefined -> false;
            _ -> true
          end,

  send_notice(IsP2P, Users, GroupJID, GroupEl, Full).

send_notice(_, [], _, _, _)  ->  ok;
send_notice(false, [UserJID|Users], GroupJID, GroupEl, Full) ->
  do_send_notice(GroupJID, UserJID, GroupEl),
  send_notice(false, Users, GroupJID, GroupEl, Full);
send_notice(true, [UserJID | Users], GroupJID, GroupEl, Full) ->
  UserS = jid:to_string(jid:remove_resource(UserJID)),
  GroupS = jid:to_string(jid:remove_resource(GroupJID)),
  Server = GroupJID#jid.lserver,
  Info = GroupEl#groups_group.info,
  Name = mod_groups_chats:get_name(GroupS, UserS, true,
    Info#groups_info.name),
  Avatar = case Full of
             true ->
               mod_groups_chats:get_avatar(Server, GroupS,
                 UserS, true);
             _ -> undefined
           end,
  Info1 = Info#groups_info{name = Name, avatar = Avatar},
  GroupEl1 = GroupEl#groups_group{info = Info1},
  do_send_notice(GroupJID, UserJID, GroupEl1),
  send_notice(true, Users, GroupJID, GroupEl, Full).

do_send_notice(From, To, GroupEl) ->
  Msg = #message{type = headline,
    id = randoms:get_string(),
    sub_els = [GroupEl]},
  ejabberd_router:route(From, To , Msg).

system_message(Type, Server, Group, User) ->
  UserCard = mod_groups_users:user_card(User, Group),
  Nick = get_name(UserCard),
  system_message(Type, Server, Group, User, UserCard, Nick).

system_message(create, Server, Group, User, UserCard, Nick) ->
  Anonymous = case mod_groups_chats:get_info(Group, [privacy]) of
              [imcognito] -> <<" anonymous ">>;
              _ -> <<" ">>
            end,
  Txt =  <<Nick/binary," created the",Anonymous/binary,"group chat.">>,
  send_sys_msg(Server, Group, User, UserCard, <<"create">>, Txt, []);
system_message(pinned, Server, Group, User, UserCard, Nick) ->
  Txt =  <<Nick/binary," changed the pinned messages.">>,
  send_sys_msg(Server, Group, User, UserCard, <<"pinned">>, Txt, []);
system_message(join, Server, Group, User, UserCard, Nick) ->
  Txt =  <<Nick/binary," joined the group.">>,
  send_sys_msg(Server, Group, User, UserCard, <<"join">>, Txt, []);
system_message(left, Server, Group, User, UserCard, Nick) ->
  Txt =  <<Nick/binary," left the group.">>,
  send_sys_msg(Server, Group, User, UserCard, <<"left">>, Txt, []);
system_message(update, Server, Group, User, NewCard, OldCard) ->
  NewName = get_name(NewCard),
  OldName = get_name(OldCard),
  Txt =  <<OldName/binary," is now known as ",NewName/binary>>,
  send_sys_msg(Server, Group, User, OldCard, <<"update">>, Txt, []);
system_message(user_avatar, Server, Group, User, UserCard, _Nick) ->
  send_sys_msg(Server, Group, User, UserCard, <<"update">>, <<>>, []);
system_message(_, _, _, _, _, _) ->
  ok.


send_sys_msg(Server, Group, _User, UserCard, Type, Txt, SubEls) ->
  GroupJID = jid:from_string(Group),
  {MsgType, Body} = case Txt of
                      <<>> -> {headline, []};
                      _ ->
                        {chat, [#text{lang = <<>>, data = Txt}]}
         end,
  ID = create_id(),
  OriginID = #origin_id{id = ID},
  SysMsg = #groups_sys_msg{actor = UserCard, type = Type},
  GroupX = #groups_x{sub_els = [SysMsg]},
  Els = [OriginID, GroupX] ++ SubEls,
  Msg = #message{type = MsgType, from = GroupJID, to = GroupJID,
    id = ID, body = Body, sub_els = Els, meta = #{}},
  {Msg1, _State} = ejabberd_hooks:run_fold(
    user_send_packet, Server, {Msg, #{jid => GroupJID}}, []),
  case Type of
    <<"create">> -> ok;
    _ ->
      send_to_all(Server, Group, ID, Msg1)
  end.

send_to_all(Server, Group, OriginID, Msg) ->
  #message{meta = #{stanza_id := TS}} = Msg,
  GroupJID = jid:from_string(Group),
  mod_groups_messages:set_displayed(GroupJID, GroupJID,
    TS, OriginID),
  Users = mod_groups_users:users_to_send(Server, Group),
  lists:foreach(fun(To) ->
    ejabberd_router:route(jid:replace_resource(GroupJID,<<"Group">>),
      To, Msg) end, Users).


maybe_send_to_index(_Server, _Group) -> ok.

get_name(UserCard) ->
  Nick = UserCard#groups_user.nickname,
  Badge = case UserCard#groups_user.badge of
            undefined -> <<>>;
            V -> V
          end,
  <<Nick/binary,Badge/binary>>.

-spec create_id() -> binary().
create_id() ->
  A = randoms:get_alphanum_string(10),
  B = randoms:get_alphanum_string(4),
  C = randoms:get_alphanum_string(4),
  D = randoms:get_alphanum_string(4),
  E = randoms:get_alphanum_string(10),
  ID = <<A/binary, "-", B/binary, "-", C/binary, "-", D/binary, "-", E/binary>>,
  list_to_binary(string:to_lower(binary_to_list(ID))).