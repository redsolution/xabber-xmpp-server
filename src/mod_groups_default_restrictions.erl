%%%-------------------------------------------------------------------
%%% File    : mod_groups_default_restrictions.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Default restrinctions for group chats
%%% Created : 23 Aug 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_groups_default_restrictions).
-author('andrey.gagarin@redsolution.com').
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).
-behavior(gen_mod).
%% gen_mod
-export([start/2, stop/1, mod_options/1, depends/2]).
%% API
-export([
  set_default_rights/4,
  set_restrictions/3
]).

%% Hook groupchat_default_rights_form set_groupchat_default_rights
-export([check_permission/5]).

%% Hook set_groupchat_default_rights set_groupchat_default_rights
-export([check_permission_and_values/5, set_values/5]).

start(Host, _Opts) ->
  ejabberd_hooks:add(set_groupchat_default_rights, Host, ?MODULE, check_permission_and_values, 20),
  ejabberd_hooks:add(set_groupchat_default_rights, Host, ?MODULE, set_values, 30),
  ejabberd_hooks:add(groupchat_default_rights_form, Host, ?MODULE, check_permission, 20).

stop(Host) ->
  ejabberd_hooks:delete(set_groupchat_default_rights, Host, ?MODULE, check_permission_and_values, 20),
  ejabberd_hooks:delete(set_groupchat_default_rights, Host, ?MODULE, set_values, 30),
  ejabberd_hooks:delete(groupchat_default_rights_form, Host, ?MODULE, check_permission, 20).

depends(_Host, _Opts) ->  [].

mod_options(_Opts) -> [].

check_permission(_Acc, User, Chat, LServer, Lang) ->
  case mod_groups_restrictions:
  is_permitted(<<"change-group">>,User,Chat) of
    true ->
      {stop, {ok, create_right_form(Chat, LServer, Lang, form)}};
    _ ->
      {stop, not_ok}
  end.

check_permission_and_values(Acc, User, Chat, LServer, _Lang) ->
  case mod_groups_restrictions:
  is_permitted(<<"change-group">>, User, Chat) of
    true ->
      case decode(LServer, Acc) of
        {ok, Values} ->
          NewValues = Values -- get_default_current_rights(LServer, Chat),
          validate(NewValues);
        _ ->
          bad_request
      end;
    _ ->
      {stop, not_allowed}
  end.

set_values(Acc, _User, Chat, LServer, Lang) ->
  lists:foreach(fun(El) ->
    {Right,Value} = El,
    set_default_restrictions(LServer,Chat,Right,Value) end, Acc),
  {stop, {ok, create_right_form(Chat, LServer, Lang, result)}}.

-spec decode(binary(),list()) -> list().
decode(LServer, FS) ->
  Restrictions1 = mod_groups_restrictions:get_all_restrictions(LServer),
  Restrictions = [ R || {R,_, _} <- Restrictions1],
  Decoded = lists:map(
    fun(#xdata_field{var = Var, values = Values}) ->
      case lists:member(Var, Restrictions) of
        true -> {Var, Values};
        _ -> false
      end end, filter_fixed_fields(FS)),
  case lists:member(false, Decoded) of
    true -> error;
    _ -> {ok, Decoded}
  end.

-spec filter_fixed_fields(list()) -> list().
filter_fixed_fields(FS) ->
  lists:filter(fun(F) ->
    #xdata_field{type = Type} = F,
    case Type of
      fixed ->
        false;
      hidden ->
        false;
      _ ->
        true
    end
               end, FS).

is_valid_value([],_ValidValues) ->
  true;
is_valid_value([Value],ValidValues) ->
  lists:member(Value,ValidValues);
is_valid_value(_Other,_ValidValues) ->
  false.

validate([]) ->
  {stop,bad_request};
validate(FS) ->
  ValidValues = valid_values(),
  Validation = lists:map(fun(El) ->
    {_Rightname,Values} = El,
    is_valid_value(Values,ValidValues)
                         end, FS),
  IsFailed = lists:member(false, Validation),
  case IsFailed of
    false ->
      FS;
    _ ->
      {stop, bad_request}
  end.

create_right_form(Chat, LServer, Lang, FormType) ->
  {WithOpts, Instr} =
    case FormType of
      result ->
        {false, []};
      _ ->
        {true, [<<"Fill out this form to change the default rights of group chat">>]}
    end,
  Rights = default_rights(LServer, Chat, Lang, WithOpts),
  Fields = [#xdata_field{var = <<"FORM_TYPE">>, type = hidden,
    values = [?NS_GROUPCHAT]} | Rights ],
  #xabbergroupchat{
    xmlns = ?NS_GROUPCHAT_DEFAULT_RIGHTS,
    sub_els = [
      #xdata{type = FormType,
        title = <<"Groupchat default rights">>,
        instructions = Instr,
        fields = Fields}
    ]}.

default_rights(LServer, Group, Lang, WithOpts) ->
  Restrictions = sql_get_all_restrictions(LServer, Group),
  Opts = case WithOpts of
           true -> form_options();
           _ -> []
         end,
  RestrictionsFields = lists:map(
    fun({Name, Desc, Time}) ->
      Values = case Time of
                 null -> [];
                 _ -> [Time]
               end,
      #xdata_field{var = Name, label = translate:translate(Lang,Desc),
        type = 'list-single', values = Values, options = Opts}
    end, Restrictions),
  RestrictionSection = [#xdata_field{var= <<"restriction">>,
    type = 'fixed', values = [<<"Restrictions">>]}],
  RestrictionSection ++ RestrictionsFields.

sql_get_all_restrictions(Server, Group)->
  case ejabberd_sql:sql_query(
  Server,
  ?SQL("select @(groupchat_rights.name)s,
  @(groupchat_rights.description)s,
  @(groupchat_default_restrictions.action_time)s
  from groupchat_rights
  LEFT JOIN groupchat_default_restrictions on
    groupchat_default_restrictions.right_name = groupchat_rights.name
    and groupchat_default_restrictions.chatgroup =%(Group)s
  where groupchat_rights.type='restriction'")) of
    {selected, L} -> L;
    _ -> []
  end.

sql_get_default_restrictions(LServer, Group) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(right_name)s,@(action_time)s
     from groupchat_default_restrictions
      where chatgroup=%(Group)s")) of
    {selected, Rights} -> Rights;
    _ -> []
  end.

get_default_current_rights(LServer,Chat) ->
  Defaults = sql_get_default_restrictions(LServer,Chat),
  [{Name,[Value]} || {Name,Value} <- Defaults].


valid_values() ->
  [<<>>,<<"0">>,<<"300">>,<<"600">>,<<"900">>,<<"1800">>,<<"3600">>,<<"604800">>,<<"2592000">>].

form_options() ->
  [
    #xdata_option{label = <<"5 minutes">>, value = [<<"300">>]},
    #xdata_option{label = <<"10 minutes">>, value = [<<"600">>]},
    #xdata_option{label = <<"15 minutes">>, value = [<<"900">>]},
    #xdata_option{label = <<"30 minutes">>, value = [<<"1800">>]},
    #xdata_option{label = <<"1 hour">>, value = [<<"3600">>]},
    #xdata_option{label = <<"1 week">>, value = [<<"604800">>]},
    #xdata_option{label = <<"1 month">>, value = [<<"2592000">>]},
    #xdata_option{label = <<"Forever">>, value = [<<"0">>]}
  ].


set_default_rights(Server,Chat,Right,Time) ->
  ?SQL_UPSERT(Server,
    "groupchat_default_restrictions",
    ["!chatgroup=%(Chat)s",
      "!right_name=%(Right)s",
      "action_time=%(Time)s"]).

set_restrictions(Server, User, Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(right_name)s,@(action_time)s
     from groupchat_default_restrictions where chatgroup=%(Chat)s")) of
    {selected, []} -> ok;
    {selected,Restrictions} ->
      lists:foreach(fun({Rule,Time} ) ->
        ActionTime = set_time(Time),
         mod_groups_restrictions:upsert_rule(Server,
           Chat, User, Rule, ActionTime, <<"server">>)
                    end, Restrictions);
    _ -> ok
  end.

set_default_restrictions(LServer, Chat, Right, [Time]) when Time /= <<>> ->
  set_default_rights(LServer,Chat,Right,Time);
set_default_restrictions(LServer, Chat, Right, _) ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from groupchat_default_restrictions
     where chatgroup=%(Chat)s and right_name=%(Right)s")).

%% Internal functions
set_time(<<"never">>) ->
  <<"0">>;
set_time(<<"0">>) ->
  <<"0">>;
set_time(Time) ->
  ExpireInteger = binary_to_integer(Time),
  TS = now_to_timestamp(now()),
  Sum = TS + ExpireInteger,
  integer_to_binary(Sum).

now_to_timestamp({MSec, Sec, _USec}) ->
  (MSec * 1000000 + Sec).