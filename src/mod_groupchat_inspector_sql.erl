%%%-------------------------------------------------------------------
%%% File    : mod_groupchat_sql.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Old module - will be removed soon
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

-module(mod_groupchat_inspector_sql).
-author('andrey.gagarin@redsolution.com').
-compile([{parse_transform, ejabberd_sql_pt}]).


-export([
          add_user/5,
         update_user_role/4,
  update_user_subscription/4,
         users_from_chat/2,
         check_user/3,
         delete_user_chat/3,
         create_groupchat/12,
         check_jid/2
        ]).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("ejabberd_sql_pt.hrl").
-include("xmpp.hrl").



check_user(User,Server,Chat) ->
  case ejabberd_sql:sql_query(
         Server,
         ?SQL("select @(username)s
         from groupchat_users where chatgroup=%(Chat)s 
              and username=%(User)s and subscription = 'both' ")) of
    {selected,[]} ->
      not_exist;
    {selected,_Users} ->
      exist
  end.



delete_user_chat(User,Server,Chat) ->
  From = jid:from_string(Chat),
  IsAnonim = mod_groupchat_inspector:is_anonim(Server,Chat),
  {_UserId,_Nickname} = mod_groupchat_inspector:get_user_id_and_nick(Server,User,Chat),
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_users where 
         username=%(User)s and chatgroup=%(Chat)s")) of
    {updated,1} when IsAnonim == yes->
      Unsubscribe = mod_groupchat_presence:form_unsubscribe_presence(),
      Unavailable = mod_groupchat_presence:form_presence_unavailable(),
      mod_groupchat_messages:send_message(Unsubscribe,[{User}],From),
      mod_groupchat_messages:send_message(Unavailable,[{User}],From),
      mod_groupchat_service_message:send_service_message(user_left,User,Chat);
    {updated,1} when IsAnonim == no ->
      Unsubscribe = mod_groupchat_presence:form_unsubscribe_presence(),
      Unavailable = mod_groupchat_presence:form_presence_unavailable(),
      mod_groupchat_messages:send_message(Unsubscribe,[{User}],From),
      mod_groupchat_messages:send_message(Unavailable,[{User}],From),
      mod_groupchat_service_message:send_service_message(user_left,User,Chat);
    _ ->
      nothing
  end,

  case users_from_chat(Chat,Server) of
    {selected,[]} ->
      ejabberd_sql:sql_query(
        Server,
        ?SQL("delete from archive where peer=%(Chat)s")
      );
    _ ->
      ok
  end.


users_from_chat(Chat,Server) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s,@(role)s from groupchat_users where chatgroup=%(Chat)s")).

check_jid(Jid,LServer) ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(localpart)s from groupchats where localpart=%(Jid)s and %(LServer)H")).

create_groupchat(LServer,Localpart,CreatorJid,Name,ChatJid,Anon,Search,Model,Desc,Message,Contacts,Domains) ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL_INSERT(
      "groupchats",
      ["name=%(Name)s",
        "server_host=%(LServer)s",
        "anonymous=%(Anon)s",
        "localpart=%(Localpart)s",
        "jid=%(ChatJid)s",
        "searchable=%(Search)s",
        "model=%(Model)s",
        "description=%(Desc)s",
        "message=%(Message)d",
        "contacts=%(Contacts)s",
        "domains=%(Domains)s",
        "owner=%(CreatorJid)s"])).


add_user(Server,User,Role,Chatgroup,Subscription) ->
  R = randoms:get_alphanum_string(16),
  R_s = binary_to_list(R),
  R_sl = string:to_lower(R_s),
  Id = list_to_binary(R_sl),
  ejabberd_sql:sql_query(
    Server,
    ?SQL_INSERT(
       "groupchat_users",
       ["username=%(User)s",
        "role=%(Role)s",
        "chatgroup=%(Chatgroup)s",
         "id=%(Id)s",
        "subscription=%(Subscription)s"
       ])).

update_user_role(Server,User,Chat,Role) ->
  case ?SQL_UPSERT(Server, "groupchat_users",
                   ["!username=%(User)s",
                      "!chatgroup=%(Chat)s",
                      "role=%(Role)s"]) of
             ok ->
                     ok;
             _Err ->
                     {error, db_failure}
    end.

update_user_subscription(Server,User,Chat,State) ->
  case ?SQL_UPSERT(Server, "groupchat_users",
                   ["!username=%(User)s",
                      "!chatgroup=%(Chat)s",
                      "subscription=%(State)s"]) of
             ok ->
                     ok;
             _Err ->
                     {error, db_failure}
    end.