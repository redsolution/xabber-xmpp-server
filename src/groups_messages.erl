%%%-------------------------------------------------------------------
%%% File    : groups_messages.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : Message processing.
%%% Created : 22 Jan 2026 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
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

-module(groups_messages).
-author('ilya.kalashnikov@redsolution.com').
-behavior(gen_mod).
-behaviour(gen_server).

-include("logger.hrl").
-include("xmpp.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

%% gen_mod, gen_server
-export([start/2, stop/1, depends/2, mod_options/1]).
-export([init/1, handle_call/3, handle_cast/2,
  handle_info/2, terminate/2, code_change/3]).


%% Sub process
-export([process_messages/0]).

%% API
-export([
  modify/1,
  denied_sender_is_banned/1,
  clear_denied_sender_on_join/2,
  delete_all_sessions/1,
  get_present/1,
  select_sessions/2,
  delete_all_user_sessions/2,
  change_present_state/3]).

-define(DENIED_SENDERS_TABLE, groups_denied_senders).

-type denied_message_reason() ::
  nested_forwarded | inactive | restricted | notexist.
-type denied_message_action() :: reply | ban_and_drop | drop.

-record(state, {host :: binary()}).
-record(participant_session, {group, username, server, resource, ts}).


%%====================================================================
%% gen_mod callbacks
%%====================================================================
start(Host, Opts) ->
  gen_mod:start_child(?MODULE, Host, Opts).


stop(Host) ->
  gen_mod:stop_child(?MODULE, Host).

depends(_Host, _Opts) -> [].

mod_options(_Opts) -> [].

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([Host, _Opts]) ->
  init_db(),
  ejabberd_hooks:add(groups_presence_subscribed, Host, ?MODULE,
    clear_denied_sender_on_join, 30),
  %% run task once for all hosts
  Hosts = lists:sort(ejabberd_config:get_myhosts()),
  case Hosts of
    [Host | _] ->
      erlang:send_after(timer:minutes(10), self(), clean),
      erlang:send_after(timer:minutes(60), self(),
        'delete_zombie_sessions');
    _ ->
      ok
  end,
  {ok, #state{host = Host}}.

init_db() ->
  ejabberd_mnesia:create(?MODULE, participant_session,
    [{ram_copies, [node()]},
      {attributes, record_info(fields, participant_session)},
      {type, bag}]),
  catch ets:new(?DENIED_SENDERS_TABLE, [named_table, public, set,
    {read_concurrency, true}, {write_concurrency, true},
    {heir, erlang:group_leader(), none}]),
  groups_displayed:init_db().

handle_call(_Call, _From, State) ->
  {noreply, State}.

handle_cast(Msg, State) ->
  ?WARNING_MSG("unexpected cast: ~p", [Msg]),
  {noreply, State}.


handle_info(clean, State) ->
  Now = erlang:system_time(second),
  clean_denied_senders(Now),
  groups_displayed:clean(Now),
  erlang:send_after(timer:minutes(10), self(), clean),
  {noreply, State};
handle_info('delete_zombie_sessions', State) ->
  kill_zombies(),
  erlang:send_after(timer:minutes(60),
    self(), 'delete_zombie_sessions'),
  {noreply, State};
handle_info(Info, State) ->
  ?WARNING_MSG("unexpected info: ~p", [Info]),
  {noreply, State}.

terminate(_Reason, #state{host = Host}) ->
  ejabberd_hooks:delete(groups_presence_subscribed, Host, ?MODULE,
    clear_denied_sender_on_join, 30),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

modify(#message{to = To, from = From, body = Body} = Pkt) ->
  GroupS = jid:to_string(jid:remove_resource(To)),
  UserS = jid:to_string(jid:remove_resource(From)),
  UserBareJID = jid:remove_resource(From),
  UserCard = groups_members:user_card(UserS, GroupS),
  Username = UserCard#groups_user.nickname,
  Header = <<Username/binary, ":", "\n">>,
  Length = misc:escaped_text_len(Header),
  GroupEls = [#xmppreference{'begin' = 0, 'end' = Length,
    type = <<"mutable">>}, #groups_x{author = UserCard}],
  NewBody = [T#text{data = <<Header/binary, Text/binary >>}
    || #text{data = Text} = T <- Body],
  Els1 = clean_sub_els(xmpp:get_els(Pkt)),
  Els2 = shift_references(Els1, Length),
  Pkt1 = Pkt#message{body = NewBody, sub_els = GroupEls ++ Els2,
    to = UserBareJID},
  case extract_mentions(Pkt) of
    false -> Pkt1;
    Val ->
      xmpp:put_meta(Pkt1, groups_mentions, Val)
  end.

%%--------------------------------------------------------------------
%% Sub process.
%%--------------------------------------------------------------------
process_messages() ->
  receive
    {message,Message} ->
      process_message(Message),
      process_messages();
    _ ->
      exit(normal)
  after
    300000 -> exit(normal)
  end.

%% Internal functions

send_message(Message, [], GroupJID) ->
  send_message_to_index(GroupJID, Message),
  ok;
send_message(Message, Users, GroupJID) ->
  [User|RestUsers] = Users,
  ejabberd_router:route(GroupJID, User, Message),
  send_message(Message, RestUsers, GroupJID).

process_message(#message{from = From, to = From}) ->
  ok;
process_message(#message{type = headline, body=[]} = Msg) ->
  try xmpp:decode_els(Msg) of
    MsgD ->
      case xmpp:get_subtag(MsgD, #ps_event{}) of
        false -> ok;
        Event ->
          groups_avatars:process_pubsub_event(
            MsgD#message{sub_els = [Event]})
      end
  catch _:{xmpp_codec, _Why} ->
    ok
  end;
process_message(#message{body=[], from = From, type = Type, to = To} = Msg)
  when Type == normal orelse Type == chat ->
  LServer = To#jid.lserver,
  GroupJID = jid:remove_resource(To),
  User = jid:to_string(jid:remove_resource(From)),
  Displayed = groups_displayed:get_marker(Msg, GroupJID),
  PresentType = get_present_type(Msg),
  IsAllowed = case {Displayed, PresentType} of
                {false, false} -> false;
                _ ->
                  groups_members:check_if_exist(LServer,
                    jid:to_string(GroupJID), User)
              end,
  if
    Displayed /= false  andalso IsAllowed ->
      groups_displayed:process_marker(GroupJID, From, Displayed);
    PresentType /= false andalso IsAllowed ->
      change_present_state(To, From, PresentType);
    true ->
      ok
  end;
process_message(#message{type = Type} = Msg)
  when Type == normal orelse Type == chat ->
  case xmpp:get_subtag(Msg, #groups_invite{}) of
    false ->
      case check_message_permission(Msg) of
        allowed ->
          process_message(allowed, Msg);
        {denied, Reason, Why} ->
          case register_denied_message(Msg, Reason) of
            reply ->
              process_message({denied, Reason, Why}, Msg);
            ban_and_drop ->
              ok;
            drop ->
              ok
          end
      end;
    _ ->
      ?DEBUG("Drop message with invite",[]),
      ok
  end;
process_message(_Message) ->
  ok.

process_message({denied, _Reason, <<>>}, Pkt) ->
  ejabberd_router:route_error(Pkt, xmpp:err_not_allowed());
process_message({denied, Reason, Why}, Pkt) ->
  ejabberd_router:route_error(Pkt,
    denied_message_error(Reason, Why, Pkt#message.lang));
process_message(_, Pkt) ->
  OriginID = case xmpp:get_subtag(Pkt, #origin_id{}) of
               false -> Pkt#message.id;
               #origin_id{id = Val}  -> Val
             end,
  Pkt1 = Pkt#message{type = chat, id = OriginID},
  case xmpp:get_subtag(Pkt1, #groups_resend{}) of
    false ->
      modify_and_send(Pkt1);
    _ ->
      re_sent_msg(Pkt1)
  end.

-spec check_message_permission(message()) ->
  allowed | {denied, denied_message_reason(), binary()}.
check_message_permission(#message{to = To, from = From} = Pkt) ->
  User = jid:to_string(jid:remove_resource(From)),
  Group = jid:to_string(jid:remove_resource(To)),
  case has_nested_forwarded(Pkt) of
    true ->
      {denied, nested_forwarded,
        <<"Forwarded messages cannot contain forwarded messages.">>};
    false ->
      case groups_groups:group_is_active(Group) of
        inactive ->
          {denied, inactive, <<"Group is inactive.">>};
        _ ->
          case check_permission_write(User, Group, Pkt) of
            restricted ->
              {denied, restricted,
                <<"You are not allowed to send such messages to this group.">>};
            allowed ->
              allowed;
            _ ->
              {denied, notexist, <<>>}
          end
      end
  end.

denied_message_error(nested_forwarded, Why, Lang) ->
  xmpp:err_not_acceptable(Why, Lang);
denied_message_error(_Reason, Why, Lang) ->
  xmpp:err_not_allowed(Why, Lang).

has_nested_forwarded(Msg) ->
  lists:any(fun reference_has_nested_forwarded/1, get_message_references(Msg)).

reference_has_nested_forwarded(Reference) ->
  case xmpp:get_subtag(Reference, #forwarded{}) of
    #forwarded{sub_els = [ForwardedMsg]} ->
      forwarded_message_has_forwarded(ForwardedMsg);
    _ ->
      false
  end.

forwarded_message_has_forwarded(#message{} = Msg) ->
  message_has_forwarded(Msg);
forwarded_message_has_forwarded(El) ->
  try xmpp:decode(El) of
    #message{} = Msg ->
      message_has_forwarded(Msg);
    _ ->
      false
  catch _:{xmpp_codec, _} ->
    false
  end.

message_has_forwarded(Msg) ->
  lists:any(fun(Reference) ->
    xmpp:get_subtag(Reference, #forwarded{}) /= false
  end, get_message_references(Msg)).

get_message_references(Msg) ->
  lists:filtermap(fun(El) ->
    case decode_reference(El) of
      {ok, Reference} ->
        {true, Reference};
      _ ->
        false
    end
  end, xmpp:get_els(Msg)).

decode_reference(#xmppreference{} = Ref) ->
  {ok, Ref};
decode_reference(El) ->
  case {xmpp:get_name(El), xmpp:get_ns(El)} of
    {<<"reference">>, ?NS_REFERENCES} ->
      try xmpp:decode(El) of
        #xmppreference{} = Ref ->
          {ok, Ref};
        _ ->
          error
      catch _:{xmpp_codec, _} ->
        error
      end;
    _ ->
      false
  end.

-spec check_permission_write(binary(), binary(), xmlel()) -> allowed | restricted | notexist .
check_permission_write(User,Chat, Pkt) ->
  ChatJID = jid:from_string(Chat),
  Server = ChatJID#jid.lserver,
  case groups_members:check_if_exist(Server,Chat,User) of
    true ->
      case groups_members:is_permitted(Server, Chat, User,
        send_message, true, [{message,Pkt}]) of
        true -> allowed;
        _ -> restricted
      end;
    _ ->
      notexist
  end.

get_present_type(Msg) ->
  lists:foldl(fun(CType, Result) ->
    case xmpp:get_subtag(Msg, #chatstate{type = CType}) of
      false -> Result;
      _ when CType == active -> present;
      _ -> not_present
    end end, false, [active, gone, inactive]).

re_sent_msg(#message{from = From, to = To, id = Id} = Pkt) ->
  {LP, Server, _} = jid:tolower(To),
  case mod_unique:get_message(Server, LP, Id) of
    #message{} = Found ->
      FoundMeta = Found#message.meta,
      StanzaID = integer_to_binary(maps:get('stanza_id', FoundMeta)),
      Mod = gen_mod:db_mod(Server, 'mod_mam'),
      case Mod:select(Server, To, To,
        [{'ids',[StanzaID]}], undefined, chat) of
        {[{_, _, Forwarded}], true, 1} ->
          Message1 = hd(Forwarded#forwarded.sub_els),
          Message2 = Message1#message{meta = FoundMeta},
          send_received(Message2, From, To);
        Err ->
          %%  message not found in archive
          ?ERROR_MSG("The message is gone!!! group: ~p, id: ~p.\n ~p",
            [To, StanzaID, Err]),
          ejabberd_router:route_error(Pkt,
            xmpp:err_internal_server_error())
      end;
    _ ->
      Pkt1 = mod_unique:remove_request(Pkt, true),
      modify_and_send(Pkt1)
  end.

modify_and_send(#message{to = To, from = From} = Pkt) ->
  Msg = modify(Pkt),
  Server = To#jid.lserver,
  GroupS = jid:to_string(jid:remove_resource(To)),
  AllUsers = groups_members:users_to_send(Server, GroupS),
  UserBareJID = jid:remove_resource(From),
  Users = AllUsers -- [UserBareJID],
  send_received_and_message(Msg, From, To, Users).

send_received_and_message(Pkt, UserJID, GroupJID, Users) ->
  {Pkt2, _State2} = mod_mam:user_send_packet({Pkt,#{jid => GroupJID}}),
  send_received(Pkt2, UserJID, GroupJID),
  send_message(Pkt2, Users, GroupJID),
  send_notifications(Pkt2, GroupJID, UserJID, Users).


send_message_to_index(GroupJID, Message) ->
  Server = GroupJID#jid.lserver,
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  [Index] = groups_groups:get_info(Group, [index]),
  case Index of
    global ->
      GlobalIndexes = mod_groups:get_option(Server, global_indexs),
      lists:foreach(fun(JIDS) ->
        To = jid:from_string(JIDS),
        MessageDecoded = xmpp:decode(Message),
        M = xmpp:set_from_to(MessageDecoded, GroupJID,To),
        ejabberd_router:route(M) end, GlobalIndexes);
    _ ->
      ok
  end.

send_notifications(Message, GroupJID, AuthorJID, Users) ->
  Server = GroupJID#jid.lserver,
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  case xmpp:get_meta(Message, groups_mentions, false) of
    false -> ok;
    all ->
      Author = jid:to_string(jid:remove_resource(AuthorJID)),
      case groups_members:user_role(Server, Author, Group) of
        <<"member">> -> {error, not_allowed};
        _ ->
          send_notifications(Message, GroupJID, Users)
      end;
    MemberIDs ->
      MemberJIDSs = [groups_members:get_user_by_id(Server, Group, ID)
        || ID <- MemberIDs],
      MemberJIDs = [jid:from_string(S) || S <- MemberJIDSs],
      send_notifications(Message, GroupJID, MemberJIDs)
  end.

send_notifications(_Message, _GroupJID, []) ->
  ok;
send_notifications(Message, GroupJID, [User | Users]) ->
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  Fallback = xmpp:mk_text(<<"You were mentioned in ",Group/binary," group.">>),
  Notification = #xen_notification{category = <<"mention">>,
    sub_els = [
      #forwarded{sub_els = [xmpp:set_from_to(Message, GroupJID, User)]}
    ]},
  Notify = #xen_notify{notification = Notification,
    fallback = Fallback,
    addresses = #addresses{list = [#address{type = to, jid = User}]}},
  IQ = #iq{from = GroupJID, to = User, type = set, id = randoms:get_string(),
    sub_els = [Notify]},
  ejabberd_router:route(IQ),
  send_notifications(Message, GroupJID, Users).

extract_mentions(Pkt) ->
  case xmpp:get_subtag(Pkt, #groups_mentions{}) of
    #groups_mentions{members = []} -> all;
    #groups_mentions{members = Members} ->
      [ ID || #groups_user{id = ID} <- Members, ID /= <<>>];
    _ ->
      false
  end.

clean_sub_els(Els) ->
  lists:filter(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      IsGroup = str:prefix(?NS_GROUPS, NS),
      if
        (Name == <<"archived">> andalso NS == ?NS_MAM_TMP);
        (Name == <<"time">> andalso NS == ?NS_UNIQUE);
        (Name == <<"stanza-id">> andalso NS == ?NS_SID_0);
        NS == ?NS_CARBONS_1;
        NS == ?NS_CARBONS_2;
        NS == ?NS_HINTS;
        IsGroup ->
          false;
        true ->
          true
      end
    end, Els).

send_received(Pkt, UserJID, GroupJID) ->
  JIDBare = jid:remove_resource(UserJID),
  #message{meta = #{stanza_id := StanzaID}, id = OriginID} = Pkt,
  Pkt2 = xmpp:set_from_to(Pkt, UserJID, GroupJID),
  Forwarded = #forwarded{sub_els = [Pkt2]},
  groups_displayed:cache_message(GroupJID, UserJID, StanzaID, OriginID),
  Received = #groups_x{sub_els = [Forwarded]},
  Confirmation = #message{
    from = GroupJID,
    to = JIDBare,
    type = headline,
    sub_els = [Received]},
  ejabberd_router:route(Confirmation).

shift_references(Els, Offset) ->
  lists:filtermap(fun(El) ->
    case decode_reference(El) of
      {ok, Ref} ->
        {true, shift_reference(Ref, Offset)};
      false ->
        true;
      error ->
        false
    end
  end, Els).

shift_reference(#xmppreference{'begin' = undefined, 'end' = undefined} = Ref, _) ->
  Ref;
shift_reference(#xmppreference{'begin' = Begin, 'end' = End} = Ref, Offset) ->
  Ref#xmppreference{'begin' = Begin + Offset, 'end' = End + Offset}.

%% Rate limit denied group messages per user/group pair.

-spec denied_sender_is_banned(message()) -> boolean().
denied_sender_is_banned(#message{} = Pkt) ->
  Key = denied_sender_key(Pkt),
  Now = erlang:system_time(second),
  case ets:info(?DENIED_SENDERS_TABLE) of
    undefined ->
      false;
    _ ->
      case ets:lookup(?DENIED_SENDERS_TABLE, Key) of
        [{Key, _WindowStart, _Count, BannedUntil, _ExpireAt}]
          when BannedUntil > Now ->
          true;
        [{Key, _WindowStart, _Count, _BannedUntil, ExpireAt}]
          when ExpireAt =< Now ->
          ets:delete(?DENIED_SENDERS_TABLE, Key),
          false;
        _ ->
          false
      end
  end.

-spec clear_denied_sender(jid() | binary(), jid() | binary()) -> ok.
clear_denied_sender(UserJID, GroupJID) ->
  case ets:info(?DENIED_SENDERS_TABLE) of
    undefined ->
      ok;
    _ ->
      ets:delete(?DENIED_SENDERS_TABLE,
        {bare_jid_string(UserJID), bare_jid_string(GroupJID)})
  end,
  ok.

clear_denied_sender_on_join(Acc, {_Server, UserJID, Group}) ->
  clear_denied_sender(UserJID, Group),
  Acc.

denied_sender_key(#message{from = From, to = To}) ->
  {bare_jid_string(From), bare_jid_string(To)}.

bare_jid_string(#jid{} = JID) ->
  jid:to_string(jid:remove_resource(JID));
bare_jid_string(JID) when is_binary(JID) ->
  jid:to_string(jid:remove_resource(jid:from_string(JID))).

denied_messages_limit(#message{to = To}) ->
  mod_groups:get_option(To#jid.lserver, denied_messages_limit).

-spec register_denied_message(message(), denied_message_reason()) ->
  denied_message_action().
register_denied_message(#message{} = Pkt, Reason) ->
  Key = denied_sender_key(Pkt),
  Now = erlang:system_time(second),
  {Limit, Window, BanLifetime} = denied_messages_limit(Pkt),
  register_denied_message(Key, Reason, Now, Limit, Window, BanLifetime).

register_denied_message(Key, Reason, Now, Limit, Window, BanLifetime) ->
  case ets:lookup(?DENIED_SENDERS_TABLE, Key) of
    [] ->
      insert_denied_window(Key, Now, Window, 1),
      reply;
    [{Key, _WindowStart, _Count, BannedUntil, _ExpireAt}]
      when BannedUntil > Now ->
      drop;
    [{Key, _WindowStart, _Count, _BannedUntil, ExpireAt}]
      when ExpireAt =< Now ->
      insert_denied_window(Key, Now, Window, 1),
      reply;
    [{Key, WindowStart, _Count, _BannedUntil, _ExpireAt}]
      when WindowStart + Window =< Now ->
      insert_denied_window(Key, Now, Window, 1),
      reply;
    [{Key, WindowStart, Count, _BannedUntil, _ExpireAt}] ->
      NewCount = Count + 1,
      case NewCount > Limit of
        true ->
          block_denied_sender(Key, Reason, Now, WindowStart,
            Window, BanLifetime, NewCount);
        false ->
          insert_denied_window(Key, WindowStart, Window, NewCount),
          reply
      end
  end.

insert_denied_window(Key, WindowStart, Window, Count) ->
  ets:insert(?DENIED_SENDERS_TABLE,
    {Key, WindowStart, Count, 0, WindowStart + Window}).

block_denied_sender(Key, notexist, Now, _WindowStart,
    _Window, BanLifetime, Count) ->
  ban_denied_sender(Key, notexist, Now, BanLifetime, Count),
  ban_and_drop;
block_denied_sender(Key, _Reason, _Now, WindowStart,
    Window, _BanLifetime, Count) ->
  insert_denied_window(Key, WindowStart, Window, Count),
  drop.

ban_denied_sender({User, Group} = Key, Reason, Now, BanLifetime, Count) ->
  BannedUntil = Now + BanLifetime,
  ?INFO_MSG("Temporarily blocked denied group message sender ~p "
    "for group ~p for ~p seconds after ~p denied messages; reason: ~p",
    [User, Group, BanLifetime, Count, Reason]),
  ets:insert(?DENIED_SENDERS_TABLE,
    {Key, Now, Count, BannedUntil, BannedUntil}).

clean_denied_senders(Now) ->
  ?DEBUG("cleaning ~p ETS table", [?DENIED_SENDERS_TABLE]),
  ets:select_delete(
    ?DENIED_SENDERS_TABLE,
    ets:fun2ms(fun({_, _, _, _, ExpireAt}) -> ExpireAt =< Now end)).


%%%===================================================================
%%% present functions
%%%===================================================================

get_present(Group) ->
  Sessions = select_all_sessions(Group),
  AllUsersSession = [{U,S}||{participant_session, _G, U, S, _R, _TS} <- Sessions],
  UniqueOnline = lists:usort(AllUsersSession),
  integer_to_binary(length(UniqueOnline)).

change_present_state(GroupJID, UserJID, PresentType) ->
  Server = GroupJID#jid.lserver,
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  Username = jid:to_string(jid:remove_resource(UserJID)),
  PresentNum = get_present(Group),
  Result  = case PresentType of
              present ->
                set_session(Group, UserJID);
              not_present ->
                delete_session(Group, UserJID)
            end,
  groups_members:update_last_seen(Server, Username, Group),
  case Result of
    ok ->
      send_present(UserJID, GroupJID, PresentNum, PresentType);
    _ -> ignore
  end.

get_users_with_session(Group) ->
  SS = select_all_sessions(Group),
  [jid:make(U,S,R)||{participant_session, _, U, S, R, _} <- SS].

send_present(UserJID, GroupJID, PresentNum, PresentType) ->
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  CurNum = get_present(Group),
  Users =
    case CurNum of
      PresentNum  when PresentType == present ->
        %% notify only the connecting device about the actual count
        [UserJID];
      PresentNum ->
        %% someone left, but the counter didn't change
        [];
      _ ->
        %% notify everyone about the counter change
        get_users_with_session(Group)
    end,
  groups_notifications:send_present(Group, Users, CurNum).

-spec set_session(binary(), jid()) -> ok | ignore.
set_session(Group, UserJID) ->
  Result = case select_session(Group, UserJID) of
             [#participant_session{} = SS] ->
               delete_session(SS),
               ignore;
             _ -> ok
           end,
  {Username, Server, Resource} = jid:tolower(UserJID),
  Session = #participant_session{
    group = Group,
    username = Username,
    server = Server,
    resource =  Resource,
    ts = os:system_time(microsecond)
  },
  mnesia:dirty_write(Session),
  Result.

delete_session(Group, UserJID) ->
  S = select_session(Group, UserJID),
  lists:foreach(fun(N) -> delete_session(N) end, S).

-spec delete_session(#participant_session{}) -> ok.
delete_session(S) ->
  mnesia:dirty_delete_object(S).

select_session(Group, UserJID) ->
  {LUser, LServer, Resource} = jid:tolower(UserJID),
  FN = fun()->
    mnesia:match_object(participant_session,
      {participant_session, Group, LUser, LServer, Resource, '_'},
      read)
       end,
  {atomic,Session} = mnesia:transaction(FN),
  Session.

select_all_sessions(Group) ->
  mnesia:dirty_read(participant_session, Group).

select_sessions(User, Group) ->
  {LUser, LServer, _} = jid:tolower(jid:from_string(User)),
  FN = fun()->
    mnesia:match_object(participant_session,
      {participant_session, Group, LUser, LServer, '_', '_'},
      read)
       end,
  {atomic,Sessions} = mnesia:transaction(FN),
  Sessions.

delete_all_user_sessions(User, Group) ->
  Sessions = select_sessions(User, Group),
  lists:foreach(fun(Session) ->
    delete_session(Session) end, Sessions).

delete_all_sessions(Group) ->
  Sessions = select_all_sessions(Group),
  lists:foreach(fun(Session) ->
    delete_session(Session) end, Sessions).

%% delete sessions older than 1 hour
kill_zombies() ->
  FN = fun()->
    TS = os:system_time(microsecond) - 3600000000,
    MatchHead = #participant_session{ts = '$1', _ = '_'},
    Guards = [{'<', '$1', TS}],
    SS = mnesia:select(participant_session,[{MatchHead, Guards, ['$_']}]),
    lists:foreach(fun(O) ->
      ?WARNING_MSG("Delete session older than 1 hour. Group: ~p; user: ~p",
        [O#participant_session.group, O#participant_session.username]),
      mnesia:delete_object(O) end, SS)
       end,
  mnesia:transaction(FN),
  ok.
