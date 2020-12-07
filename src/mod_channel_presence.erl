%%%-------------------------------------------------------------------
%%% @author Andrey Gagarin andrey.gagarin@redsolution.ru
%%% @copyright (C) 2020, Redsolution Inc.
%%% @doc
%%%
%%% @end
%%% Created : 18. нояб. 2020 15:30
%%%-------------------------------------------------------------------
-module(mod_channel_presence).
-author("andrey.gagarin@redsolution.ru").
-behavior(gen_mod).
-behavior(gen_server).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").

-export([start/2, stop/1, depends/2, mod_options/1]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-export([process_presence/1]).

%% channel_created hook
-export([send_subscription/4]).
%% records
-record(state, {host = <<"">> :: binary()}).

start(Host, Opts) ->
  gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
  gen_mod:stop_child(?MODULE, Host).

depends(_Host, _Opts) ->  [].

mod_options(_Host) -> [].

init([Host, _Opts]) ->
  register_hooks(Host),
  {ok, #state{host = Host}}.

terminate(_Reason, State) ->
  Host = State#state.host,
  unregister_hooks(Host).

register_hooks(Host) ->
  ejabberd_hooks:add(channel_created, Host, ?MODULE, send_subscription, 15).


unregister_hooks(Host) ->
  ejabberd_hooks:delete(channel_created, Host, ?MODULE, send_subscription, 15).

handle_call(_Request, _From, _State) ->
  erlang:error(not_implemented).

handle_cast(#presence{to = To} = Presence, State) ->
  DecodedPresence = xmpp:decode_els(Presence),
  answer_presence(DecodedPresence),
  {noreply, State};
handle_cast(_Request, State) ->
  {noreply, State}.

process_presence(#presence{to=To} = Packet) ->
  Server = To#jid.lserver,
  Proc = gen_mod:get_module_proc(Server, ?MODULE),
  gen_server:cast(Proc, Packet),
  Packet.

send_subscription(LServer,User,Channel,_Lang) ->
  UserJID = jid:from_string(User),
  Presence = form_presence_with_info(LServer, Channel, UserJID, subscribe),
  ejabberd_router:route(Presence).

answer_presence(#presence{to = To, from = From, type = available, sub_els = SubEls}) ->
  Channel = jid:to_string(jid:remove_resource(To)),
  User = jid:to_string(jid:remove_resource(From)),
  LServer = To#jid.lserver,
  Key = lists:keyfind(vcard_xupdate,1,SubEls),
  NewHash = search_for_hash(Key),
  OldHash = mod_groupchat_sql:get_hash(LServer,User),
  case NewHash of
    OldHash ->
      ok;
    <<>> ->
      delete_photo_if_exist;
    undefined ->
      ok;
    _ ->
      mod_groupchat_sql:update_hash(LServer,User,NewHash),
      mod_groupchat_sql:set_update_status(LServer,User,<<"true">>)
  end,
  Presence = form_presence_with_info(LServer, Channel, From, available),
  ejabberd_router:route(Presence);
answer_presence(#presence{to=To, from = From, type = subscribe, sub_els = Sub} = Presence) ->
  LServer = To#jid.lserver,
  User = jid:to_string(jid:remove_resource(From)),
  Channel = jid:to_string(jid:remove_resource(To)),
  Result = ejabberd_hooks:run_fold(channel_subscribe_hook, LServer, [], [LServer, Channel, User]),
  FromChannel = jid:replace_resource(To,<<"Channel">>),
  case Result of
    ok ->
      SubscribePresence = form_presence_with_info(LServer, Channel, From, subscribe),
      SubscribedPresence = form_presence(FromChannel,From,subscribed),
      ejabberd_router:route(SubscribedPresence),
      ejabberd_router:route(SubscribePresence),
      ejabberd_router:route(FromChannel,From,mod_groupchat_vcard:get_pubsub_meta());
    not_ok ->
      Presence = form_presence(FromChannel,From,unsubscribed),
      ejabberd_router:route(Presence);
    _ ->
      ok
  end;
answer_presence(#presence{to=To, from = From, lang = Lang, type = subscribed}) ->
  LServer = To#jid.lserver,
  User = jid:to_string(jid:remove_resource(From)),
  Channel = jid:to_string(jid:remove_resource(To)),
  FromChannel = jid:replace_resource(To,<<"Channel">>),
  Result = ejabberd_hooks:run_fold(channel_subscribed_hook, LServer, [], [LServer, Channel, User, Lang]),
  case Result of
    ok ->
      SubscribedPresence = form_presence_with_info(LServer, Channel, From, subscribed),
      ejabberd_router:route(SubscribedPresence),
      ejabberd_router:route(FromChannel,From,mod_groupchat_vcard:get_pubsub_meta());
    not_ok ->
      ejabberd_router:route(ejabberd_router:route(form_presence(FromChannel, From, unsubscribed)));
    _ ->
      ok
  end;
answer_presence(#presence{lang = Lang,to = ChatJID, from = UserJID, type = unsubscribe}) ->
  Server = ChatJID#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(ChatJID)),
  User = jid:to_string(jid:remove_resource(UserJID)),
  UserCard = mod_groupchat_users:form_user_card(User,Chat),
  ChannelRes = jid:replace_resource(ChatJID,<<"Channel">>),
  Result = ejabberd_hooks:run_fold(groupchat_presence_unsubscribed_hook, Server, [], [{Server,User,Chat,UserCard,Lang}]),
  case Result of
    ok ->
      ejabberd_router:route(form_presence(ChannelRes, UserJID, unsubscribe)),
      ejabberd_router:route(form_presence(ChannelRes, UserJID, unavailable));
    alone ->
      alone;
    _ ->
      error
  end;
answer_presence(#presence{lang = Lang,to = ChatJID, from = UserJID, type = unsubscribed}) ->
  Server = ChatJID#jid.lserver,
  Chat = jid:to_string(jid:remove_resource(ChatJID)),
  User = jid:to_string(jid:remove_resource(UserJID)),
  Exist = mod_groupchat_inspector_sql:check_user(User,Server,Chat),
  case Exist of
    exist ->
      UserCard = mod_groupchat_users:form_user_card(User,Chat),
      ChatJIDRes = jid:replace_resource(ChatJID,<<"Channel">>),
      Result = ejabberd_hooks:run_fold(groupchat_presence_unsubscribed_hook, Server, [], [{Server,User,Chat,UserCard,Lang}]),
      case Result of
        ok ->
          mod_groupchat_present_mnesia:delete_all_user_sessions(User,Chat),
          ejabberd_router:route(ChatJIDRes,UserJID,#presence{type = unsubscribe, id = randoms:get_string()}),
          ejabberd_router:route(ChatJIDRes,UserJID,#presence{type = unavailable, id = randoms:get_string()});
        alone ->
          alone;
        _ ->
          error
      end;
    _ ->
      ok
  end;
answer_presence(Presence) ->
  ?DEBUG("Drop presence ~p",[Presence]).

search_for_hash(Hash) ->
  case Hash of
    false ->
      <<>>;
    _ ->
      Hash#vcard_xupdate.hash
  end.

form_presence_with_info(LServer, Channel, UserJID, Type) ->
  ChannelJID = jid:replace_resource(jid:from_string(Channel),<<"Channel">>),
  SubEls = case mod_channels:get_channel_info(LServer,Channel) of
             {ok, Info} ->
               {Name,Index,Membership,Description,_Message,Contacts,Domains} = Info,
               LocalPart = ChannelJID#jid.luser,
               NameEl = #channel_name{cdata = Name},
               LocalpartEl = #channel_localpart{cdata = LocalPart},
               MembershipEl = #channel_membership{cdata = Membership},
               DescEl = #channel_description{cdata = Description},
               IndexEl = #channel_index{cdata = Index},
               ContactsEl = #channel_contacts{contact = mod_channels:make_list(Contacts, contacts)},
               DomainsEl = #channel_domains{domain = mod_channels:make_list(Domains, domains)},
               Els  = [NameEl,LocalpartEl,MembershipEl,DescEl,IndexEl,ContactsEl,DomainsEl],
               [#channel_x{xmlns = ?NS_CHANNELS,sub_els = Els}];
             _ ->
               []
           end,
  #presence{type = Type, from = ChannelJID, to = UserJID, sub_els = SubEls, id = randoms:get_string()}.

-spec form_presence(jid(), jid(), atom()) -> #presence{}.
form_presence(ChannelJID,UserJID,Type) ->
  #presence{from = ChannelJID, to = UserJID, type = Type, id = randoms:get_string()}.