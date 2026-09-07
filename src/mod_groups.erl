%%%-------------------------------------------------------------------
%%% File    : mod_groups.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : Main module of Groups.
%%% Created : 22 Jan 2022 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
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
-module(mod_groups).
-author('ilya.kalashnikov@redsolution.com').
-behavior(gen_mod).

-include("logger.hrl").

%% gen_mod
-export([start/2, stop/1, depends/2, mod_options/1, mod_opt_type/1]).

%% API
-export([get_option/2]).

-define(SUBMODULES, [
  groups_groups,
  groups_discovery,
  groups_iq_handler,
  groups_messages,
  groups_presences,
  groups_retract,
  groups_members,
  groups_avatars,
  groups_notifications]).


%% gen_mod
start(Host, _Opts) ->
  lists:foreach(fun(Module) ->
    start_module(Host,Module) end, ?SUBMODULES),
  ok.

stop(_Host) ->
  ok.

depends(_Host, _Opts) ->
  [{mod_http_upload, hard},
    {mod_groups_permissions, soft}].

mod_options(_Host) ->
  [
%%    {session_lifetime, 45},
    {remove_empty, true},
    {global_indexs, []},
    {avatar_max_size, 524288},
    {denied_messages_limit, "5/10:60"}
  ].

%%mod_opt_type(session_lifetime) ->
%%  fun(I) when is_integer(I), I > 0 -> I end;

mod_opt_type(remove_empty) ->
  fun (B) when is_boolean(B) -> B end;
mod_opt_type(global_indexs) ->
  fun (L) -> lists:map(fun iolist_to_binary/1, L) end;
mod_opt_type(avatar_max_size) ->
  fun (A) when is_integer(A) andalso A >= 0 -> A end;
mod_opt_type(denied_messages_limit) ->
  fun parse_denied_messages_limit/1.

parse_denied_messages_limit(Value) when is_list(Value) ->
  case re:run(Value,
    "^([1-9][0-9]*)/([1-9][0-9]*):([1-9][0-9]*)$",
    [{capture, all_but_first, list}]) of
    {match, [Limit, Window, BanLifetime]} ->
      {list_to_integer(Limit),
        list_to_integer(Window),
        list_to_integer(BanLifetime)};
    nomatch ->
      erlang:error(badarg)
  end;
parse_denied_messages_limit(_) ->
  erlang:error(badarg).

%% Internal
start_module(Host, Module) ->
  try case Module:start(Host, []) of
        ok -> ok;
        {ok, Pid} when is_pid(Pid) -> {ok, Pid};
        Err -> erlang:error(Err)
      end
  catch Class:Reason:ST ->
    ErrorText =
      case Reason == undef andalso
        code:ensure_loaded(Module) /= {module, Module} of
        true ->
          io_lib:format("Failed to load unknown module "
          "~s for host ~s: make sure "
          "there is no typo and ~s.beam "
          "exists inside either ~s or ~s "
          "directory",
            [Module, Host, Module,
              filename:dirname(code:which(?MODULE)),
              ext_mod:modules_dir()]);
        false ->
          io_lib:format("Problem starting the module ~s for host "
          "~s ~n ~p: ~p~n~p",
            [Module, Host, Class, Reason,
              ST])
      end,
    ?CRITICAL_MSG(ErrorText, []),
    erlang:raise(Class, Reason, ST)
  end.

%% API
get_option(Server, Option) ->
  gen_mod:get_module_opt(Server, ?MODULE, Option).
