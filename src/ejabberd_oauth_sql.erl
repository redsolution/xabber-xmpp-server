%%%-------------------------------------------------------------------
%%% File    : ejabberd_oauth_sql.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : OAUTH2 SQL backend
%%% Created : 27 Jul 2016 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2018   ProcessOne
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
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%-------------------------------------------------------------------

-module(ejabberd_oauth_sql).
-behaviour(ejabberd_oauth).
-behaviour(ejabberd_config).
-compile([{parse_transform, ejabberd_sql_pt}]).

-export([init/0,
         store/1,
         lookup/1,
         clean/1, list_user_tokens/1, revoke_user_token/2, revoke_token/1, opt_type/1
  ]).

-include("ejabberd_oauth.hrl").
-include("ejabberd.hrl").
-include("ejabberd_sql_pt.hrl").
-include("jid.hrl").
-include("logger.hrl").

init() ->
    ok.

store(R) ->
  DefaultHost = find_host(),
    Token = R#oauth_token.token,
    {User, Server} = R#oauth_token.us,
    SJID = jid:encode({User, Server, <<"">>}),
    Scope = str:join(R#oauth_token.scope, <<" ">>),
    Expire = R#oauth_token.expire,
    case ?SQL_UPSERT(
	    DefaultHost,
	    "oauth_token",
	    ["!token=%(Token)s",
	     "jid=%(SJID)s",
	     "scope=%(Scope)s",
	     "expire=%(Expire)d"]) of
	ok ->
	    ok;
	_ ->
	    {error, db_failure}
    end.

lookup(Token) ->
  DefaultHost = find_host(),
    case ejabberd_sql:sql_query(
      DefaultHost,
           ?SQL("select @(jid)s, @(scope)s, @(expire)d"
                " from oauth_token where token=%(Token)s")) of
        {selected, [{SJID, Scope, Expire}]} ->
            JID = jid:decode(SJID),
            US = {JID#jid.luser, JID#jid.lserver},
            {ok, #oauth_token{token = Token,
			      us = US,
			      scope = str:tokens(Scope, <<" ">>),
			      expire = Expire}};
        _ ->
            error
    end.

clean(TS) ->
  DefaultHost = find_host(),
    ejabberd_sql:sql_query(
      DefaultHost,
      ?SQL("delete from oauth_token where expire < %(TS)d")).

list_user_tokens(BareJID) ->
  DefaultHost = find_host(),
  case ejabberd_sql:sql_query(
    DefaultHost,
    ?SQL("select @(token)s, @(scope)s, @(expire)d"
    " from oauth_token where jid=%(BareJID)s")) of
    {selected, []} ->
      [{<<>>,<<>>,<<>>}];
    {selected, [<<>>]} ->
      [{<<>>,<<>>,<<>>}];
    {selected, Tokens} ->
      List = lists:map(fun(N)->
        {Token, Scope, Expire} = N,
        {binary_to_list(Token),binary_to_list(Scope),integer_to_list(Expire) ++ " seconds"}
                       end, Tokens),
      List;
    _ ->
      error
  end.

revoke_user_token(BareJID, <<"all">>) ->
  Host = find_host(),
 case ejabberd_sql:sql_query(
    Host,
    ?SQL("delete from oauth_token where jid=%(BareJID)s")) of
   {updated,_N} ->
     ok;
   _ ->
     1
 end;
revoke_user_token(BareJID, Token) ->
  Host = find_host(),
 case ejabberd_sql:sql_query(
    Host,
    ?SQL("delete from oauth_token where jid=%(BareJID)s and token=%(Token)s")) of
   {updated,_N} ->
     ok;
   _ ->
     1
 end.

revoke_token(Token) ->
  Host = find_host(),
  case ejabberd_sql:sql_query(
    Host,
    ?SQL("delete from oauth_token where token=%(Token)s")) of
    {updated,_N} ->
      ok;
    _ ->
      1
  end.

find_host() ->
  DefaultHost = ejabberd_config:get_option(oauth_default_server),
  ?INFO_MSG("Host from config ~p",[DefaultHost]),
  case DefaultHost of
    undefined ->
      ?MYNAME;
    _ ->
      DefaultHost
  end.

opt_type(oauth_default_server) ->
  fun(I) when is_binary(I) -> I end;
opt_type(_) ->
  [oauth_default_server].