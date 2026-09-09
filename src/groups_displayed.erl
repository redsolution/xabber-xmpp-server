%%%-------------------------------------------------------------------
%%% File    : groups_displayed.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : Displayed marker processing in groups.
%%% Created : 09 Sep 2026 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
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

-module(groups_displayed).
-author('ilya.kalashnikov@redsolution.com').
-compile([{parse_transform, ejabberd_sql_pt}]).

-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

%% API
-export([
  init_db/0,
  clean/1,
  get_marker/2,
  process_marker/3,
  cache_message/4]).

-define(DISPLAYED_CACHE_TABLE, groups_displayed_cache).
-define(DISPLAYED_SENT_TABLE, groups_displayed_sent).
-define(DISPLAYED_CACHE_TTL, 7 * 24 * 60 * 60).


%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

init_db() ->
  catch ets:new(?DISPLAYED_CACHE_TABLE, [named_table, public, ordered_set,
    {read_concurrency, true}, {write_concurrency, true},
    {heir, erlang:group_leader(), none}]),
  catch ets:new(?DISPLAYED_SENT_TABLE, [named_table, public, set,
    {read_concurrency, true}, {write_concurrency, true},
    {heir, erlang:group_leader(), none}]).

clean(Now) ->
  clean_cache(Now),
  clean_sent(Now).

get_marker(Pkt, GroupJID) ->
  case xmpp:get_subtag(Pkt, #mark_displayed{}) of
    #mark_displayed{sub_els = Els} = D ->
      NewEls = lists:filtermap(
        fun(El) ->
          Name = xmpp:get_name(El),
          NS = xmpp:get_ns(El),
          if (Name == <<"stanza-id">> andalso NS == ?NS_SID_0) ->
            try xmpp:decode(El) of
              #stanza_id{by = GroupJID} = SID ->
                {true, SID};
              _ -> false
            catch _:{xmpp_codec, _} ->
              false
            end;
            true ->
              false
          end
        end, Els),
      D#mark_displayed{sub_els = NewEls};
    _ ->
      false
  end.

process_marker(GroupJID, UserJID, #mark_displayed{id = OriginID} = Displayed) ->
  StanzaID = get_stanza_id(Displayed, GroupJID, GroupJID#jid.lserver,
    OriginID),
  check_marker(GroupJID, UserJID, StanzaID);
process_marker(_GroupJID, _UserJID, _Displayed) ->
  ok.

cache_message(GroupJID, UserJID, StanzaID, OriginID) ->
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  User = jid:to_string(jid:remove_resource(UserJID)),
  case User of
    Group ->
      ok;
    _ ->
      cache_displayed_message(Group, User, StanzaID, OriginID)
  end.


%%--------------------------------------------------------------------
%% Internal functions.
%%--------------------------------------------------------------------

get_stanza_id(Pkt, BareJID, LServer, OriginID) ->
  case xmpp:get_subtag(Pkt, #stanza_id{}) of
    #stanza_id{by = BareJID, id = StanzaID} ->
      parse_stanza_id(StanzaID);
    _ ->
      mod_unique:get_stanza_id_by_origin_id(LServer,
        OriginID, BareJID#jid.luser)
  end.

parse_stanza_id(StanzaID) ->
  try binary_to_integer(StanzaID) of
    ID -> ID
  catch _:_ ->
    0
  end.

check_marker(GroupJID, UserJID, StanzaID)
  when is_integer(StanzaID), StanzaID > 0 ->
  Group = jid:to_string(jid:remove_resource(GroupJID)),
  User = jid:to_string(jid:remove_resource(UserJID)),
  process_displayed(GroupJID, Group, User, StanzaID);
check_marker(_GroupJID, _UserJID, _StanzaID) ->
  ok.

process_displayed(GroupJID, Group, User, StanzaID) ->
  Now = erlang:system_time(second),
  case find_cached_displayed(Group, StanzaID, Now) of
    {ok, _DisplayedStanzaID, User, _OriginID} ->
      delete_displayed_cache_until(Group, StanzaID, User);
    {ok, DisplayedStanzaID, Author, OriginID} ->
      maybe_send_displayed(GroupJID, Group, DisplayedStanzaID, Author,
        OriginID, Now),
      delete_displayed_cache_until(Group, StanzaID);
    not_found ->
      case select_displayed_from_archive(GroupJID, Group, User, StanzaID) of
        {ok, DisplayedStanzaID, Author, OriginID} ->
          maybe_send_displayed(GroupJID, Group, DisplayedStanzaID, Author,
            OriginID, Now);
        not_found ->
          ok
      end
  end.

cache_displayed_message(_Group, _User, StanzaID, _OriginID)
  when not is_integer(StanzaID); StanzaID =< 0 ->
  ok;
cache_displayed_message(Group, User, StanzaID, OriginID) ->
  case ets:info(?DISPLAYED_CACHE_TABLE) of
    undefined ->
      ok;
    _ ->
      delete_displayed_cache_until(Group, StanzaID, User),
      drop_previous_displayed_message(Group, User, StanzaID),
      ExpireAt = erlang:system_time(second) + ?DISPLAYED_CACHE_TTL,
      ets:insert(?DISPLAYED_CACHE_TABLE,
        {{Group, StanzaID}, User, OriginID, ExpireAt})
  end.

drop_previous_displayed_message(Group, User, StanzaID) ->
  case ets:prev(?DISPLAYED_CACHE_TABLE, {Group, StanzaID}) of
    {Group, _PrevStanzaID} = Key ->
      case ets:lookup(?DISPLAYED_CACHE_TABLE, Key) of
        [{Key, User, _OriginID, _ExpireAt}] ->
          ets:delete(?DISPLAYED_CACHE_TABLE, Key);
        _ ->
          ok
      end;
    _ ->
      ok
  end.

find_cached_displayed(Group, StanzaID, Now) ->
  case ets:info(?DISPLAYED_CACHE_TABLE) of
    undefined ->
      not_found;
    _ ->
      case ets:lookup(?DISPLAYED_CACHE_TABLE, {Group, StanzaID}) of
        [Msg] ->
          cached_displayed_result(Group, Msg, Now);
        [] ->
          find_prev_cached_displayed(Group,
            ets:prev(?DISPLAYED_CACHE_TABLE, {Group, StanzaID}), Now)
      end
  end.

find_prev_cached_displayed(Group, {Group, _StanzaID} = Key, Now) ->
  case ets:lookup(?DISPLAYED_CACHE_TABLE, Key) of
    [Msg] ->
      cached_displayed_result(Group, Msg, Now);
    [] ->
      find_prev_cached_displayed(Group,
        ets:prev(?DISPLAYED_CACHE_TABLE, Key), Now)
  end;
find_prev_cached_displayed(_Group, _Key, _Now) ->
  not_found.

cached_displayed_result(Group, {{Group, StanzaID} = Key, User, OriginID,
    ExpireAt}, Now) ->
  case ExpireAt =< Now of
    true ->
      PrevKey = ets:prev(?DISPLAYED_CACHE_TABLE, Key),
      ets:delete(?DISPLAYED_CACHE_TABLE, Key),
      find_prev_cached_displayed(Group, PrevKey, Now);
    false ->
      {ok, StanzaID, User, OriginID}
  end.

select_displayed_from_archive(#jid{luser = LUser, lserver = LServer},
    Group, User, StanzaID) ->
  case ejabberd_sql:sql_query(LServer,
      ?SQL("select @(timestamp)d, @(bare_peer)s, @(origin_id)s "
      "from archive where username=%(LUser)s and timestamp <= %(StanzaID)d "
      "and bare_peer <> %(Group)s and %(LServer)H "
      "order by timestamp desc limit 1")) of
    {selected, [{_DisplayedStanzaID, User, _OriginID}]} ->
      not_found;
    {selected, [{DisplayedStanzaID, Author, OriginID}]} ->
      {ok, DisplayedStanzaID, Author,
        normalize_displayed_origin_id(OriginID, DisplayedStanzaID)};
    _ ->
      not_found
  end.

maybe_send_displayed(GroupJID, Group, StanzaID, User, OriginID, Now) ->
  case displayed_sent(Group, User, StanzaID, Now) of
    true ->
      ok;
    false ->
      send_displayed(GroupJID, StanzaID, User, OriginID),
      mark_displayed_sent(Group, User, StanzaID, Now)
  end.

displayed_sent(Group, User, StanzaID, Now) ->
  Key = {displayed_sent, Group, User},
  case ets:info(?DISPLAYED_SENT_TABLE) of
    undefined ->
      false;
    _ ->
      case ets:lookup(?DISPLAYED_SENT_TABLE, Key) of
        [{Key, LastStanzaID, ExpireAt}]
          when ExpireAt > Now, LastStanzaID >= StanzaID ->
          true;
        [{Key, _LastStanzaID, ExpireAt}] when ExpireAt =< Now ->
          ets:delete(?DISPLAYED_SENT_TABLE, Key),
          false;
        _ ->
          false
      end
  end.

mark_displayed_sent(Group, User, StanzaID, Now) ->
  Key = {displayed_sent, Group, User},
  case ets:info(?DISPLAYED_SENT_TABLE) of
    undefined ->
      ok;
    _ ->
      ets:insert(?DISPLAYED_SENT_TABLE,
        {Key, StanzaID, Now + ?DISPLAYED_CACHE_TTL})
  end.

send_displayed(GroupJID, StanzaID, User, OriginID) ->
  Displayed = #mark_displayed{id = OriginID,
    sub_els = [#stanza_id{id = integer_to_binary(StanzaID), by = GroupJID}]},
  Message = #message{type = chat, from = GroupJID,
    to = jid:from_string(User), sub_els = [Displayed],
    id = randoms:get_string()},
  ejabberd_router:route(Message).

delete_displayed_cache_until(Group, StanzaID) ->
  FirstKey = ets:next(?DISPLAYED_CACHE_TABLE, {Group, 0}),
  delete_displayed_cache_until(Group, StanzaID, FirstKey, all).

delete_displayed_cache_until(Group, StanzaID, User) ->
  FirstKey = ets:next(?DISPLAYED_CACHE_TABLE, {Group, 0}),
  delete_displayed_cache_until(Group, StanzaID, FirstKey, {except, User}).

delete_displayed_cache_until(Group, StanzaID, {Group, SID} = Key, Mode)
  when SID =< StanzaID ->
  NextKey = ets:next(?DISPLAYED_CACHE_TABLE, Key),
  delete_displayed_cache_entry(Key, Mode),
  delete_displayed_cache_until(Group, StanzaID, NextKey, Mode);
delete_displayed_cache_until(_Group, _StanzaID, _Key, _Mode) ->
  ok.

delete_displayed_cache_entry(Key, all) ->
  ets:delete(?DISPLAYED_CACHE_TABLE, Key);
delete_displayed_cache_entry(Key, {except, User}) ->
  case ets:lookup(?DISPLAYED_CACHE_TABLE, Key) of
    [{Key, User, _OriginID, _ExpireAt}] ->
      ok;
    [_Msg] ->
      ets:delete(?DISPLAYED_CACHE_TABLE, Key);
    [] ->
      ok
  end.

normalize_displayed_origin_id(OriginID, _StanzaID)
  when is_binary(OriginID), OriginID =/= <<>> ->
  OriginID;
normalize_displayed_origin_id(_OriginID, StanzaID) ->
  integer_to_binary(StanzaID).

clean_cache(Now) ->
  case ets:info(?DISPLAYED_CACHE_TABLE) of
    undefined ->
      ok;
    _ ->
      ets:select_delete(?DISPLAYED_CACHE_TABLE,
        ets:fun2ms(fun({_Key, _User, _OriginID, ExpireAt})
          when ExpireAt =< Now -> true end)),
      ok
  end.

clean_sent(Now) ->
  case ets:info(?DISPLAYED_SENT_TABLE) of
    undefined ->
      ok;
    _ ->
      ets:select_delete(?DISPLAYED_SENT_TABLE,
        ets:fun2ms(fun({_Key, _StanzaID, ExpireAt})
          when ExpireAt =< Now -> true end)),
      ok
  end.
