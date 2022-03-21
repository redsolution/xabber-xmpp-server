%%%-------------------------------------------------------------------
%%% File    : mod_registration_keys.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : Secret registration keys
%%% Created : 15 March 2022 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%%
%%%
%%% xabberserver, Copyright (C) 2007-2022   Redsolution OÜ
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
-module(mod_registration_keys).
-author("ilya.kalashnikov@redsolution.com").
-behaviour(gen_mod).
-include("xmpp.hrl").
-include("logger.hrl").
-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).

%% gen_mod
-export([start/2, stop/1, mod_options/1, depends/2, reload/3]).
%% external
-export([get_keys/1, make_key/3, add_key/4, update_key/4, remove_key/2, check_key/2]).




start(_Host, _Opts) -> ok.

stop(_Host) -> ok.

reload(_Host, _NewOpts, _OldOpts) -> ok.

depends(_Host, _Opts) -> [].

mod_options(_Host) -> [].



get_keys(Server)->
  case sql_select_keys(Server) of
    {error, _} -> error;
    R -> R
  end.


make_key(Server, Expire, Desc) when is_integer(Expire) ->
  <<SrvID:10/binary,_/binary>> = str:sha(Server),
  RStr = list_to_binary(str:to_lower(binary_to_list(randoms:get_alphanum_string(6)))),
  Key = <<SrvID/binary,RStr/binary>>,
  case add_key(Server, Key, Expire, Desc) of
    ok -> {Key, Expire, Desc};
    _ -> error
  end;
make_key(_Server, _Expire, _Desc) ->
  error.

add_key(_Server, Key, Expire, _Desc) when Key == <<>> orelse not is_integer(Expire) ->
  error;
add_key(Server, Key, Expire, Desc) ->
  case sql_save_key(Server, Key, Expire, Desc) of
    ok ->
      ok;
    _ ->
      error
  end.

update_key(_Server, Key, Expire, _Desc) when Key == <<>> orelse not is_integer(Expire) ->
  error;
update_key(Server, Key, Expire, Desc) ->
  sql_update_key(Server, Key, Expire, Desc).

remove_key(Server, Key) ->
  sql_remove_key(Server, Key),
  ok.

check_key(LServer, Key) ->
  case sql_check_key(LServer, Key) of
    ok -> allow;
    _ -> deny
  end.

%% Utils
-spec seconds_since_epoch(integer()) -> non_neg_integer().
seconds_since_epoch(Diff) ->
  {Mega, Secs, _} = os:timestamp(),
  Mega * 1000000 + Secs + Diff.

%% SQL
sql_check_key(LServer, _Key)->
  _Now = seconds_since_epoch(0),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @('true')b from registration_keys"
    " where key=%(_Key)s  and not removed and expire > %(_Now)d and %(LServer)H")) of
    {selected, [{_}]} -> ok;
    _ -> {error, db_failure}
  end.

sql_select_keys(LServer)->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(key)s,@(expire)d,@(description)s from registration_keys"
    " where not removed and %(LServer)H")) of
    {selected, R} -> R;
    _ -> {error, db_failure}
  end.

sql_save_key(LServer, _Key, _Expire, _Desc)->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL_INSERT(
      "registration_keys",
      ["key=%(_Key)s",
        "server_host=%(LServer)s",
        "expire=%(_Expire)d",
        "description=%(_Desc)s"])) of
    {updated, _} ->
      ok;
    _ ->
      {error, db_failure}
  end.

sql_update_key(LServer, _Key, _Expire, _Desc)->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("update registration_keys set expire=%(_Expire)d, description=%(_Desc)s where"
    " key=%(_Key)s and %(LServer)H ")) of
    {updated,1} ->
      ok;
    {updated,0} ->
      notfound;
    _->
      error
  end.

sql_remove_key(LServer, _Key)->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update registration_keys set removed = true where"
         " key=%(_Key)s and %(LServer)H ")).
