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

-module(mod_groupchat_sql).
-author('andrey.gagarin@redsolution.com').
-compile([{parse_transform, ejabberd_sql_pt}]).


-export([start/1, stop/1,
        add_to_channel_list/3,
        add_to_groupchat_user_list/5,
        add_user_to_groupchat/6,
        list_channels/2,
        user_subsription/3,
        user_list_of_channel/2,
        change_subscription/4,
        check_and_add/3,
        check_and_add/5,
        update_vcard_nick/5,
        get_vcard_info/2,
        check_jid/2,
        get_nick/2,
        search_for_chat/2,
        update_groupchat/9,
        check_and_add/6,
        update_hash/3,
        get_hash/2,
        set_update_status/3,
        get_update_status/2,
        get_photo/2,
        user_list_to_send/2,
        get_information_of_chat/2,
        get_user_nick/3,
        count_users/2, update_last_seen/3
        ]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("ejabberd_sql_pt.hrl").

start(_Host) -> ok.

stop(_Host) -> ok.


user_list_to_send(Server, Groupchat) ->
ejabberd_sql:sql_query(
  Server,
  ?SQL("select @(username)s from groupchat_users where chatgroup=%(Groupchat)s and subscription='both'")).

get_photo(Server,Jid) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(image)s
       from groupchat_users_vcard where jid=%(Jid)s")) of
    {selected,[{null}]} ->
      not_exist;
    {selected,[]} ->
      not_exist;
    {selected,[{Image}]} ->
      {exist,Image}
  end.

get_hash(Server,Jid) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(hash)s
       from groupchat_users_vcard where jid=%(Jid)s")) of
    {selected,[]} ->
      <<>>;
    {selected,[{Hash}]} ->
      Hash
  end.

set_update_status(Server,Jid,Status) ->
  case ?SQL_UPSERT(Server, "groupchat_users_vcard",
    ["fullupdate=%(Status)s",
      "!jid=%(Jid)s"]) of
    ok ->
      ok;
    _Err ->
      {error, db_failure}
  end.

get_update_status(Server,Jid) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(fullupdate)s
       from groupchat_users_vcard where jid=%(Jid)s")) of
    {selected,[]} ->
      <<>>;
    {selected,[{Status}]} ->
      Status
  end.

update_hash(Server,Jid,Hash) ->
  case ?SQL_UPSERT(Server, "groupchat_users_vcard",
    ["hash=%(Hash)s",
      "!jid=%(Jid)s"]) of
    ok ->
      ok;
    _Err ->
      {error, db_failure}
  end.

get_user_nick(Server,Jid,_Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(givenfamily)s,@(fn)s,@(nickname)s
       from groupchat_users_vcard where jid=%(Jid)s")) of
    {selected,[]} ->
      Jid;
    {selected,Names} ->
      [{Fl,Fn,Nick}] = Names,
      get_first_not_null([Nick,Fl,Fn,Jid])
  end.

get_first_not_null(List) ->
  N = [X || X <- List, bit_size(X) > 0],
  [H|_T] = N,
  H.

get_nick(Server,Chat) ->
  case ejabberd_sql:sql_query(
  Server,
  ?SQL("select @(name)s from groupchats 
  where jid=%(Chat)s")) of
    {selected,[]} ->
      <<>>;
    {selected,[{Nick}]} ->
      Nick
  end.

update_groupchat(Server,Jid,Name,Search,Desc,Model,Message,DomainList,ContactList) ->
    case ?SQL_UPSERT(Server, "groupchats",
                     ["name=%(Name)s",
                       "searchable=%(Search)s",
                       "description=%(Desc)s",
                       "model=%(Model)s",
                       "message=%(Message)d",
                       "domains=%(DomainList)s",
                       "contacts=%(ContactList)s",
                      "!jid=%(Jid)s"]) of
             ok ->
                     ok;
             _Err ->
                     {error, db_failure}
    end.

search_for_chat(Server,Groupchat) ->
  ejabberd_sql:sql_query(
  Server,
  ?SQL("select @(jid)s from groupchats 
  where jid=%(Groupchat)s")).

get_vcard_info(Server,JID) ->
  case ejabberd_sql:sql_query(
  Server,
  ?SQL("select @(givenfamily)s,@(fn)s,@(nickname)s,@(image)s,@(hash)s
       from groupchat_users_vcard where jid=%(JID)s")) of
    {selected,[Info]} ->
      Info;
    {selected,[]} ->
      []
   end.

update_vcard_nick(Server,Jid,GIVENFAMILY,FN,NICKNAME) ->
  case ?SQL_UPSERT(Server, "groupchat_users_vcard",
    ["!JID=%(Jid)s",
      "givenfamily=%(GIVENFAMILY)s",
      "fn=%(FN)s",
      "nickname=%(NICKNAME)s"
    ]) of
    ok ->
      ok;
    _Err ->
      {error, db_failure}
  end.

check_jid(Server,JID) ->
    Q =ejabberd_sql:sql_query(
      Server,
      ?SQL("select @(jid)s from groupchat_users_vcard")),
    {selected,List} = Q,
    lists:member({JID},List).


check_and_add(Server,Channel,Owner) ->
    {_,List} = list_channels(Server,[]),
    Existing_groupchats = [element(1,X) || X <- List],
    case lists:member(Channel,Existing_groupchats) of
        true -> ok;
        false ->
            add_to_channel_list(Server,Channel,Owner)
    end.

check_and_add(Server,User,Role,Chatgroup,Subscription) ->
    {_,List} = users_and_groupchats(Server,[]),
    User_to_add = {User,Chatgroup},
    case lists:member(User_to_add,List) of
        true -> ok;
        false ->
            add_to_groupchat_user_list(Server,User,Role,Chatgroup,Subscription),
            mod_admin_extra:add_rosteritem(User,Server,Chatgroup,Server,Chatgroup,<<"xabberchats">>,<<"both">>),
            mod_admin_extra:add_rosteritem(Chatgroup,Server,User,Server,User,<<"xabberchats">>,<<"both">>)
    end.

check_and_add(Server,User,Role,Chatgroup,Host,Subscription) ->
    {_,List} = users_and_groupchats(Server,[]),
    User_to_add = {User,Host,Chatgroup},
    case lists:member(User_to_add,List) of
        true -> ok;
        false ->
            add_user_to_groupchat(Server,User,Role,Chatgroup,Host,Subscription)
    end.

change_subscription(Server,Chat,Username,State) ->
    case ?SQL_UPSERT(Server, "groupchat_users",
                     ["!username=%(Username)s",
                      "!chatgroup=%(Chat)s",
                      "subscription=%(State)s"]) of
             ok ->
                     ok;
             _Err ->
                     {error, db_failure}
    end.

users_and_groupchats(Server,[]) ->
    ejabberd_sql:sql_query(
      Server,
      ?SQL("select @(username)s,@(host)s,@(chatgroup)s from groupchat_users")).

user_list_of_channel(Server, Groupchat) ->
    ejabberd_sql:sql_query(
      Server,
      ?SQL("select @(username)s from groupchat_users where chatgroup=%(Groupchat)s")).

list_channels(Server, []) ->
    ejabberd_sql:sql_query(
      Server,
      ?SQL("select @(name)s from groupchats")).

add_to_channel_list(Server,Channel,Owner) ->
    ejabberd_sql:sql_query(
      Server,
      ?SQL_INSERT(
         "groupchats",
         ["name=%(Channel)s",
          "owner=%(Owner)s"])).

add_to_groupchat_user_list(Server,User,Role,Chatgroup,Subscription) ->
    ejabberd_sql:sql_query(
      Server,
      ?SQL_INSERT(
         "groupchat_users",
         ["username=%(User)s",
          "host=%(Server)s",
          "role=%(Role)s",
          "chatgroup=%(Chatgroup)s",
          "subscription=%(Subscription)s"
         ])).

add_user_to_groupchat(Server,User,Role,Chatgroup,Host,Subscription) ->
    ejabberd_sql:sql_query(
      Server,
      ?SQL_INSERT(
         "groupchat_users",
         ["username=%(User)s",
          "host=%(Host)s",
          "role=%(Role)s",
          "chatgroup=%(Chatgroup)s",
          "subscription=%(Subscription)s"
         ])).

user_subsription(Groupchat,User,Server) ->
  ejabberd_sql:sql_query(
  Server,
  ?SQL("select @(subscription)s,@(ask)s from rosterusers 
  where username=%(Groupchat)s and jid=%(User)s")).

get_information_of_chat(Chat,Server) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(name)s,@(anonymous)s,@(searchable)s,@(model)s,@(description)s,@(message)d,@(contacts)s,@(domains)s
    from groupchats where jid=%(Chat)s and %(Server)H")).

count_users(Server,Chat) ->
  ejabberd_sql:sql_query(
    Server,
    [<<"select count(distinct username) from groupchat_users where chatgroup= '">>
      ,Chat,<<"' and subscription = 'both';">>
    ]
  ).

update_last_seen(Server,User,Chat) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("update groupchat_users set last_seen = now()
  where chatgroup=%(Chat)s and username=%(User)s")).