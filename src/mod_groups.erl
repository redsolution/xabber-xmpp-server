%%%-------------------------------------------------------------------
%%% File    : mod_groups.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : main module of groups
%%% Created : 22 Jan 2022 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
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
-module(mod_groups).
-author("ilya.kalashnikov@redsolution.com").
-behavior(gen_mod).
-include("logger.hrl").

%% API
-export([start/2, stop/1, depends/2, mod_options/1, mod_opt_type/1]).

-define(SUBMODULES, [
  mod_groups_access_model,
  mod_groups_block,
  mod_groups_chats,
  mod_groups_default_restrictions,
  mod_groups_discovery,
  mod_groups_domains,
  mod_groups_inspector,
  mod_groups_iq_handler,
  mod_groups_messages,
  mod_groups_presence,
  mod_groups_present_mnesia,
  mod_groups_retract,
  mod_groups_system_message,
  mod_groups_users,
  mod_groups_vcard]).


%% gen_mod
start(Host, _Opts) ->
  lists:foreach(fun(Module) ->
    start_module(Host,Module) end, ?SUBMODULES),
  ok.

stop(_Host) ->
  ok.

depends(_Host, _Opts) ->
  [{mod_http_upload, hard}].

mod_options(_Host) ->
  [
    {session_lifetime, 45},
    {remove_empty, true},
    {global_indexs, []}
  ].

mod_opt_type(session_lifetime) ->
  fun(I) when is_integer(I), I > 0 -> I end;

mod_opt_type(remove_empty) ->
  fun (B) when is_boolean(B) -> B end;

mod_opt_type(global_indexs) ->
  fun (L) -> lists:map(fun iolist_to_binary/1, L) end.

%% Internal
start_module(Host, Module) ->
  try case Module:start(Host, []) of
        ok -> ok;
        {ok, Pid} when is_pid(Pid) -> {ok, Pid};
        Err -> erlang:error(Err)
      end
  catch Class:Reason ->
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
              erlang:get_stacktrace()])
      end,
    ?CRITICAL_MSG(ErrorText, []),
    erlang:raise(Class, Reason, erlang:get_stacktrace())
  end.
