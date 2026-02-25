%%%-------------------------------------------------------------------
%%% File    : groups_invites.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : Processing invitations.
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

-module(groups_invites).
-author('ilya.kalashnikov@redsolution.com').
-compile([{parse_transform, ejabberd_sql_pt}]).

-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").

%%API
-export([get_invites/3,
  revoke/3, revoke/4,
  invite_user/4
]).


%% External

invite_user(Server, Group, User, Invite) ->
  case invite_allowed(Server, Group, User) of
    true ->
      #groups_invite{target = JID, send = Send,
        reason = Reason } = Invite,
      case check_target(Server, Group, JID) of
        ok ->
          Target = jid:to_string(jid:remove_resource(JID)),
          add_user_to_group(Server, Group, User, Target, Send, Reason);
        exists ->
          {error, xmpp:err_conflict(<<"User was already invited">>,<<>>)};
        blocked ->
          {error, xmpp:err_not_allowed(<<"User is blocked">>,<<>>)};
        _ ->
          {error, xmpp:err_forbidden()}
      end;
    _ ->
      {error, xmpp:err_not_allowed()}
  end.

get_invites(Server, Group, User) ->
  case groups_members:is_permitted(Server, Group, User,
    get_invited_users, false, []) of
    true ->
      get_invited_users(Server, Group);
    _ ->
      get_invited_users(Server, Group, User)
  end.

revoke(Server, Group, JIDS) ->
  remove_invite(Server, Group, JIDS).

revoke(Server, Group, User, JIDS) ->
  case groups_members:is_permitted(Server, Group, User,
    revoke_invite, false, []) of
    true ->
      remove_invite(Server, Group, JIDS);
    _ ->
      remove_invite(Server, Group, User, JIDS)
  end.


%%Internal

invite_allowed(Server, Group, User) ->
  case groups_groups:get_info(Group, [parent]) of
    [<<"0">>] ->
      groups_members:is_permitted(Server, Group, User,
        add_members, true, []);
    _ ->
      false
  end.

check_target(Server, Group, UserJID) ->
  IsGroup = case UserJID#jid.lserver of
              Server ->
                mod_xabber_entity:is_group(UserJID#jid.luser, Server);
              _ ->
                false
            end,
  if
    not IsGroup ->
      User = jid:to_string(jid:remove_resource(UserJID)),
      case groups_block:is_blocked(Server, Group, User) of
        false ->
          Subs = groups_members:user_subscription(Server,
            User, Group),
          if
            Subs == <<"both">> orelse  Subs == <<"wait">> ->
              exists;
            true ->
              ok
          end;
        _ ->
          blocked
      end;
    true ->
      forbidden
  end.

add_user_to_group(Server, Group, Actor, User, Send, Reason) ->
  groups_members:add_invited_user(Server, Group, User, Actor),
  case Send of
    true ->
      send_invite(Server, Group, User, Reason);
    _->
      ok
  end.

send_invite(Server, Group, User, Reason) ->
  GroupDetails = groups_groups:group_details(Server, User, Group,
    [{full, true}, {members, true}]),
  Text = <<"You have been invited to the group chat ",Group/binary,".
   Please add it to your contacts to join">>,
  GroupJID = jid:from_string(Group),
  Invite = #groups_invite{reason = Reason, jid = GroupJID},
  Message = #message{
    type = chat,
    id = randoms:get_string(),
    from = jid:replace_resource(GroupJID, <<"Group">>),
    to = jid:from_string(User),
    body = [#text{lang = <<>>,data = Text}],
    sub_els = [Invite, GroupDetails]},
  ejabberd_router:route(Message).

get_invited_users(Server, Group) ->
  List = sql_get_invited(Server, Group),
  invites_query_result(List).

get_invited_users(Server, Group, User) ->
  List = sql_get_invited(Server, Group, User),
  invites_query_result(List).

invites_query_result([]) ->
  #groups_invites{};
invites_query_result(List) ->
  JIDs = lists:map(fun({User})->
    jid:from_string(User)
                   end, List),
  #groups_invites{list = JIDs}.

remove_invite(Server, Group, JIDS) ->
  R = sql_remove_invite(Server, Group, JIDS),
  remove_invite_result(R, Group, JIDS).

remove_invite(Server, Group, User, JIDS) ->
  R = sql_remove_invite(Server, Group, User, JIDS),
  remove_invite_result(R, Group, JIDS).

remove_invite_result(Result, Group, JIDS) ->
  case Result of
    ok ->
      From = jid:from_string(Group),
      To = jid:from_string(JIDS),
      Unsubscribe = #presence{type = unsubscribe, from = From, to= To},
      Unavailable = #presence{type = unavailable,from = From, to= To},
      ejabberd_router:route(Unavailable),
      ejabberd_router:route(Unsubscribe),
      ok;
    _ ->
      {error, xmpp:err_item_not_found()}
  end.

%% SQL

sql_get_invited(Server,Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_users
    where chatgroup = %(Chat)s
    and subscription = 'wait'")) of
    {selected, Users} -> Users;
    _-> []
  end.

sql_get_invited(Server,Chat, User) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_users
    where chatgroup = %(Chat)s
    and subscription = 'wait' and invited_by = %(User)s")) of
    {selected, Users} -> Users;
    _-> []
  end.

sql_remove_invite(Server, Group, JIDS) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_users where "
    " username=%(JIDS)s and chatgroup=%(Group)s "
    " and subscription='wait'")) of
    {updated, 1} -> ok;
    _ -> error
  end.

sql_remove_invite(Server, Group, User, JIDS) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_users where "
    " username=%(JIDS)s and chatgroup=%(Group)s "
    " and subscription='wait' and invited_by=%(User)s")) of
    {updated, 1} -> ok;
    _ -> error
  end.
