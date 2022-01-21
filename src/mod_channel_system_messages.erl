%%%-------------------------------------------------------------------
%%% File    : mod_channel_system_messages.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Manage system messages in channels
%%% Created : 18 November 2020 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_channel_system_messages).
-author("andrey.gagarin@redsolution.ru").

-behavior(gen_mod).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").

-export([start/2, stop/1, depends/2, mod_options/1]).

-export([channel_created/4]).
start(Host, _Opts) ->
  ejabberd_hooks:add(channel_created, Host, ?MODULE, channel_created, 10).

stop(Host) ->
  ejabberd_hooks:delete(channel_created, Host, ?MODULE, channel_created, 10).

depends(_Host, _Opts) ->  [].

mod_options(_Opts) -> [].

channel_created(LServer,User,Channel,Lang) ->
  case mod_channels:get_channel_info(LServer,Channel) of
    {ok, Info} ->
      ChannelJID = jid:from_string(Channel),
      {Name,Index,Membership,Description,_Message,Contacts,Domains} = Info,
      LocalPart = ChannelJID#jid.luser,
      NameEl = #channel_name{cdata = Name},
      LocalpartEl = #channel_localpart{cdata = LocalPart},
      MembershipEl = #channel_membership{cdata = Membership},
      DescEl = #channel_description{cdata = Description},
      IndexEl = #channel_index{cdata = Index},
      ContactsEl = #channel_contacts{contact = mod_channels:make_list(Contacts, contacts)},
      DomainsEl = #channel_domains{domain = mod_channels:make_list(Domains, domains)},
      XSubEls = [NameEl,LocalpartEl,MembershipEl,DescEl,IndexEl,ContactsEl,DomainsEl],
      Txt = <<"created channel">>,
%%      X = mod_groupchat_users:form_user_card(User,Channel),
      UserID = User,
      MsgTxt = text_for_msg(Lang,Txt,UserID,[],[]),
      Body = [#text{lang = <<>>,data = MsgTxt}],
      XEl = #channel_x{
        xmlns = ?NS_CHANNELS_SYSTEM_MESSAGE,
        sub_els = XSubEls
      },
      By = #xmppreference{type = <<"mutable">>, sub_els = []},
      SubEls = [XEl,By],
      M = form_message(jid:from_string(Channel),Body,SubEls),
      send_to_all(Channel,M);
    _ ->
      ok
  end.

text_for_msg(Lang,Txt,UserName,Additional1,Additional2) ->
  translate:translate(Lang, Txt),
  MsgList = [UserName," ",Txt,Additional1,Additional2],
  list_to_binary(MsgList).

form_message(From,Body,SubEls) ->
  ID = create_id(),
  OriginID = #origin_id{id = ID},
  NewEls = [OriginID | SubEls],
  #message{from = From, to = From, type = chat, id = ID, body = Body, sub_els = NewEls, meta = #{}}.

-spec create_id() -> binary().
create_id() ->
  A = randoms:get_alphanum_string(10),
  B = randoms:get_alphanum_string(4),
  C = randoms:get_alphanum_string(4),
  D = randoms:get_alphanum_string(4),
  E = randoms:get_alphanum_string(10),
  ID = <<A/binary, "-", B/binary, "-", C/binary, "-", D/binary, "-", E/binary>>,
  list_to_binary(string:to_lower(binary_to_list(ID))).

-spec send_to_all(binary(), binary()) -> ok.
send_to_all(Chat,Stanza) ->
  ChatJID = jid:from_string(Chat),
  FromChannel = jid:replace_resource(ChatJID,<<"Channel">>),
  Server = ChatJID#jid.lserver,
  Pkt1 = mod_groups_messages:strip_stanza_id(Stanza,Server),
  {Pkt2, _State2} = ejabberd_hooks:run_fold(
    user_send_packet, Server, {Pkt1, #{jid => ChatJID}}, []),
%%  #message{meta = #{stanza_id := TS}} = Pkt2,
%%  #origin_id{id = OriginID} = xmpp:get_subtag(Pkt2,#origin_id{}),
%%  mod_groupchat_messages:set_displayed(ChatJID,ChatJID,TS,OriginID),
  ListTo = mod_channels_users:user_list_to_send(Server,Chat),
  case ListTo of
    [] ->
      ok;
    _ ->
      lists:foreach(fun(U) ->
        {Member} = U,
        To = jid:from_string(Member),
        ejabberd_router:route(FromChannel,To,Pkt2) end, ListTo)
  end.