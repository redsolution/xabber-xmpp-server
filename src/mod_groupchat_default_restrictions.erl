%%%-------------------------------------------------------------------
%%% File    : mod_groupchat_default_restrictions.erl
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

-module(mod_groupchat_default_restrictions).
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
  restrictions/2,
  set_restrictions/3
]).

%% Hook groupchat_default_rights_form set_groupchat_default_rights
-export([check_if_exist/5, check_if_has_rights/5]).

%% Hook set_groupchat_default_rights set_groupchat_default_rights
-export([check_values/5, set_values/5]).

start(Host, _Opts) ->
  ejabberd_hooks:add(set_groupchat_default_rights, Host, ?MODULE, check_if_exist, 10),
  ejabberd_hooks:add(set_groupchat_default_rights, Host, ?MODULE, check_values, 20),
  ejabberd_hooks:add(set_groupchat_default_rights, Host, ?MODULE, set_values, 30),
  ejabberd_hooks:add(groupchat_default_rights_form, Host, ?MODULE, check_if_exist, 10),
  ejabberd_hooks:add(groupchat_default_rights_form, Host, ?MODULE, check_if_has_rights, 20).

stop(Host) ->
  ejabberd_hooks:delete(set_groupchat_default_rights, Host, ?MODULE, check_if_exist, 10),
  ejabberd_hooks:delete(set_groupchat_default_rights, Host, ?MODULE, check_values, 20),
  ejabberd_hooks:delete(set_groupchat_default_rights, Host, ?MODULE, set_values, 30),
  ejabberd_hooks:delete(groupchat_default_rights_form, Host, ?MODULE, check_if_exist, 10),
  ejabberd_hooks:delete(groupchat_default_rights_form, Host, ?MODULE, check_if_has_rights, 20).

depends(_Host, _Opts) ->  [].

mod_options(_Opts) -> [].

check_if_exist(Acc, User, Chat, LServer, _Lang) ->
  case mod_groupchat_users:check_user_if_exist(LServer,User,Chat) of
    not_exist ->
      {stop,not_ok};
    _ ->
      Acc
  end.

check_if_has_rights(_Acc, User, Chat, LServer, Lang) ->
  case mod_groupchat_restrictions:is_permitted(<<"change-group">>,User,Chat) of
    true ->
      {stop, {ok,create_default_right_form(Chat, LServer, Lang)}};
    _ ->
      {stop, not_ok}
  end.

check_values(Acc, User, Chat, LServer, _Lang) ->
  FS = decode(LServer,Acc),
  case mod_groupchat_restrictions:is_permitted(<<"change-group">>,User,Chat) of
    true when FS =/= not_ok ->
      {ok,Values} = FS,
      NewValues = Values -- get_default_current_rights(LServer,Chat),
      validate(NewValues);
    _ ->
      {stop, not_ok}
  end.

set_values(Acc, _User, Chat, LServer, Lang) ->
  lists:foreach(fun(El) ->
    {Right,Value} = El,
    set_default_restrictions(LServer,Chat,Right,Value) end, Acc),
  {stop, {ok, create_result_right_form(Chat,LServer,Lang)}}.

-spec decode(binary(),list()) -> list().
decode(LServer, FS) ->
  Decoded = decode(LServer, [],filter_fixed_fields(FS)),
  case lists:member(false,Decoded) of
    true ->
      not_ok;
    _ ->
      {ok,Decoded}
  end.

-spec decode(binary(),list(),list()) -> list().
decode(LServer, Acc,[#xdata_field{var = Var, values = Values} | RestFS]) ->
  decode(LServer,[get_and_validate(LServer,Var,Values)| Acc], RestFS);
decode(_LServer, Acc, []) ->
  Acc.

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

-spec get_and_validate(binary(),binary(),list()) -> binary().
get_and_validate(LServer,RightName,Value) ->
  AllRights = mod_groupchat_restrictions:get_all_rights(LServer),
  Restrictions = [{R,D}||{R,T,D} <- AllRights, T == <<"restriction">>],
  case lists:keyfind(RightName,1,Restrictions) of
    {RightName,_Desc} ->
      {RightName,Value};
    _ ->
      false
  end.

is_valid_value([],_ValidValues) ->
  true;
is_valid_value([Value],ValidValues) ->
  lists:member(Value,ValidValues);
is_valid_value(_Other,_ValidValues) ->
  false.

valid_values() ->
  [<<>>,<<"300">>,<<"600">>,<<"900">>,<<"1800">>,<<"3600">>,<<"604800">>,<<"2592000">>].

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

restrictions(Query,Iq) ->
  #iq{to = To} = Iq,
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  Restrictions = Query#xabbergroupchat_query_rights.restriction,
  case length(Restrictions) of
    0 ->
      xmpp:err_bad_request();
    _ ->
      lists:foreach(fun(N) ->
        Name = N#xabbergroupchat_restriction.name,
        Time = N#xabbergroupchat_restriction.expires,
        set_default_rights(Server,Chat,Name,Time)
                    end, Restrictions),
      xmpp:make_iq_result(Iq)
  end.

create_default_right_form(Chat, LServer, Lang) ->
  Rights = default_rights(LServer,Chat,Lang),
      Fields = [
        #xdata_field{var = <<"FORM_TYPE">>, type = hidden, values = [?NS_GROUPCHAT]}| Rights
      ],
      #xabbergroupchat{
        xmlns = ?NS_GROUPCHAT_DEFAULT_RIGHTS,
        sub_els = [
          #xdata{type = form,
            title = <<"Groupchat default rights change">>,
            instructions = [<<"Fill out this form to change the default rights of group chat">>],
            fields = Fields}
        ]}.

create_result_right_form(Chat,LServer,Lang) ->
  Rights = default_rights_no_options(LServer,Chat,Lang),
  Fields = [
    #xdata_field{var = <<"FORM_TYPE">>, type = hidden, values = [?NS_GROUPCHAT]}| Rights
  ],
  #xabbergroupchat{
    xmlns = ?NS_GROUPCHAT_DEFAULT_RIGHTS,
    sub_els = [
      #xdata{type = result,
        title = <<"Groupchat default rights">>,
        fields = Fields}
    ]}.

default_rights_no_options(LServer, Chat, Lang) ->
  DefaultRights = get_default_rights(LServer,Chat),
  AllRights = mod_groupchat_restrictions:get_all_rights(LServer),
  Restrictions = [{R,D}||{R,T,D} <- AllRights, T == <<"restriction">>],
  RestrictionsFields = lists:map(fun(Right) ->
    {Name,Desc} = Right,
    Values = get_time(Name,DefaultRights),
    #xdata_field{var = Name, label = translate:translate(Lang,Desc), type = 'list-single',
      values = Values
    }
                                 end, Restrictions
  ),
  RestrictionSection = [#xdata_field{var= <<"restriction">>, type = 'fixed', values = [<<"Restrictions">>]}],
  RestrictionSection ++ RestrictionsFields.

default_rights(LServer, Chat, Lang) ->
  DefaultRights = get_default_rights(LServer,Chat),
  AllRights = mod_groupchat_restrictions:get_all_rights(LServer),
  Restrictions = [{R,D}||{R,T,D} <- AllRights, T == <<"restriction">>],
  RestrictionsFields = lists:map(fun(Right) ->
    {Name,Desc} = Right,
    Values = get_time(Name,DefaultRights),
    #xdata_field{var = Name, label = translate:translate(Lang,Desc), type = 'list-single',
      values = Values,
      options = form_options()
    }
                                 end, Restrictions
  ),
  RestrictionSection = [#xdata_field{var= <<"restriction">>, type = 'fixed', values = [<<"Restrictions">>]}],
  RestrictionSection ++ RestrictionsFields.

get_default_rights(LServer,Chat) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(right_name)s,@(action_time)s from groupchat_default_restrictions where chatgroup=%(Chat)s")) of
    {selected,[]} ->
      [];
    {selected,[{}]} ->
      [];
    {selected,Rights} ->
      Rights
  end.

get_default_current_rights(LServer,Chat) ->
  DefaultRights = get_default_rights(LServer,Chat),
  lists:map(fun(El) -> {Name,Value} = El, {Name,[Value]} end, DefaultRights).

get_time(Right,RightsList) ->
  case lists:keyfind(Right,1,RightsList) of
    {Right,Time} ->
      [Time];
    _ ->
      []
  end.

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
  case ?SQL_UPSERT(Server, "groupchat_default_restrictions",
    [
      "action_time=%(Time)s",
      "!right_name=%(Right)s",
      "!chatgroup=%(Chat)s"
    ]) of
    ok ->
      ok;
    _ ->
      {error, db_failure}
  end.

set_restrictions(Server,User,Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(right_name)s,@(action_time)s from groupchat_default_restrictions where chatgroup=%(Chat)s")) of
    {selected,[]} ->
      ok;
    {selected,[{}]} ->
      ok;
    {selected,Restrictions} ->
      lists:map(fun(N) ->
        {Rule,Time} = N,
        ActionTime = set_time(Time),
      mod_groupchat_restrictions:upsert_rule(Server,Chat,User,Rule,ActionTime,<<"server">>) end, Restrictions),
        ok;
    _ ->
      ok
  end.
set_default_restrictions(LServer, Chat, Right, [<<>>]) ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from groupchat_default_restrictions where chatgroup=%(Chat)s and right_name=%(Right)s"));
set_default_restrictions(LServer, Chat, Right, []) ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from groupchat_default_restrictions where chatgroup=%(Chat)s and right_name=%(Right)s"));
set_default_restrictions(LServer, Chat, Right, [Time]) ->
  set_default_rights(LServer,Chat,Right,Time).

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