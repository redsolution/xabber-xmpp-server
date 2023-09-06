%%%-------------------------------------------------------------------
%%% File    : mod_groups_invites.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : Processing invitations.
%%% Created : 06 Sep 2023 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%%
%%%
%%% xabberserver, Copyright (C) 2007-2023   Redsolution OÜ
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

-module(mod_groups_invites).
-author('ilya.kalashnikov@redsolution.com').
-behavior(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).

-export([start/2, stop/1, depends/2, mod_options/1]).
-export([
  add_user/5,
  add_user/6,
  invite_right/2,
  check_user/2,
  send_invite/2,
  get_invited_users/2,
  get_invited_users/3,
  revoke/3,
  revoke/4,
  add_user_in_chat/2
]).

start(Host, _Opts) ->
  ejabberd_hooks:add(groupchat_invite_hook, Host, ?MODULE, invite_right, 10),
  ejabberd_hooks:add(groupchat_invite_hook, Host, ?MODULE, check_user, 20),
  ejabberd_hooks:add(groupchat_invite_hook, Host, ?MODULE, add_user_in_chat, 30),
  ejabberd_hooks:add(groupchat_invite_hook, Host, ?MODULE, send_invite, 80).

stop(Host) ->
  ejabberd_hooks:delete(groupchat_invite_hook, Host, ?MODULE, invite_right, 10),
  ejabberd_hooks:delete(groupchat_invite_hook, Host, ?MODULE, check_user, 20),
  ejabberd_hooks:delete(groupchat_invite_hook, Host, ?MODULE, add_user_in_chat, 30),
  ejabberd_hooks:delete(groupchat_invite_hook, Host, ?MODULE, send_invite, 80).

depends(_Host, _Opts) -> [].

mod_options(_Opts) -> [].

revoke(Server,User,Chat) ->
  remove_invite(Server,User,Chat).
revoke(Server, User, Chat, Admin) ->
  case mod_groups_restrictions:is_permitted(<<"change-group">>,Admin,Chat) of
    true ->
      remove_invite(Server,User,Chat);
    _ ->
      remove_invite(Server,User,Chat, Admin)
  end.


-spec get_invited_users(binary(),binary()) -> xabbergroupchat_invite_query().
get_invited_users(Server,Chat) ->
  List = sql_get_invited(Server,Chat),
  make_invite_query(List).

-spec get_invited_users(binary(),binary(),binary()) -> xabbergroupchat_invite_query().
get_invited_users(Server, Chat, User) ->
  List = sql_get_invited(Server, Chat, User),
  make_invite_query(List).

-spec make_invite_query(list()) -> xabbergroupchat_invite_query().
make_invite_query([]) ->
  #xabbergroupchat_invite_query{};
make_invite_query(List) ->
  UserList = lists:map(fun({User})->
    #xabbergroup_invite_user{jid = User}
                       end, List),
  #xabbergroupchat_invite_query{user = UserList}.

sql_get_invited(Server,Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_users
    where chatgroup = %(Chat)s
    and subscription = 'wait'")) of
    {selected,Users} ->
      Users;
    _->
      []
  end.

sql_get_invited(Server,Chat, User) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_users
    where chatgroup = %(Chat)s
    and subscription = 'wait' and invited_by = %(User)s")) of
    {selected,Users} ->
      Users;
    _->
      []
  end.

invite_right(_Acc, {Admin, Chat, _Server, _Invite}) ->
  case mod_groups_restrictions:is_restricted(<<"send-invitations">>, Admin, Chat) of
    true -> {stop,forbidden};
    _ -> ok
  end.

check_user(_Acc, {_A, Chat, Server, #xabbergroupchat_invite{invite_jid = User}}) ->
  {_,Domain,_} = jid:tolower(jid:from_string(User)),
  case mod_groups_block:check_block(Server, Chat , User, Domain) of
    ok ->
      Subs = mod_groups_users:check_user_if_exist(Server,User,Chat),
      if
        Subs == <<"both">> orelse  Subs == <<"wait">> ->
          {stop, exist};
        true ->
          ok
      end;
    Stop ->
      Stop
  end.

add_user_in_chat(_Acc, {Admin,Chat,Server,
  #xabbergroupchat_invite{invite_jid =  User, reason = _Reason, send = _Send}}) ->
  Role = <<"member">>,
  Subscription = <<"wait">>,
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set subscription = %(Subscription)s, invited_by = %(Admin)s where chatgroup=%(Chat)s
              and username=%(User)s and subscription='none'")) of
    {updated,N} when N > 0 ->
      ok;
    _ ->
      add_user(Server,User,Role,Chat,Subscription, Admin)
  end.

send_invite(_Acc, {Admin, Chat, _Server,
  #xabbergroupchat_invite{invite_jid = User, reason = Reason, send = Send}}) ->
  if
    Send == <<"1">> orelse Send == <<"true">> ->
      ejabberd_router:route(message_invite(User, Chat, Admin, Reason)),
      ok;
    true ->
      ok
  end.


message_invite(User,Chat,Admin,Reason) ->
  U = #xabbergroup_invite_user{jid = Admin},
  ChatJID = jid:from_string(Chat),
  LServer = ChatJID#jid.lserver,
  {ok, Anonymous, _} = mod_groups_chats:get_type_and_parent(LServer,Chat),
  Text = <<"Add ",Chat/binary," to the contacts to join a group chat">>,
    #message{type = chat,to = jid:from_string(User), from = jid:from_string(Chat), id = randoms:get_string(),
      sub_els = [#xabbergroupchat_invite{user = U, reason = Reason, jid = ChatJID},
        #xabbergroupchat_x{sub_els = [#xabbergroupchat_privacy{cdata = Anonymous}]}],
      body = [#text{lang = <<>>,data = Text}], meta = #{}}.

%% internal functions
remove_invite(Server,User,Chat) ->
  R = ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_users where
         username=%(User)s and chatgroup=%(Chat)s and subscription='wait'")),
  remove_invite_result(R, User, Chat).
remove_invite(Server, User, Chat, InvitedBy) ->
  R = ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_users where
         username=%(User)s and chatgroup=%(Chat)s and subscription='wait' and invited_by=%(InvitedBy)s")),
  remove_invite_result(R, User, Chat).

remove_invite_result(Result, User, Chat) ->
  case Result of
    {updated,1} ->
      From = jid:from_string(Chat),
      Users = [jid:from_string(User)],
      Unsubscribe = #presence{type = unsubscribe},
      Unavailable = #presence{type = unavailable},
      mod_groups_presence:send_presence(Unsubscribe, Users, From),
      mod_groups_presence:send_presence(Unavailable, Users, From),
      ok;
    _ ->
      {error, not_found}
  end.

add_user(Server, Member, Role, Group, Subs) ->
  add_user(Server, Member, Role, Group, Subs,<<>>).

add_user(Server, Member, Role, Group, Subs, InvitedBy) ->
  case mod_groups_users:check_user_if_exist(Server, Member, Group) of
    not_exist  ->
      mod_groups_users:add_user(Server, Member, Role,
        Group, Subs,InvitedBy);
    _ ->
      ok
  end.

