%%% File    : mod_rewrite.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : XEP-REWRITE: Message Delete and Rewrite
%%% Created : 07 Nov 2026 by Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
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
-module(mod_rewrite).
-author('ilya.kalashnikov@redsolution.com').
-behavior(gen_mod).
-compile([{parse_transform, ejabberd_sql_pt}]).


%% gen_mod callbacks.
-export([start/2, stop/1, reload/3, depends/2,
  mod_opt_type/1, mod_options/1]).

%%%% ejabberd_hooks callbacks.
-export([disco_features/5, remove_user/2]).

%%%% gen_iq_handler callback.
-export([pre_process_iq/1]).

-export([delete_message/3]).
%%-export([
%%  get_version/2,
%%  filter_new_els/1
%%]).

-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").

-define(REWRITE_ALL_TYPES, <<"all">>).
-define(REWRITE_ARCHIVE, <<"archive">>).

%%--------------------------------------------------------------------
%% gen_mod callbacks.
%%--------------------------------------------------------------------
-spec start(binary(), gen_mod:opts()) -> ok.
start(Host, _Opts) ->
  register_iq_handlers(Host),
  register_hooks(Host).

-spec stop(binary()) -> ok.
stop(Host) ->
  unregister_hooks(Host),
  unregister_iq_handlers(Host).

-spec reload(binary(), gen_mod:opts(), gen_mod:opts()) -> ok.
reload(_Host, _NewOpts, _OldOpts) ->
  ok.

-spec depends(binary(), gen_mod:opts()) -> [{module(), hard | soft}].
depends(_Host, _Opts) ->
  [].

mod_opt_type(autoclean) ->
  fun (B) when is_boolean(B) -> B end.

mod_options(_Host) ->
  [
    {autoclean, false}
  ].

%%--------------------------------------------------------------------
%% Hooks.
%%--------------------------------------------------------------------
%% Service discovery.
-spec disco_features(empty | {result, [binary()]} | {error, stanza_error()},
    jid(), jid(), binary(), binary())
      -> {result, [binary()]} | {error, stanza_error()}.
disco_features(empty, From, To, Node, Lang) ->
  disco_features({result, []}, From, To, Node, Lang);
disco_features({result, OtherFeatures}, _From, _To, <<"">>, _Lang) ->
  {result, [?NS_XABBER_REWRITE | OtherFeatures]};
disco_features(Acc, _From, _To, _Node, _Lang) ->
  Acc.

%% Remove user.
remove_user(User, Server) ->
  sql_delete_all_events(User, Server).

%%--------------------------------------------------------------------
%% API.
%%--------------------------------------------------------------------

pre_process_iq(#iq{to = To} = IQ) ->
  {PUser, PServer, _} = jid:tolower(To),
  case mod_xabber_entity:get_entity_type(PUser, PServer) of
    group -> groups_iq_handler:make_action(IQ);
    _ ->
      process_iq(IQ)
  end.


%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------
-spec process_iq(iq()) -> iq().
process_iq(#iq{type = set, lang = Lang, sub_els = [#rewrite_query{}]} = IQ) ->
  Txt = <<"Value 'set' of 'type' attribute is not allowed">>,
  xmpp:make_error(IQ, xmpp:err_not_allowed(Txt, Lang));
%% Query the current version
process_iq(#iq{type = get, sub_els = [#rewrite_query{version = undefined}],
  from = #jid{luser = LUser, lserver = LServer},
  to = #jid{luser = LUser, lserver = LServer}} = IQ) ->
  Version = get_version(LServer, LUser),
  xmpp:make_iq_result(IQ, #rewrite_query{version = Version});
process_iq(#iq{type = get, sub_els = [#rewrite_query{version = Ver, max = Max0}],
  from = #jid{luser = LUser, lserver = LServer} = From,
  to = #jid{luser = LUser, lserver = LServer}} = IQ) ->
  Max = if
           Max0 == undefined -> 50;
           Max0 > 50 -> 50;
           true -> Max0
         end,
  case get_count_events(LServer, LUser, Ver) of
    {ok, CurrentVer, ChatList} ->
      send_retract_query_messages(From, Ver, Max, ChatList, CurrentVer),
      xmpp:make_iq_result(IQ, #rewrite_query{version = CurrentVer});
    {error, Reason} ->
      ?ERROR_MSG("Failed to query rewrite history: ~p", [Reason]),
      xmpp:make_error(IQ, xmpp:err_internal_server_error())
  end;
process_iq(#iq{type = get, lang = Lang} = IQ) ->
  Txt = <<"Value 'get' of 'type' attribute is not allowed">>,
  xmpp:make_error(IQ, xmpp:err_not_allowed(Txt, Lang));
%%%%%%
%% Retract message
%%%%%%
process_iq(#iq{type = set, sub_els = [#retract_message{symmetric = false,
  conversation = PeerJID, sid = #stanza_id{by = By, id = ID}}],
  from = #jid{luser = LUser, lserver = LServer},
  to = #jid{luser = LUser, lserver = LServer}} = IQ) ->
  User = jid:make(LUser, LServer),
  case jid:tolower(By) =:= jid:tolower(User) of
    true -> retract_local_message(IQ, User, PeerJID, ID);
    false -> xmpp:make_error(IQ, xmpp:err_bad_request())
  end;
process_iq(#iq{type = set, sub_els = [#retract_message{symmetric = true,
  conversation = PeerJID, sid = #stanza_id{by = By, id = ID}} = Retract],
  from = #jid{luser = LUser, lserver = LServer},
  to = #jid{luser = LUser, lserver = LServer}} = IQ) ->
  User = jid:make(LUser, LServer),
  case jid:tolower(By) =:= jid:tolower(User) of
    true -> symmetric_retract(IQ, User, jid:remove_resource(PeerJID), ID, Retract);
    false -> xmpp:make_error(IQ, xmpp:err_bad_request())
  end;
process_iq(#iq{type = set, sub_els = [#retract_message{symmetric = true,
  sid = #stanza_id{by = By, id = ID}, oid = OID}],
  from = #jid{resource = <<>>} = From, to = To} = IQ) ->
  case jid:tolower(By) =:= jid:tolower(From) of
    true ->
      case retract_peer_message(jid:remove_resource(To), From, ID, OID) of
        ok ->
          xmpp:make_iq_result(IQ);
        error -> xmpp:make_error(IQ, xmpp:err_internal_server_error())
      end;
    false -> xmpp:make_error(IQ, xmpp:err_bad_request())
  end;
%%%%%%
%% Replace message
%%%%%%
process_iq(#iq{type = set, sub_els = [#replace{conversation = PeerJID,
  sid = #stanza_id{by = By, id = ID}} = Replace],
  from = #jid{luser = LUser, lserver = LServer},
  to = #jid{luser = LUser, lserver = LServer}} = IQ) ->
  User = jid:make(LUser, LServer),
  case jid:tolower(By) =:= jid:tolower(User) of
    true -> symmetric_replace(IQ, User, jid:remove_resource(PeerJID), ID, Replace);
    false -> xmpp:make_error(IQ, xmpp:err_bad_request())
  end;
process_iq(#iq{type = set, sub_els = [#replace{sid = #stanza_id{by = By, id = ID},
  oid = OID, replacement = #replacement_message{message = Message}}],
  from = #jid{resource = <<>>} = From, to = To} = IQ) ->
  case jid:tolower(By) =:= jid:tolower(From) of
    true -> replace_iq_result(IQ, replace_peer_message(jid:remove_resource(To), From, ID, OID, Message));
    false -> xmpp:make_error(IQ, xmpp:err_bad_request())
  end;
%%%%%%
%% Retract all
%%%%%%
%% Allowed only local and asymmetric retract all
process_iq(#iq{sub_els = [#retract_all{}],
  from = #jid{luser = U1, lserver = S1},
  to = #jid{luser = U2, lserver = S2}} = IQ) when U1 /= U2 orelse S1 /= S2 ->
  xmpp:make_error(IQ, xmpp:err_not_allowed());
process_iq(#iq{sub_els = [#retract_all{symmetric = true}]} = IQ) ->
  xmpp:make_error(IQ, xmpp:err_not_allowed());
%% The sender attribute is not supported in P2P chats.
process_iq(#iq{sub_els = [#retract_all{sender = S }]} = IQ) when S /= <<>> ->
  xmpp:make_error(IQ, xmpp:err_feature_not_implemented());
%% Retract all with the contact
process_iq(#iq{type = set, sub_els = [#retract_all{symmetric = false,
  type = <<>>, conversation = Peer}],
  from = #jid{luser = LUser, lserver = LServer},
  to = #jid{luser = LUser, lserver = LServer}} = IQ) ->
  retract_conversation(IQ, jid:make(LUser, LServer), Peer, <<>>);
%%Retract all messages in the specific conversation
process_iq(#iq{type = set, sub_els = [#retract_all{symmetric = false,
  type = CType, conversation = Peer}],
  from = #jid{luser = LUser, lserver = LServer},
  to = #jid{luser = LUser, lserver = LServer}} = IQ) ->
  retract_conversation(IQ, jid:make(LUser, LServer), Peer, CType);
%%%%%%
%% Retract archive
%%%%%%
process_iq(#iq{type = set, sub_els = [#retract_archive{}],
  from = #jid{luser = LUser, lserver = LServer},
  to = #jid{luser = LUser, lserver = LServer}} = IQ)->
  retract_archive(IQ, jid:make(LUser, LServer));
%%%%%%
%% To hell
%%%%%%
process_iq(IQ) ->
  ?INFO_MSG("IQ ~p",[IQ]),
  xmpp:make_error(IQ, xmpp:err_not_allowed()).

get_version(Server, Username) ->
  sql_get_version(Server, Username).

get_count_events(Server, Username, Version) ->
  sql_get_count_events(Server, Username, Version).

retract_archive(IQ, #jid{luser = User, lserver = Server} = UserJID) ->
  Version = erlang:system_time(microsecond),
  Event = #retract_archive{version = Version},
  XML = fxml:element_to_binary(xmpp:encode(Event)),
  case sql_retract_archive(Server, User, Version, XML) of
    {atomic, ok} ->
      ejabberd_hooks:run(retract_archive, Server, [User, Server, Event]),
      notify(Event, UserJID),
      xmpp:make_iq_result(IQ);
    {aborted, Reason} ->
      ?ERROR_MSG("Failed to retract archive: ~p", [Reason]),
      xmpp:make_error(IQ, xmpp:err_internal_server_error())
  end.

delete_message(Server, User, StanzaID) ->
  case sql_delete_message(Server, User, StanzaID) of
    {updated, 1} -> ok;
    {updated, 0} -> {error, not_found};
    Err ->
      ?ERROR_MSG("Error during delete: ~p", [Err]),
      {error, db_error}
  end.

sql_delete_message(Server, User, StanzaID) ->
  ejabberd_sql:sql_query(Server,
    ?SQL("delete from archive where timestamp=%(StanzaID)d "
      "and username=%(User)s and %(Server)H")).

retract_conversation(IQ, #jid{luser = User, lserver = Server} = UserJID,
    PeerJID, Type) ->
  Peer = jid:remove_resource(PeerJID),
  Conversation = jid:encode(jid:tolower(Peer)),
  Version = erlang:system_time(microsecond),
  Event = #retract_all{conversation = Peer, type = Type, version = Version},
  XML = fxml:element_to_binary(xmpp:encode(Event)),
  case sql_retract_conversation(Server, User, Conversation, Type, Version, XML) of
    {atomic, ok} ->
      ejabberd_hooks:run(retract_all_messages, Server, [User, Server, Event]),
      notify(Event, UserJID),
      xmpp:make_iq_result(IQ);
    {aborted, Reason} ->
      ?ERROR_MSG("Failed to retract conversation: ~p", [Reason]),
      xmpp:make_error(IQ, xmpp:err_internal_server_error())
  end.

retract_local_message(IQ, UserJID, PeerJID, ID) ->
  case retract_message(UserJID, PeerJID, ID) of
    ok -> xmpp:make_iq_result(IQ);
    bad_request -> xmpp:make_error(IQ, xmpp:err_bad_request());
    error -> xmpp:make_error(IQ, xmpp:err_internal_server_error())
  end.

retract_message(#jid{luser = User, lserver = Server} = UserJID, PeerJID, ID) ->
  try binary_to_integer(ID) of
    Timestamp when Timestamp >= 0 ->
      Peer = jid:remove_resource(PeerJID),
      Version = erlang:system_time(microsecond),
      Event = #retract_message{conversation = Peer, version = Version,
        sid = #stanza_id{by = UserJID, id = ID}},
      XML = fxml:element_to_binary(xmpp:encode(Event)),
      case sql_retract_local_message(Server, User, jid:encode(jid:tolower(Peer)),
          Timestamp, Version, XML) of
        {atomic, {ok, Type}} ->
          ejabberd_hooks:run(retract_message, Server, [User, Server, Type, Event]),
          notify(Event, UserJID),
          ok;
        {atomic, not_found} -> ok;
        {aborted, Reason} ->
          ?ERROR_MSG("Failed to retract message: ~p", [Reason]),
          error
      end;
    _ -> bad_request
  catch error:badarg -> bad_request
  end.

symmetric_retract(IQ, User, Peer, ID, Retract) ->
  case sql_find_original(User, Peer, ID) of
    {ok, XML, OriginID} ->
      Message = xmpp:decode(fxml_stream:parse_element(XML)),
      case jid:tolower(jid:remove_resource(Message#message.from)) =:= jid:tolower(User) of
        true -> forward_retract(IQ, User, Peer, ID,
          add_origin_id(Retract, OriginID));
        false -> xmpp:make_error(IQ, xmpp:err_not_allowed())
      end;
    not_found -> forward_retract(IQ, User, Peer, ID, Retract);
    error -> xmpp:make_error(IQ, xmpp:err_internal_server_error())
  end.

add_origin_id(#retract_message{oid = undefined} = Retract, ID)
    when is_binary(ID), ID /= <<>> ->
  Retract#retract_message{oid = #origin_id{id = ID}};
add_origin_id(Retract, _) -> Retract.

symmetric_replace(IQ, User, Peer, ID, #replace{replacement = #replacement_message{message = Message}} = Replace) ->
  case sql_find_original(User, Peer, ID) of
    {ok, XML, OriginID} ->
      Original = xmpp:decode(fxml_stream:parse_element(XML)),
      case message_from(Original, User) of
        true ->
          Request = add_replace_origin_id(Replace, OriginID),
          case {jid:tolower(Peer) =:= jid:tolower(User),
                lists:member(Peer#jid.lserver, ejabberd_config:get_myhosts())} of
            {true, _} ->
              replace_iq_result(IQ, replace_archive_message(User, Peer, ID, User, Message));
            {false, true} ->
              Result = replace_peer_message(Peer, User, ID, Request#replace.oid, Message),
              case Result of
                ok -> replace_iq_result(IQ, replace_archive_message(User, Peer, ID, User, Message));
                _ -> replace_iq_result(IQ, Result)
              end;
            {false, false} ->
              Complete = fun() -> replace_iq_result(IQ,
                replace_archive_message(User, Peer, ID, User, Message)) end,
              send_to_remote_server(User, Peer, IQ,
                Request#replace{conversation = User}, Complete),
              ignore
          end;
        false -> xmpp:make_error(IQ, xmpp:err_not_allowed())
      end;
    not_found -> xmpp:make_error(IQ, xmpp:err_item_not_found());
    error -> xmpp:make_error(IQ, xmpp:err_internal_server_error())
  end.

add_replace_origin_id(#replace{oid = undefined} = Replace, ID)
    when is_binary(ID), ID /= <<>> -> Replace#replace{oid = #origin_id{id = ID}};
add_replace_origin_id(Replace, _) -> Replace.

replace_peer_message(User, Peer, ID, OID, Message) ->
  case sql_find_peer_message(User, Peer, ID, OID) of
    {ok, LocalID, _} -> replace_archive_message(User, Peer, integer_to_binary(LocalID), Peer, Message);
    not_found -> not_found;
    error -> error
  end.

replace_iq_result(IQ, ok) -> xmpp:make_iq_result(IQ);
replace_iq_result(IQ, not_found) -> xmpp:make_error(IQ, xmpp:err_item_not_found());
replace_iq_result(IQ, not_allowed) -> xmpp:make_error(IQ, xmpp:err_not_allowed());
replace_iq_result(IQ, _) -> xmpp:make_error(IQ, xmpp:err_internal_server_error()).

message_from(#message{from = #jid{} = From}, Author) ->
  jid:tolower(jid:remove_resource(From)) =:= jid:tolower(Author);
message_from(_, _) -> false.

replace_archive_message(#jid{luser = User, lserver = Server} = UserJID, Peer, ID, Author, Message) ->
  case sql_find_original(UserJID, Peer, ID) of
    {ok, OldXML, _} ->
      Original = xmpp:decode(fxml_stream:parse_element(OldXML)),
      case message_from(Original, Author) of
        false -> not_allowed;
        true ->
          Version = erlang:system_time(microsecond),
          OldEls = [El || El <- Original#message.sub_els, protected_element(El)],
          NewEls = [El || El <- Message#message.sub_els, not protected_element(El),
            not replaced_element(El)],
          Replaced = #replaced{stamp = erlang:timestamp()},
          NewMessage = Original#message{body = Message#message.body,
            subject = Message#message.subject, sub_els = OldEls ++ NewEls ++ [Replaced]},
          NewEl = xmpp:encode(NewMessage),
          XML = fxml:element_to_binary(NewEl),
          Text = fxml:get_subtag_cdata(NewEl, <<"body">>),
          Tags = mod_mam_sql:get_message_tags(NewEl),
          Timestamp = binary_to_integer(ID),
          Archived = #mam_archived{by = UserJID, id = ID},
          StanzaID = #stanza_id{by = UserJID, id = ID},
          Time = #delivery_time{by = UserJID, stamp = misc:usec_to_now(Timestamp)},
          Notification = NewMessage#message{sub_els = [Archived, StanzaID, Time | NewMessage#message.sub_els]},
          Event = #replace{conversation = Peer, sid = StanzaID, version = Version,
            replacement = #replacement_message{message = Notification}},
          EventXML = fxml:element_to_binary(xmpp:encode(Event)),
          Conversation = jid:encode(jid:tolower(Peer)),
          case sql_replace_message(Server, User, Conversation, Timestamp, OldXML,
              XML, Text, Tags, Version, EventXML) of
            {atomic, {ok, Type}} ->
              ejabberd_hooks:run(replace_message, Server, [User, Server, Type, Event]),
              notify(Event, UserJID),
              ok;
            {atomic, not_found} -> not_found;
            {aborted, Reason} -> ?ERROR_MSG("Failed to replace message: ~p", [Reason]), error
          end
      end;
    not_found -> not_found;
    error -> error
  end.

protected_element(El) ->
  Name = xmpp:get_name(El),
  NS = xmpp:get_ns(El),
  (NS == ?NS_SID_0 andalso (Name == <<"stanza-id">> orelse Name == <<"origin-id">>)) orelse
  (NS == ?NS_MAM_TMP andalso Name == <<"archived">>) orelse
  (NS == ?NS_UNIQUE andalso Name == <<"time">>) orelse
  (NS == ?NS_DELAY andalso Name == <<"delay">>) orelse
  (Name == <<"x">> andalso str:prefix(?NS_GROUPS, NS)).

replaced_element(El) ->
  xmpp:get_name(El) == <<"replaced">> andalso xmpp:get_ns(El) == ?NS_XABBER_REWRITE.

forward_retract(IQ, User, #jid{lserver = Host} = Peer, ID, Retract) ->
  case lists:member(Host, ejabberd_config:get_myhosts()) of
    true ->
      case retract_peer_message(Peer, User, ID, Retract#retract_message.oid) of
        ok -> retract_local_message(IQ, User, Peer, ID);
        error -> xmpp:make_error(IQ, xmpp:err_internal_server_error())
      end;
    false ->
      Complete = fun() -> retract_local_message(IQ, User, Peer, ID) end,
      send_to_remote_server(User, Peer, IQ,
        Retract#retract_message{conversation = User}, Complete),
      ignore
  end.

retract_peer_message(User, Peer, ID, OID) ->
  case sql_find_peer_message(User, Peer, ID, OID) of
    {ok, LocalID, XML} ->
      Message = xmpp:decode(fxml_stream:parse_element(XML)),
      case jid:tolower(jid:remove_resource(Message#message.from)) =:= jid:tolower(Peer) of
        true ->
          case retract_message(User, Peer, integer_to_binary(LocalID)) of
            ok -> ok;
            _ -> error
          end;
        false -> error
      end;
    not_found -> ok;
    error -> error
  end.

notify(Event, UserJID) ->
  Message = #message{id = randoms:get_string(), type = headline,
    from = UserJID, to = UserJID, sub_els = [Event]},
  ejabberd_router:route(Message).

send_retract_query_messages(JID, Version, Max, ChatList, CurrentVer) ->
  {LUser, LServer, _LResource} = jid:tolower(JID),
  Msg = #message{from = jid:remove_resource(JID), to = JID, type = headline},
  case lists:any(fun({_, Type, _, _}) -> Type == ?REWRITE_ARCHIVE end, ChatList) of
    true ->
      case sql_get_archive_event(LServer, LUser, Version, CurrentVer) of
        {ok, TS, XML} ->
          Event = fxml_stream:parse_element(XML),
          Delay = #delay{stamp = misc:usec_to_now(TS)},
          ejabberd_router:route(Msg#message{id = randoms:get_string(),
            sub_els = [Event, Delay]});
        _ -> ok
      end,
      CurrentVer;
    false ->
      send_conversation_events(Msg, LUser, LServer, Version, Max, ChatList, CurrentVer)
  end.

send_conversation_events(Msg, LUser, LServer, Version, Max, ChatList, CurrentVer) ->
  AllTypeConversations = [Conv || {Conv, ?REWRITE_ALL_TYPES, _, ResetCount} <- ChatList,
    ResetCount > 0],
  RelevantChats = [Chat || {Conv, Type, _, _} = Chat <- ChatList,
    Type == ?REWRITE_ALL_TYPES orelse not lists:member(Conv, AllTypeConversations)],
  DropArchiveChats = lists:filter(
    fun({_, Type, Count, ResetCount}) ->
      Type =/= ?REWRITE_ARCHIVE andalso (ResetCount > 0 orelse Count > Max)
    end, RelevantChats),
  NotifyChats = RelevantChats -- DropArchiveChats,
  RetractNotifications = get_query(LServer, LUser, Version, CurrentVer, NotifyChats),
  Msgs1 = lists:map(fun({TS, Element}) ->
    Event = fxml_stream:parse_element(Element),
    Delay = #delay{stamp = misc:usec_to_now(TS)},
    Msg#message{id= randoms:get_string(), sub_els = [Event, Delay]}
                    end, RetractNotifications),
  Msgs2 = lists:map(fun({Conv, CType, _, _}) ->
    Type = case CType of ?REWRITE_ALL_TYPES -> <<>>; _ -> CType end,
    Invalidate = #rewrite_invalidate{version = CurrentVer,
      conversation = jid:from_string(Conv),
      type = Type},
    Msg#message{id= randoms:get_string(), sub_els = [Invalidate]}
                    end, DropArchiveChats),
  lists:foreach(fun(M) -> ejabberd_router:route(M) end, Msgs1 ++ Msgs2),
  CurrentVer.

get_query(Server, Username, Version, CurrentVer, ChatList) ->
  sql_get_query(Server, Username, Version, CurrentVer,
    [{C, T} || {C, T, _, _} <- ChatList]).


send_to_remote_server(User, PeerJID, IQ, Payload, Complete) ->
  HandleResponse = fun(#iq{type = result}) ->
      Result = Complete(),
      ejabberd_router:route(Result);
    (#iq{type = error} = Reply) ->
      Error = case xmpp:get_error(Reply) of
                #stanza_error{} = RemoteError -> RemoteError;
                _ -> xmpp:err_internal_server_error()
              end,
      Result = xmpp:make_error(IQ, Error),
      ejabberd_router:route(Result);
    (timeout) ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_remote_server_timeout()))
                   end,
  IQ1 = IQ#iq{type = set,
    from = User,
    to = PeerJID,
    id = randoms:get_string(),
    sub_els = [Payload]},
  ejabberd_router:route_iq(IQ1, HandleResponse).



%%--------------------------------------------------------------------
%% Register/unregister hooks.
%%--------------------------------------------------------------------
-spec register_hooks(binary()) -> ok.
register_hooks(Host) ->
  ejabberd_hooks:add(remove_user, Host, ?MODULE, remove_user, 60),
  ejabberd_hooks:add(disco_local_features, Host, ?MODULE,
    disco_features, 50),
  ejabberd_hooks:add(disco_sm_features, Host, ?MODULE,
    disco_features, 50).

-spec unregister_hooks(binary()) -> ok.
unregister_hooks(Host) ->
  ejabberd_hooks:delete(remove_user, Host, ?MODULE, remove_user, 60),
  ejabberd_hooks:delete(disco_local_features, Host, ?MODULE,
    disco_features, 50),
  ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE,
    disco_features, 50).

%%--------------------------------------------------------------------
%% IQ handlers.
%%--------------------------------------------------------------------
-spec register_iq_handlers(binary()) -> ok.
register_iq_handlers(Host) ->
  gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_XABBER_REWRITE,
    ?MODULE, pre_process_iq).

-spec unregister_iq_handlers(binary()) -> ok.
unregister_iq_handlers(Host) ->
  gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_XABBER_REWRITE).


%%--------------------------------------------------------------------
%% SQL
%%--------------------------------------------------------------------

sql_find_original(#jid{luser = User, lserver = Server}, Peer, ID) ->
  try binary_to_integer(ID) of
    Timestamp when Timestamp >= 0 ->
      Conversation = jid:encode(jid:tolower(Peer)),
      case ejabberd_sql:sql_query(Server, ?SQL(
        "select @(xml)s,@(origin_id)s from archive where username=%(User)s "
        "and %(Server)H and bare_peer=%(Conversation)s and timestamp=%(Timestamp)d")) of
        {selected, [{XML, OriginID}]} -> {ok, XML, OriginID};
        {selected, []} -> not_found;
        _ -> error
      end;
    _ -> error
  catch error:badarg -> error
  end.

sql_find_peer_message(#jid{luser = User, lserver = Server}, Peer, ID, OID) ->
  Conversation = jid:encode(jid:tolower(Peer)),
  case ejabberd_sql:sql_query(Server, ?SQL(
    "select @(timestamp)d,@(xml)s from archive where username=%(User)s and %(Server)H "
    "and bare_peer=%(Conversation)s and foreign_id=%(ID)s")) of
    {selected, [{Timestamp, XML}]} -> {ok, Timestamp, XML};
    {selected, []} -> sql_find_peer_origin(Server, User, Conversation, OID);
    _ -> error
  end.

sql_find_peer_origin(_Server, _User, _Conversation, undefined) -> not_found;
sql_find_peer_origin(_Server, _User, _Conversation, #origin_id{id = <<>>}) -> not_found;
sql_find_peer_origin(Server, User, Conversation, #origin_id{id = OriginID}) ->
  case ejabberd_sql:sql_query(Server, ?SQL(
    "select @(timestamp)d,@(xml)s from archive where username=%(User)s and %(Server)H "
    "and bare_peer=%(Conversation)s and origin_id=%(OriginID)s")) of
    {selected, [{Timestamp, XML}]} -> {ok, Timestamp, XML};
    {selected, []} -> not_found;
    _ -> error
  end.

sql_get_query(_Server, _Username, _Version, _CurrentVer, []) ->
  [];
sql_get_query(Server, Username, Version, CurrentVer, ConvList) ->
  case ejabberd_sql:sql_query(Server,
    ?SQL("SELECT @(created)d,@(xml)s FROM message_rewrite"
    " where username=%(Username)s and version > %(Version)d and version <= %(CurrentVer)d "
    " and %(Server)H and (conversation, type) IN (%(ConvList)lss) "
    " order by version")) of
    {selected, Query} -> Query;
    _ -> []
  end.

sql_get_archive_event(Server, Username, Version, CurrentVer) ->
  case ejabberd_sql:sql_query(Server, ?SQL(
    "select @(created)d,@(xml)s from message_rewrite where username=%(Username)s "
    "and %(Server)H and version > %(Version)d and version <= %(CurrentVer)d "
    "and event_type='retract-archive' "
    "order by version desc limit 1")) of
    {selected, [{Created, XML}]} -> {ok, Created, XML};
    _ -> error
  end.

sql_retract_local_message(Server, Username, Conversation, Timestamp, Version, XML) ->
  ejabberd_sql:sql_transaction(Server, fun() ->
    case ejabberd_sql:sql_query_t(?SQL(
      "select @(conversation_type)s from archive where username=%(Username)s "
      "and %(Server)H and bare_peer=%(Conversation)s and timestamp=%(Timestamp)d "
      "for update")) of
      {selected, []} -> not_found;
      {selected, [{Type}]} ->
        {updated, 1} = ejabberd_sql:sql_query_t(?SQL(
          "delete from archive where username=%(Username)s and %(Server)H "
          "and timestamp=%(Timestamp)d")),
        sql_store_event(Server, Username, Conversation, Type, Version, XML,
          <<"retract-message">>),
        {ok, Type}
    end
  end).

sql_replace_message(Server, Username, Conversation, Timestamp, OldXML,
    XML, Text, Tags, Version, EventXML) ->
  ejabberd_sql:sql_transaction(Server, fun() ->
    case ejabberd_sql:sql_query_t(?SQL(
      "select @(conversation_type)s from archive where username=%(Username)s "
      "and %(Server)H and bare_peer=%(Conversation)s and timestamp=%(Timestamp)d "
      "and xml=%(OldXML)s for update")) of
      {selected, []} -> not_found;
      {selected, [{Type}]} ->
        {updated, 1} = ejabberd_sql:sql_query_t(?SQL(
          "update archive set xml=%(XML)s, txt=%(Text)s, tags=%(Tags)as "
          "where username=%(Username)s and %(Server)H and timestamp=%(Timestamp)d")),
        sql_store_event(Server, Username, Conversation, Type, Version, EventXML, <<"replace">>),
        {ok, Type}
    end
  end).

sql_retract_conversation(Server, Username, Conversation, <<>>, Version, XML) ->
  ejabberd_sql:sql_transaction(Server, fun() ->
    ejabberd_sql:sql_query_t(?SQL(
      "delete from archive where username=%(Username)s and %(Server)H "
      "and bare_peer=%(Conversation)s")),
    ejabberd_sql:sql_query_t(?SQL(
      "delete from message_rewrite where username=%(Username)s and %(Server)H "
      "and conversation=%(Conversation)s and version < %(Version)d")),
    sql_store_event(Server, Username, Conversation, ?REWRITE_ALL_TYPES, Version, XML,
      <<"retract-all">>)
  end);
sql_retract_conversation(Server, Username, Conversation, Type, Version, XML) ->
  ejabberd_sql:sql_transaction(Server, fun() ->
    ejabberd_sql:sql_query_t(?SQL(
      "delete from archive where username=%(Username)s and %(Server)H "
      "and bare_peer=%(Conversation)s and conversation_type=%(Type)s")),
    ejabberd_sql:sql_query_t(?SQL(
      "delete from message_rewrite where username=%(Username)s and %(Server)H "
      "and conversation=%(Conversation)s and type=%(Type)s and version < %(Version)d")),
    sql_store_event(Server, Username, Conversation, Type, Version, XML,
      <<"retract-all">>)
  end).

sql_retract_archive(Server, Username, Version, XML) ->
  ejabberd_sql:sql_transaction(Server, fun() ->
    ejabberd_sql:sql_query_t(?SQL(
      "delete from archive where username=%(Username)s and %(Server)H")),
    ejabberd_sql:sql_query_t(?SQL(
      "delete from message_rewrite where username=%(Username)s and %(Server)H "
      "and version < %(Version)d")),
    sql_store_event(Server, Username, <<>>, ?REWRITE_ARCHIVE, Version, XML,
      <<"retract-archive">>)
  end).

sql_store_event(Server, Username, Conversation, Type, Version, XML, EventType) ->
  Created = erlang:system_time(microsecond),
  {updated, 1} = ejabberd_sql:sql_query_t(?SQL_INSERT(
    "message_rewrite", ["username=%(Username)s", "server_host=%(Server)s",
    "xml=%(XML)s", "version=%(Version)d", "conversation=%(Conversation)s",
    "type=%(Type)s", "event_type=%(EventType)s", "created=%(Created)d"])),
  ok.

sql_get_version(Server, Username) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select coalesce(max(@(version)d),0) from message_rewrite"
    " where username = %(Username)s and %(Server)H")) of
    {selected,[{Version}]} -> Version;
    {selected,_} -> 0;
    Err ->
      ?ERROR_MSG("failed to get retract version: ~p", [Err]),
      0
  end.

sql_delete_all_events(User, Server) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from message_rewrite where username = %(User)s and %(Server)H")).

sql_get_count_events(Server, Username, Version) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("with latest as (select coalesce(max(version), 0) as current_version "
    "from message_rewrite where username=%(Username)s and %(Server)H) "
    "select @(coalesce(m.conversation, ''))s,@(coalesce(m.type, ''))s,"
    "@(count(m.version))d,"
    "@(count(case when m.event_type = 'retract-all' then 1 end))d,"
    "@(latest.current_version)d from latest left join message_rewrite m "
    "on m.username=%(Username)s and m.server_host=%(Server)s "
    "and m.version > %(Version)d and m.version <= latest.current_version "
    "group by m.conversation, m.type, latest.current_version")) of
    {selected, Rows = [{_, _, _, _, CurrentVer} | _]} ->
      ChatList = [{Conv, Type, Count, ResetCount} ||
        {Conv, Type, Count, ResetCount, _} <- Rows, Count > 0],
      {ok, CurrentVer, ChatList};
    Other -> {error, Other}
  end.
