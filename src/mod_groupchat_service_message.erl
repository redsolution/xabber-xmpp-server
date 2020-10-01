%%%-------------------------------------------------------------------
%%% File    : mod_groupchat_service_message.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Service messages for groupchats
%%% Created : 16 Oct 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_groupchat_service_message).
-author('andrey.gagarin@redsolution.com').
-behavior(gen_mod).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").

%% API

-export([user_left/2,
  user_join/2,
  users_blocked/2,
  users_kicked/6,
  user_updated/8,
  created_chat/4,
  user_change_own_avatar/3,
  user_change_avatar/4,
  anon/1,
  send_to_all/2,
  chat_created/4,
  user_rights_changed/6, form_message/3
  ]).
-export([groupchat_changed/5, groupchat_avatar_changed/3]).
-export([start/2, stop/1, depends/2, mod_options/1]).

start(Host, _Opts) ->
  ejabberd_hooks:add(groupchat_created, Host, ?MODULE, chat_created, 10),
  ejabberd_hooks:add(groupchat_avatar_changed, Host, ?MODULE, groupchat_avatar_changed, 20),
  ejabberd_hooks:add(groupchat_properties_changed, Host, ?MODULE, groupchat_changed, 20),
  ejabberd_hooks:add(change_user_settings, Host, ?MODULE, user_rights_changed, 40),
  ejabberd_hooks:add(groupchat_update_user_hook, Host, ?MODULE, user_updated, 25),
  ejabberd_hooks:add(groupchat_user_kick, Host, ?MODULE, users_kicked, 35),
  ejabberd_hooks:add(groupchat_block_hook, Host, ?MODULE, users_blocked, 35),
  ejabberd_hooks:add(groupchat_presence_subscribed_hook, Host, ?MODULE, user_join, 55),
  ejabberd_hooks:add(groupchat_user_change_own_avatar, Host, ?MODULE, user_change_own_avatar, 10),
  ejabberd_hooks:add(groupchat_user_change_some_avatar, Host, ?MODULE, user_change_avatar, 10),
  ejabberd_hooks:add(groupchat_presence_unsubscribed_hook, Host, ?MODULE, user_left, 25).

stop(Host) ->
  ejabberd_hooks:delete(groupchat_created, Host, ?MODULE, chat_created, 10),
  ejabberd_hooks:delete(groupchat_avatar_changed, Host, ?MODULE, groupchat_avatar_changed, 20),
  ejabberd_hooks:delete(groupchat_properties_changed, Host, ?MODULE, groupchat_changed, 20),
  ejabberd_hooks:delete(change_user_settings, Host, ?MODULE, user_rights_changed, 40),
  ejabberd_hooks:delete(groupchat_user_change_own_avatar, Host, ?MODULE, user_change_own_avatar, 10),
  ejabberd_hooks:delete(groupchat_user_change_some_avatar, Host, ?MODULE, user_change_avatar, 10),
  ejabberd_hooks:delete(groupchat_update_user_hook, Host, ?MODULE, user_updated, 25),
  ejabberd_hooks:delete(groupchat_user_kick, Host, ?MODULE, users_kicked, 35),
  ejabberd_hooks:delete(groupchat_block_hook, Host, ?MODULE, users_blocked, 35),
  ejabberd_hooks:delete(groupchat_presence_subscribed_hook, Host, ?MODULE, user_join, 55),
  ejabberd_hooks:delete(groupchat_presence_unsubscribed_hook, Host, ?MODULE, user_left, 25).

depends(_Host, _Opts) ->  [].

mod_options(_Opts) -> [].

groupchat_avatar_changed(LServer, Chat, User) ->
  ChatJID = jid:from_string(Chat),
  Version = mod_groupchat_users:current_chat_version(LServer,Chat),
  ByUserCard = mod_groupchat_users:form_user_card(User,Chat),
  UserID = case anon(ByUserCard) of
             public when ByUserCard#xabbergroupchat_user_card.nickname =/= undefined andalso ByUserCard#xabbergroupchat_user_card.nickname =/= <<" ">> andalso ByUserCard#xabbergroupchat_user_card.nickname =/= <<"">> andalso ByUserCard#xabbergroupchat_user_card.nickname =/= <<>> andalso bit_size(ByUserCard#xabbergroupchat_user_card.nickname) > 1 ->
               ByUserCard#xabbergroupchat_user_card.nickname;
             public ->
               jid:to_string(ByUserCard#xabbergroupchat_user_card.jid);
             anonim ->
               ByUserCard#xabbergroupchat_user_card.nickname
           end,
  MsgTxt = <<UserID/binary, " changed group avatar">>,
  Body = [#text{lang = <<>>,data = MsgTxt}],
  X = #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE, version = Version, type = <<"update">>},
  By = #xmppreference{type = <<"mutable">>, sub_els = [ByUserCard]},
  SubEls =  [X,By],
  M = form_message(ChatJID,Body,SubEls),
  send_to_all(Chat,M).

groupchat_changed(_LServer, Chat, _User, [{name_changed,false},{desc_changed,false},{status_changed,false},
  {pinned_changed,false},{properties_changed,false}], _Status) ->
  ?DEBUG("Nothing is changed in chat ~p~n",[Chat]);
groupchat_changed(LServer, Chat, User, ChatProperties, Status) ->
  ChatJID = jid:from_string(Chat),
  Version = mod_groupchat_users:current_chat_version(LServer,Chat),
  IsNameChanged = proplists:get_value(name_changed, ChatProperties),
  IsDescChanged = proplists:get_value(desc_changed, ChatProperties),
  IsStatusChanged =  proplists:get_value(status_changed, ChatProperties),
  IsPinnedChanged = proplists:get_value(pinned_changed, ChatProperties),
  IsOtherChanged = proplists:get_value(properties_changed, ChatProperties),
  Label = mod_groupchat_chats:get_status_label_name(LServer,Chat,Status),
  ByUserCard = mod_groupchat_users:form_user_card(User,Chat),
  UserID = case anon(ByUserCard) of
             public when ByUserCard#xabbergroupchat_user_card.nickname =/= undefined andalso ByUserCard#xabbergroupchat_user_card.nickname =/= <<" ">> andalso ByUserCard#xabbergroupchat_user_card.nickname =/= <<"">> andalso ByUserCard#xabbergroupchat_user_card.nickname =/= <<>> andalso bit_size(ByUserCard#xabbergroupchat_user_card.nickname) > 1 ->
               ByUserCard#xabbergroupchat_user_card.nickname;
             public ->
               jid:to_string(ByUserCard#xabbergroupchat_user_card.jid);
             anonim ->
               ByUserCard#xabbergroupchat_user_card.nickname
           end,
  MsgTxt = case IsNameChanged of
             true when IsOtherChanged =/= true andalso IsDescChanged =/= true
               andalso IsStatusChanged =/= true andalso IsPinnedChanged =/= true ->
               <<UserID/binary, " changed group name">>;
             true when IsOtherChanged == true andalso IsDescChanged =/= true
               andalso IsStatusChanged =/= true andalso IsPinnedChanged =/= true ->
               <<UserID/binary, " changed group name and updated propeties">>;
             true when IsOtherChanged =/= true andalso IsDescChanged == true
               andalso IsStatusChanged =/= true andalso IsPinnedChanged =/= true ->
               <<UserID/binary, " changed group name and description">>;
             true when IsOtherChanged == true andalso IsDescChanged == true
               andalso IsStatusChanged =/= true andalso IsPinnedChanged =/= true ->
               <<UserID/binary, " changed group name, description and updated properties">>;
             _ when IsNameChanged =/= true andalso IsOtherChanged =/= true andalso IsDescChanged == true
               andalso IsStatusChanged =/= true andalso IsPinnedChanged =/= true ->
               <<UserID/binary, " changed group description">>;
             _ when IsNameChanged =/= true andalso IsOtherChanged =/= true andalso IsDescChanged =/= true
               andalso IsStatusChanged =/= true andalso IsPinnedChanged == true ->
               <<UserID/binary, " pinned a message">>;
             _ when IsNameChanged =/= true andalso IsOtherChanged =/= true andalso IsDescChanged =/= true
               andalso IsStatusChanged == true andalso IsPinnedChanged =/= true ->
               <<UserID/binary, " changed group status to ", Label/binary>>;
             _ ->
               <<UserID/binary, " updated group properties">>
           end,
  Body = [#text{lang = <<>>,data = MsgTxt}],
  X = #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE, version = Version, type = <<"update">>},
  By = #xmppreference{type = <<"mutable">>, sub_els = [ByUserCard]},

  {selected,[{Name,Anonymous,_Search,_Model,_Desc,Message,_ContactList,_DomainList,Status}]} =
    mod_groupchat_chats:get_information_of_chat(Chat,LServer),
  Group_X = #xabbergroupchat_x{
    xmlns = ?NS_GROUPCHAT,
    members = integer_to_binary(mod_groupchat_chats:count_users(LServer,Chat)),
    sub_els =
    [
      #xabbergroupchat_name{cdata = Name},
      #xabbergroupchat_privacy{cdata = Anonymous},
      #xabbergroupchat_pinned_message{cdata = integer_to_binary(Message)}
    ]},
  SubEls =  [X,By,Group_X],
  M = form_message(ChatJID,Body,SubEls),
  send_to_all(Chat,M).


user_change_avatar(User, Server, Chat, OtherUser) ->
  ChatJID = jid:replace_resource(jid:from_string(Chat),<<"Groupchat">>),
  ByUserCard = mod_groupchat_users:form_user_card(User,Chat),
  UpdatedUser = mod_groupchat_users:form_user_card(OtherUser,Chat),
  UpdatedUserID = case anon(UpdatedUser) of
                    public when UpdatedUser#xabbergroupchat_user_card.nickname =/= undefined andalso UpdatedUser#xabbergroupchat_user_card.nickname =/= <<" ">> andalso UpdatedUser#xabbergroupchat_user_card.nickname =/= <<"">> andalso UpdatedUser#xabbergroupchat_user_card.nickname =/= <<>> andalso bit_size(UpdatedUser#xabbergroupchat_user_card.nickname) > 1 ->
                      UpdatedUser#xabbergroupchat_user_card.nickname;
                    public ->
                      jid:to_string(UpdatedUser#xabbergroupchat_user_card.jid);
                    anonim ->
                      UpdatedUser#xabbergroupchat_user_card.nickname
                  end,
  UserID = case anon(ByUserCard) of
             public when ByUserCard#xabbergroupchat_user_card.nickname =/= undefined andalso ByUserCard#xabbergroupchat_user_card.nickname =/= <<" ">> andalso ByUserCard#xabbergroupchat_user_card.nickname =/= <<"">> andalso ByUserCard#xabbergroupchat_user_card.nickname =/= <<>> andalso bit_size(ByUserCard#xabbergroupchat_user_card.nickname) > 1 ->
               ByUserCard#xabbergroupchat_user_card.nickname;
             public ->
               jid:to_string(ByUserCard#xabbergroupchat_user_card.jid);
             anonim ->
               ByUserCard#xabbergroupchat_user_card.nickname
           end,
  Version = mod_groupchat_users:current_chat_version(Server,Chat),
  MsgTxt = <<UserID/binary, " updated avatar of ", UpdatedUserID/binary>>,
  Body = [#text{lang = <<>>,data = MsgTxt}],
  X = #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE, version = Version, sub_els = [UpdatedUser], type = <<"update">>},
  By = #xmppreference{type = <<"mutable">>, sub_els = [ByUserCard]},
  SubEls =  [X,By],
  M = form_message(ChatJID,Body,SubEls),
  send_to_all(Chat,M),
  {stop,ok}.

user_change_own_avatar(User, Server, Chat) ->
  ChatJID = jid:replace_resource(jid:from_string(Chat),<<"Groupchat">>),
  ByUserCard = mod_groupchat_users:form_user_card(User,Chat),
  UserID = case anon(ByUserCard) of
             public when ByUserCard#xabbergroupchat_user_card.nickname =/= undefined andalso ByUserCard#xabbergroupchat_user_card.nickname =/= <<" ">> andalso ByUserCard#xabbergroupchat_user_card.nickname =/= <<"">> andalso ByUserCard#xabbergroupchat_user_card.nickname =/= <<>> andalso bit_size(ByUserCard#xabbergroupchat_user_card.nickname) > 1 ->
               ByUserCard#xabbergroupchat_user_card.nickname;
             public ->
               jid:to_string(ByUserCard#xabbergroupchat_user_card.jid);
             anonim ->
               ByUserCard#xabbergroupchat_user_card.nickname
           end,
  Version = mod_groupchat_users:current_chat_version(Server,Chat),
  MsgTxt = <<UserID/binary, " updated avatar">>,
  Body = [#text{lang = <<>>,data = MsgTxt}],
  X = #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE, version = Version, sub_els = [ByUserCard], type = <<"update">>},
  By = #xmppreference{type = <<"mutable">>, sub_els = [ByUserCard]},
  SubEls = [X,By],
  M = form_message(ChatJID,Body,SubEls),
  send_to_all(Chat,M),
  {stop,ok}.

created_chat(Created,User,ChatJID,Lang) ->
  Txt = <<"created chat">>,
  Chat = jid:to_string(jid:remove_resource(ChatJID)),
  X = mod_groupchat_users:form_user_card(User,Chat),
  UserID = case anon(X) of
             public when X#xabbergroupchat_user_card.nickname =/= undefined andalso X#xabbergroupchat_user_card.nickname =/= <<" ">> andalso X#xabbergroupchat_user_card.nickname =/= <<"">> andalso X#xabbergroupchat_user_card.nickname =/= <<>> andalso bit_size(X#xabbergroupchat_user_card.nickname) > 1 ->
               X#xabbergroupchat_user_card.nickname;
             public ->
               jid:to_string(X#xabbergroupchat_user_card.jid);
             anonim ->
               X#xabbergroupchat_user_card.nickname
           end,
  MsgTxt = text_for_msg(Lang,Txt,UserID,[],[]),
  Body = [#text{lang = <<>>,data = MsgTxt}],
  #xabbergroupchat_create{
    name = Name,
    description = Description,
    searchable = Search,
    anonymous = Anon,
    model = Model,
    domains = Domains,
    contacts = Contacts
  } = Created,
  Privacy = #xabbergroupchat_privacy{cdata = Anon},
  Membership = #xabbergroupchat_membership{cdata = Model},
  Desc = #xabbergroupchat_description{cdata = Description},
  Index = #xabbergroupchat_index{cdata = Search},
  NameEl = #xabbergroupchat_name{cdata = Name},
  XEl = #xabbergroupchat_x{
    xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE,
  sub_els = [NameEl,Privacy,Membership,Desc,Index],
    domains = Domains,
    contacts = Contacts
  },
  By = #xmppreference{type = <<"mutable">>, sub_els = [X]},
  SubEls = [XEl,By],
  M = form_message(ChatJID,Body,SubEls),
  send_to_all(Chat,M).

chat_created(LServer,User,Chat,Lang) ->
  Txt = <<"created chat">>,
  X = mod_groupchat_users:form_user_card(User,Chat),
  UserID = case anon(X) of
             public when X#xabbergroupchat_user_card.nickname =/= undefined andalso X#xabbergroupchat_user_card.nickname =/= <<" ">> andalso X#xabbergroupchat_user_card.nickname =/= <<"">> andalso X#xabbergroupchat_user_card.nickname =/= <<>> andalso bit_size(X#xabbergroupchat_user_card.nickname) > 1 ->
               X#xabbergroupchat_user_card.nickname;
             public ->
               jid:to_string(X#xabbergroupchat_user_card.jid);
             anonim ->
               X#xabbergroupchat_user_card.nickname
           end,
  MsgTxt = text_for_msg(Lang,Txt,UserID,[],[]),
  Body = [#text{lang = <<>>,data = MsgTxt}],
  {selected,[{Name,Anonymous,Search,Model,Desc,_Message,_ContactList,_DomainList,_ParentChat}]} =
    mod_groupchat_chats:get_detailed_information_of_chat(Chat,LServer),
  Privacy = #xabbergroupchat_privacy{cdata = Anonymous},
  Membership = #xabbergroupchat_membership{cdata = Model},
  Description = #xabbergroupchat_description{cdata = Desc},
  Index = #xabbergroupchat_index{cdata = Search},
  NameEl = #xabbergroupchat_name{cdata = Name},
  XEl = #xabbergroupchat_x{
    xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE,
    sub_els = [NameEl,Privacy,Membership,Description,Index]
  },
  By = #xmppreference{type = <<"mutable">>, sub_els = [X]},
  SubEls = [XEl,By],
  M = form_message(jid:from_string(Chat),Body,SubEls),
  send_to_all(Chat,M).

users_blocked(Acc, #iq{lang = Lang,to = To, from = From}) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  Admin = jid:to_string(jid:remove_resource(From)),
  X = mod_groupchat_users:form_user_card(Admin,Chat),
  UserID = case anon(X) of
             public when X#xabbergroupchat_user_card.nickname =/= undefined andalso X#xabbergroupchat_user_card.nickname =/= <<" ">> andalso X#xabbergroupchat_user_card.nickname =/= <<"">> andalso X#xabbergroupchat_user_card.nickname =/= <<>> andalso bit_size(X#xabbergroupchat_user_card.nickname) > 1 ->
               X#xabbergroupchat_user_card.nickname;
             public ->
               jid:to_string(X#xabbergroupchat_user_card.jid);
             anonim ->
               X#xabbergroupchat_user_card.nickname
           end,
  KickedUsers = lists:map(fun(Card) ->
    case anon(Card) of
      public when Card#xabbergroupchat_user_card.nickname =/= undefined andalso Card#xabbergroupchat_user_card.nickname =/= <<" ">> andalso Card#xabbergroupchat_user_card.nickname =/= <<"">> andalso Card#xabbergroupchat_user_card.nickname =/= <<>> andalso bit_size(Card#xabbergroupchat_user_card.nickname) > 1 ->
        [Card#xabbergroupchat_user_card.nickname, <<" ">>];
      public ->
        [jid:to_string(Card#xabbergroupchat_user_card.jid),<<" ">>];
      anonim ->
        [Card#xabbergroupchat_user_card.nickname, <<" ">>]
    end end, Acc
  ),
  case length(KickedUsers) of
    0 ->
      Txt = <<"blocked some users or domains">>,
      AddTxt = [];
    _ ->
      Txt = <<"blocked ">>,
      AddTxt = <<"from chat">>
  end,
  MsgTxt = text_for_msg(Lang,Txt,UserID,KickedUsers,AddTxt),
  Body = [#text{lang = <<>>,data = MsgTxt}],
  XEl = #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE, sub_els = Acc, type = <<"block">>},
  By = #xmppreference{type = <<"mutable">>, sub_els = [X]},
  SubEls = [XEl,By],
  M = form_message(To,Body,SubEls),
  send_to_all(Chat,M),
  send_presences(To#jid.lserver,Chat),
  {stop,ok}.

users_kicked(Acc,LServer,Chat,Admin,_Kick,Lang) ->
  X = mod_groupchat_users:form_user_card(Admin,Chat),
  UserID = case anon(X) of
             public when X#xabbergroupchat_user_card.nickname =/= undefined andalso X#xabbergroupchat_user_card.nickname =/= <<" ">> andalso X#xabbergroupchat_user_card.nickname =/= <<"">> andalso X#xabbergroupchat_user_card.nickname =/= <<>> andalso bit_size(X#xabbergroupchat_user_card.nickname) > 1 ->
               X#xabbergroupchat_user_card.nickname;
             public ->
               jid:to_string(X#xabbergroupchat_user_card.jid);
             anonim ->
               X#xabbergroupchat_user_card.nickname
           end,
  KickedUsers = lists:map(fun(Card) ->
    case anon(Card) of
      public when Card#xabbergroupchat_user_card.nickname =/= undefined andalso Card#xabbergroupchat_user_card.nickname =/= <<" ">> andalso Card#xabbergroupchat_user_card.nickname =/= <<"">> andalso Card#xabbergroupchat_user_card.nickname =/= <<>> andalso bit_size(Card#xabbergroupchat_user_card.nickname) > 1 ->
        [Card#xabbergroupchat_user_card.nickname, <<" ">>];
      public ->
        [jid:to_string(Card#xabbergroupchat_user_card.jid),<<" ">>];
      anonim ->
        [Card#xabbergroupchat_user_card.nickname, <<" ">>]
    end end, Acc
  ),
  case length(KickedUsers) of
    0 ->
      Txt = <<"kicked some users">>,
      AddTxt = [];
    _ ->
      Txt = <<"kicked ">>,
      AddTxt = <<"from chat">>
  end,
  MsgTxt = text_for_msg(Lang,Txt,UserID,KickedUsers,AddTxt),
  Body = [#text{lang = <<>>,data = MsgTxt}],
  Version = mod_groupchat_users:current_chat_version(LServer,Chat),
  XEl = #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE, sub_els = Acc, type = <<"kick">>, version = Version},
  By = #xmppreference{type = <<"mutable">>, sub_els = [X]},
  SubEls = [XEl,By],
  ChatJID = jid:from_string(Chat),
  M = form_message(ChatJID,Body,SubEls),
  send_to_all(Chat,M),
  send_presences(LServer,Chat),
  {stop,ok}.

user_left(_Acc,{Server,_User,Chat,X,Lang})->
  Txt = <<"left chat">>,
  ChatJID = jid:from_string(Chat),
  UserID = case anon(X) of
             public when X#xabbergroupchat_user_card.nickname =/= undefined andalso X#xabbergroupchat_user_card.nickname =/= <<" ">> andalso X#xabbergroupchat_user_card.nickname =/= <<"">> andalso X#xabbergroupchat_user_card.nickname =/= <<>> andalso bit_size(X#xabbergroupchat_user_card.nickname) > 1 ->
               X#xabbergroupchat_user_card.nickname;
             public ->
               jid:to_string(X#xabbergroupchat_user_card.jid);
             anonim ->
               X#xabbergroupchat_user_card.nickname
           end,
  MsgTxt = text_for_msg(Lang,Txt,UserID,[],[]),
  Body = [#text{lang = <<>>,data = MsgTxt}],
  Version = mod_groupchat_users:current_chat_version(Server,Chat),
  XEl = #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE, version = Version, type = <<"left">>},
  By = #xmppreference{type = <<"mutable">>, sub_els = [X]},
  SubEls = [XEl,By],
  M = form_message(ChatJID,Body,SubEls),
  send_to_all(Chat,M),
  send_presences(Server,Chat),
  ok.

user_join(_Acc,{Server,To,Chat,Lang}) ->
  User = jid:to_string(jid:remove_resource(To)),
  ByUserCard = mod_groupchat_users:form_user_card(User,Chat),
  Txt = <<"joined chat">>,
  ChatJID = jid:from_string(Chat),
  UserID = case anon(ByUserCard) of
             public when ByUserCard#xabbergroupchat_user_card.nickname =/= undefined andalso ByUserCard#xabbergroupchat_user_card.nickname =/= <<" ">> andalso ByUserCard#xabbergroupchat_user_card.nickname =/= <<"">> andalso ByUserCard#xabbergroupchat_user_card.nickname =/= <<>> andalso bit_size(ByUserCard#xabbergroupchat_user_card.nickname) > 1 ->
               ByUserCard#xabbergroupchat_user_card.nickname;
             public ->
               jid:to_string(ByUserCard#xabbergroupchat_user_card.jid);
             anonim ->
               ByUserCard#xabbergroupchat_user_card.nickname
           end,
  MsgTxt = text_for_msg(Lang,Txt,UserID,[],[]),
  Body = [#text{lang = <<>>,data = MsgTxt}],
  Version = mod_groupchat_users:current_chat_version(Server,Chat),
  X = #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE, version = Version, type = <<"join">>},
  By = #xmppreference{type = <<"mutable">>, sub_els = [ByUserCard]},
  SubEls = [X,By],
  M = form_message(ChatJID,Body,SubEls),
  send_to_all(Chat,M),
  send_presences(Server,Chat),
  {stop,ok}.

user_updated({User,OldCard}, LServer,Chat, Admin,_ID,Nick,_Badge,Lang) ->
  ByUserCard = mod_groupchat_users:form_user_card(Admin,Chat),
  UpdatedUser = mod_groupchat_users:form_user_card(User,Chat),
  OldName = case anon(UpdatedUser) of
              public when OldCard#xabbergroupchat_user_card.nickname =/= undefined andalso OldCard#xabbergroupchat_user_card.nickname =/= <<" ">> andalso OldCard#xabbergroupchat_user_card.nickname =/= <<"">> andalso OldCard#xabbergroupchat_user_card.nickname =/= <<>> andalso bit_size(OldCard#xabbergroupchat_user_card.nickname) > 1 ->
                OldCard#xabbergroupchat_user_card.nickname;
              public ->
                jid:to_string(OldCard#xabbergroupchat_user_card.jid);
              anonim ->
                OldCard#xabbergroupchat_user_card.nickname
            end,
  Acc = case anon(UpdatedUser) of
          public when UpdatedUser#xabbergroupchat_user_card.nickname =/= undefined andalso UpdatedUser#xabbergroupchat_user_card.nickname =/= <<" ">> andalso UpdatedUser#xabbergroupchat_user_card.nickname =/= <<"">> andalso UpdatedUser#xabbergroupchat_user_card.nickname =/= <<>> andalso bit_size(UpdatedUser#xabbergroupchat_user_card.nickname) > 1 ->
          UpdatedUser#xabbergroupchat_user_card.nickname;
          public ->
            jid:to_string(UpdatedUser#xabbergroupchat_user_card.jid);
          anonim ->
            UpdatedUser#xabbergroupchat_user_card.nickname
        end,
  UserID = case anon(ByUserCard) of
             public when ByUserCard#xabbergroupchat_user_card.nickname =/= undefined andalso ByUserCard#xabbergroupchat_user_card.nickname =/= <<" ">> andalso ByUserCard#xabbergroupchat_user_card.nickname =/= <<"">> andalso ByUserCard#xabbergroupchat_user_card.nickname =/= <<>> andalso bit_size(ByUserCard#xabbergroupchat_user_card.nickname) > 1 ->
               ByUserCard#xabbergroupchat_user_card.nickname;
             public ->
               jid:to_string(ByUserCard#xabbergroupchat_user_card.jid);
             anonim ->
               ByUserCard#xabbergroupchat_user_card.nickname
           end,
  OldNick = OldCard#xabbergroupchat_user_card.nickname,
  NewNick = UpdatedUser#xabbergroupchat_user_card.nickname,
  OldBadge = OldCard#xabbergroupchat_user_card.badge,
  NewBadge = UpdatedUser#xabbergroupchat_user_card.badge,
  case Admin of
    User when OldNick =/= NewNick andalso OldBadge =/= NewBadge ->
      Txt = <<" changed his/her badge and is now known as ">>,
      MsgTxt = text_for_msg(Lang,Txt,OldName,UserID,[]),
      maybe_send(LServer,Chat,UpdatedUser,ByUserCard,MsgTxt);
    User when OldNick =/= NewNick andalso OldBadge == NewBadge ->
      Txt = <<" is now known as ">>,
      MsgTxt = text_for_msg(Lang,Txt,OldName,UserID,[]),
      maybe_send(LServer,Chat,UpdatedUser,ByUserCard,MsgTxt);
    User when OldNick == NewNick andalso OldBadge =/= NewBadge ->
      Txt = <<" changed his/her badge">>,
      MsgTxt = text_for_msg(Lang,Txt,UserID,[],[]),
      maybe_send(LServer,Chat,UpdatedUser,ByUserCard,MsgTxt);
    _ when OldNick =/= NewNick andalso OldBadge =/= NewBadge ->
      Txt = <<" nickname was changed to ", Nick/binary," and badge was changed by ">>,
      MsgTxt = text_for_msg(Lang,Txt,OldName,UserID,[]),
      maybe_send(LServer,Chat,UpdatedUser,ByUserCard,MsgTxt);
    _ when OldNick =/= NewNick andalso OldBadge == NewBadge ->
      Txt = <<" nickname was changed to ", Nick/binary," by ">>,
      MsgTxt = text_for_msg(Lang,Txt,OldName,UserID,[]),
      maybe_send(LServer,Chat,UpdatedUser,ByUserCard,MsgTxt);
    _ when OldNick == NewNick andalso OldBadge =/= NewBadge ->
      Txt = <<" badge was changed by ">>,
      MsgTxt = text_for_msg(Lang,Txt,Acc,UserID,[]),
      maybe_send(LServer,Chat,UpdatedUser,ByUserCard,MsgTxt);
    _ ->
      ok
  end,
  {stop,ok}.

maybe_send(LServer,Chat,UpdatedUser,ByUserCard,MsgTxt) ->
  ChatJID = jid:from_string(Chat),
  Body = [#text{lang = <<>>,data = MsgTxt}],
  Version = mod_groupchat_users:current_chat_version(LServer,Chat),
  X = #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE, version = Version, sub_els = [UpdatedUser], type = <<"update">>},
  By = #xmppreference{type = <<"mutable">>, sub_els = [ByUserCard]},
  SubEls = [X,By],
  M = form_message(ChatJID,Body,SubEls),
  send_to_all(Chat,M).

user_rights_changed({OldCard,RequestUser,Permission,Restriction,Form}, LServer, Admin, Chat, _ID, Lang) ->
  ByUserCard = mod_groupchat_users:form_user_card(Admin,Chat),
  UpdatedUser = mod_groupchat_users:form_user_card(RequestUser,Chat),
  ChatJID = jid:from_string(Chat),
  Acc = case anon(UpdatedUser) of
          public when UpdatedUser#xabbergroupchat_user_card.nickname =/= undefined andalso UpdatedUser#xabbergroupchat_user_card.nickname =/= <<" ">> andalso UpdatedUser#xabbergroupchat_user_card.nickname =/= <<"">> andalso UpdatedUser#xabbergroupchat_user_card.nickname =/= <<>> andalso bit_size(UpdatedUser#xabbergroupchat_user_card.nickname) > 1 ->
            UpdatedUser#xabbergroupchat_user_card.nickname;
          public ->
            jid:to_string(UpdatedUser#xabbergroupchat_user_card.jid);
          anonim ->
            UpdatedUser#xabbergroupchat_user_card.nickname
        end,
  UserID = case anon(ByUserCard) of
             public when ByUserCard#xabbergroupchat_user_card.nickname =/= undefined andalso ByUserCard#xabbergroupchat_user_card.nickname =/= <<" ">> andalso ByUserCard#xabbergroupchat_user_card.nickname =/= <<"">> andalso ByUserCard#xabbergroupchat_user_card.nickname =/= <<>> andalso bit_size(ByUserCard#xabbergroupchat_user_card.nickname) > 1 ->
               ByUserCard#xabbergroupchat_user_card.nickname;
             public ->
               jid:to_string(ByUserCard#xabbergroupchat_user_card.jid);
             anonim ->
               ByUserCard#xabbergroupchat_user_card.nickname
           end,
  MsgTxt =
    case Admin of
      _  when length(Permission) > 0 andalso length(Restriction) > 0 ->
        Txt = <<" rights was updated by ">>,
        text_for_msg(Lang,Txt,Acc,UserID,[]);
      _ when length(Permission) > 0 andalso length(Restriction) == 0 ->
        Txt = permission_text(Permission,OldCard,UpdatedUser),
        text_for_msg(Lang,Txt,Acc,UserID,[]);
      _ when length(Permission) == 0 andalso length(Restriction) > 0 ->
        Txt = new_restriction_text(Restriction),
        text_for_msg(Lang,Txt,Acc,UserID,[]);
      _ ->
        Txt = <<" info was updated by ">>,
        text_for_msg(Lang,Txt,Acc,UserID,[])
    end,
  Body = [#text{lang = <<>>,data = MsgTxt}],
  Version = mod_groupchat_users:current_chat_version(LServer,Chat),
  X = #xabbergroupchat_x{xmlns = ?NS_GROUPCHAT_SYSTEM_MESSAGE, version = Version, sub_els = [UpdatedUser], type = <<"update">>},
  By = #xmppreference{type = <<"mutable">>, sub_els = [ByUserCard]},
  SubEls = [X,By],
  M = form_message(ChatJID,Body,SubEls),
  send_to_all(Chat,M),
  {stop,{ok,Form}}.

% Internal function

permission_text(Perms,OldUserCard,UpdateUserCard) ->
  OldRole = OldUserCard#xabbergroupchat_user_card.role,
  NewRole = UpdateUserCard#xabbergroupchat_user_card.role,
  case NewRole of
    OldRole when length(Perms) > 1 ->
      <<" permissions were changed by ">>;
    OldRole ->
      <<" permission was changed by ">>;
    <<"member">> ->
      <<" was demoted to member by ">>;
    <<"admin">> ->
      <<" was promoted to admin by ">>;
    <<"owner">> ->
      <<" was promoted to owner by ">>;
    _  when length(Perms) > 1 ->
      <<" permissions were changed by ">>;
    _ ->
      <<" permission was changed by ">>
  end.

new_restriction_text(Restrictions) ->
  ResExpire = lists:map(fun(R) ->
   {_Name,_Type,Expire} = R,
    Expire end, Restrictions
  ),
  NowExpireList = lists:filter(fun(El) ->
    El == [] end, ResExpire
  ),
  DiffList = ResExpire--NowExpireList,
  case length(DiffList) of
    0 when length(NowExpireList) > 1 ->
      <<" restrictions were canceled by ">>;
    0 ->
      <<" restriction was canceled by ">>;
    _ when NowExpireList == [] ->
      <<" was restricted by ">>;
    _ when length(Restrictions) > 1 ->
      <<" restrictions were changed by ">>;
    _ ->
      <<" restriction was changed by ">>
  end.


send_presences(Server,Chat) ->
  To = jid:from_string(Chat),
  Users = mod_groupchat_users:user_list_to_send(Server,Chat),
  FromChat = jid:replace_resource(To,<<"Groupchat">>),
  mod_groupchat_messages:send_message(mod_groupchat_presence:form_presence(Chat),Users,FromChat).

-spec send_to_all(binary(), binary()) -> ok.
send_to_all(Chat,Stanza) ->
  ChatJID = jid:from_string(Chat),
  FromChat = jid:replace_resource(ChatJID,<<"Groupchat">>),
  Server = ChatJID#jid.lserver,
  Pkt1 = mod_groupchat_messages:strip_stanza_id(Stanza,Server),
  {Pkt2, _State2} = ejabberd_hooks:run_fold(
    user_send_packet, Server, {Pkt1, #{jid => ChatJID}}, []),
  #message{meta = #{stanza_id := TS}} = Pkt2,
  #origin_id{id = OriginID} = xmpp:get_subtag(Pkt2,#origin_id{}),
  mod_groupchat_messages:set_displayed(ChatJID,ChatJID,TS,OriginID),
  ListAll = mod_groupchat_users:user_list_to_send(Server,Chat),
  {selected, NoReaders} = mod_groupchat_users:user_no_read(Server,Chat),
  ListTo = ListAll -- NoReaders,
  case ListTo of
    [] ->
      ok;
    _ ->
      lists:foreach(fun(U) ->
        {Member} = U,
        To = jid:from_string(Member),
        ejabberd_router:route(FromChat,To,Pkt2) end, ListTo)
  end.

anon(ByUser) ->
  case ByUser#xabbergroupchat_user_card.jid of
    undefined ->
      anonim;
    _ ->
      public
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