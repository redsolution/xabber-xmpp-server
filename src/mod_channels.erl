%%%-------------------------------------------------------------------
%%% File    : mod_channels.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Create and delete channels
%%% Created : 16 November 2020 by Andrey Gagarin <andrey.gagarin@redsolution.com>
%%%
%%%
%%% xabberserver, Copyright (C) 2007-2020   Redsolution OÜ
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

-module(mod_channels).
-author("andrey.gagarin@redsolution.ru").
-behavior(gen_mod).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).

-export([start/2, stop/1, depends/2, mod_options/1]).

%% Create channel hook
-export([check_localpart/6, check_unsupported_stanzas/6, check_params/6, create_channel/6, get_vcard/2]).

-export([get_channel_info/2, make_list/2, get_all/1]).
start(Host, _Opts) ->
  ejabberd_hooks:add(create_channel, Host, ?MODULE, check_localpart, 10),
  ejabberd_hooks:add(create_channel, Host, ?MODULE, check_unsupported_stanzas, 15),
  ejabberd_hooks:add(create_channel, Host, ?MODULE, check_params, 25),
  ejabberd_hooks:add(create_channel, Host, ?MODULE, create_channel, 35).

stop(Host) ->
  ejabberd_hooks:delete(create_channel, Host, ?MODULE, check_localpart, 10),
  ejabberd_hooks:delete(create_channel, Host, ?MODULE, check_unsupported_stanzas, 15),
  ejabberd_hooks:delete(create_channel, Host, ?MODULE, check_params, 25),
  ejabberd_hooks:delete(create_channel, Host, ?MODULE, create_channel, 35).

depends(_Host, _Opts) ->
  [].

mod_options(_) -> [].

check_localpart(_Acc, LServer, _CreatorLUser, _CreatorLServer, SubEls, Lang) ->
  LocalPart = proplists:get_value(channel_localpart, SubEls),
  Name = proplists:get_value(channel_name, SubEls),
  case LocalPart of
    undefined ->
      check_name(LServer, Name, Lang);
    _ ->
      case mod_xabber_entity:is_exist_anywhere(LocalPart,LServer) of
        false ->
          check_name(LServer, Name, Lang);
        true ->
          {stop,{error, xmpp:err_conflict(<<"Entity exist">>,Lang)}}
      end
  end.

check_name(_LServer, undefined, Lang) ->
  {stop,{error, xmpp:err_bad_request(<<"Name cannot be blank">>,Lang)}};
check_name(LServer, Name, Lang) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(name)s
    from channels where name=%(Name)s and %(LServer)H")) of
    {selected, InfoList} when length(InfoList) > 0 ->
      {stop,{error, xmpp:err_conflict(<<"Channel with such name exist">>,Lang)}};
    _Q ->
      ok
  end.

check_unsupported_stanzas(_Acc, _Server, _CreatorLUser, _CreatorLServer, SubEls, Lang)  ->
  case lists:keyfind(xmlel,1,SubEls) of
    false ->
      ok;
    _ ->
      {stop,{error, xmpp:err_bad_request(<<"Unsupported tags">>,Lang)}}
  end.

check_params(_Acc, _Server, _CreatorLUser, _CreatorLServer, SubEls, Lang)  ->
  Name = proplists:get_value(channel_name, SubEls, <<>>),
  Membership = proplists:get_value(channel_membership,SubEls),
  Index = proplists:get_value(channel_index,SubEls),
  IsMembershipValid = validate_membership(Membership),
  IsIndexValid = validate_index(Index),
  Localpart = proplists:get_value(channel_localpart,SubEls,create_jid()),
  LocalpartLength = string:length(Localpart),
  NameLength = string:length(Name),
  case IsMembershipValid of
    true when LocalpartLength > 0 andalso IsIndexValid =/= false andalso NameLength > 0 ->
      ok;
    _ ->
      {stop, {error, make_error_text(IsMembershipValid,IsIndexValid,LocalpartLength,NameLength, Lang)}}
  end.

make_error_text(IsMembershipValid,IsIndexValid,LocalpartLength,NameLength, Lang) ->
  T1 = case IsMembershipValid of
         true ->
           [];
         _ ->
           [translate:translate(Lang, <<"Membership value is invalid">>), <<"\n">>]
       end,
  T2 = case IsIndexValid of
         true ->
           [];
         _ ->
           [translate:translate(Lang, <<"Index value is invalid">>) , <<"\n">>]
       end,
  T3 = case LocalpartLength of
         true ->
           [];
         _ ->
           [translate:translate(Lang, <<"Localpart cannot be blank">>), <<"\n">>]
       end,
  T4 = case NameLength of
         true ->
           [];
         _ ->
           [translate:translate(Lang, <<"Name cannot be blank">>), <<"\n">>]
       end,
  Text = list_to_binary(T1 ++ T2 ++ T3 ++ T4),
  xmpp:err_bad_request(Text, Lang).

validate_membership(Value) ->
  ValidValues = [<<"open">>, <<"member-only">>, undefined],
  lists:member(Value, ValidValues).

validate_index(Value) ->
  ValidValues = [<<"none">>, <<"local">>, <<"global">>, undefined],
  lists:member(Value, ValidValues).

create_jid() ->
  list_to_binary(
    [randoms:get_alphanum_string(2),randoms:get_string(),randoms:get_alphanum_string(3)]).

create_channel(_Acc, LServer,CreatorLUser,CreatorLServer,SubEls,Lang) ->
  Localpart0 = proplists:get_value(channel_localpart,SubEls,create_jid()),
  LocalPart = list_to_binary(string:to_lower(binary_to_list(Localpart0))),
  Name = proplists:get_value(channel_name, SubEls),
  Desc = proplists:get_value(channel_description, SubEls, <<>>),
  Membership = proplists:get_value(channel_membership,SubEls, <<"open">>),
  Index = proplists:get_value(channel_index,SubEls, <<"local">>),
  ContactList = proplists:get_value(channel_contacts,SubEls,[]),
  Contacts = make_string(ContactList),
  DomainList = proplists:get_value(channel_domains,SubEls,[]),
  Domains = make_string(DomainList),
  Channel = jid:to_string(jid:make(LocalPart,LServer)),
  Creator = jid:to_string(jid:make(CreatorLUser,CreatorLServer)),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL_INSERT(
      "channels",
      ["name=%(Name)s",
        "server_host=%(LServer)s",
        "localpart=%(LocalPart)s",
        "jid=%(Channel)s",
        "index=%(Index)s",
        "membership=%(Membership)s",
        "description=%(Desc)s",
        "contacts=%(Contacts)s",
        "domains=%(Domains)s",
        "owner=%(Creator)s"])) of
    {updated,_N} ->
      xabber_channels_sm:activate(LServer,LocalPart),
      mod_channels_users:add_user(LServer,Channel,Creator,<<"both">>),
      Permissions = mod_channel_rights:get_permissions(LServer),
      lists:foreach(fun(Permission) ->
        {Rule} = Permission,
        mod_channel_rights:insert_rule(LServer,Channel,Creator,Rule,0,<<"server">>) end, Permissions),
      NameEl = #channel_name{cdata = Name},
      LocalpartEl = #channel_localpart{cdata = LocalPart},
      MembershipEl = #channel_membership{cdata = Membership},
      DescEl = #channel_description{cdata = Desc},
      IndexEl = #channel_index{cdata = Index},
      ContactsEl = #channel_contacts{contact = ContactList},
      DomainsEl = #channel_domains{domain = DomainList},
      {stop, {ok, #channel_query{sub_els = [NameEl,LocalpartEl,MembershipEl,DescEl,IndexEl,ContactsEl,DomainsEl]}, Channel}};
    _ ->
      {stop,{error,xmpp:err_internal_server_error(<<"Cannot create a channel">>,Lang)}}
  end.

get_channel_info(LServer, Channel) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(name)s,@(index)s,@(membership)s,@(description)s,@(message)d,@(contacts)s,@(domains)s
    from channels where jid=%(Channel)s and %(LServer)H")) of
    {selected, [Info] = InfoList} when length(InfoList) > 0 ->
      {ok,Info};
    _ ->
      err
  end.


get_all(LServer) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(localpart)s from channels where %(LServer)H")) of
    {selected,[{null}]} ->
      [];
    {selected,[]} ->
      [];
    {selected,[{}]} ->
      [];
    {selected, Channels} ->
      Channels
  end.

make_string(List) ->
  SortedList = lists:usort(List),
  list_to_binary(lists:map(
    fun(El)->
      {_T,N} = El,
      [N|[<<",">>]]
    end,
    SortedList)).


make_list(Elements, contacts) ->
  Splited = binary:split(Elements,<<",">>,[global]),
  Empty = [X||X <- Splited, X == <<>>],
  List = Splited -- Empty,
  lists:map(fun(El) -> #channel_contact{cdata = El} end, List);
make_list(Elements, domains) ->
  Splited = binary:split(Elements,<<",">>,[global]),
  Empty = [X||X <- Splited, X == <<>>],
  List = Splited -- Empty,
  lists:map(fun(El) -> #channel_domain{cdata = El} end, List).

get_vcard(LUser,LServer) ->
  Channel = jid:to_string(jid:make(LUser,LServer)),
  case get_channel_info(LServer, Channel) of
    {ok,Info} ->
      {Name,Index,Membership,Description,_Message,_Contacts,_Domains} = Info,
      Members = integer_to_binary(mod_channels_users:get_count(LServer,Channel)),
      [xmpp:encode(#vcard_temp{
        jabberid = Channel,
        nickname = Name,
        desc = Description,
        index = Index,
        membership = Membership,
        members = Members})];
    _ ->
      [xmpp:encode(#vcard_temp{jabberid = Channel})]
  end.