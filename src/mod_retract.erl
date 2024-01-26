%%%-------------------------------------------------------------------
%%% File    : mod_retract.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : XEP-RETRACT: Message Delete and Rewrite
%%% Created : 17 May 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_retract).
-author('andrey.gagarin@redsolution.com').
-behaviour(gen_mod).
-behavior(gen_server).
-compile([{parse_transform, ejabberd_sql_pt}]).

-protocol({xep, 'RETRACT', '0.1.0'}).
%% gen_mod callbacks.
-export([start/2,stop/1,reload/3,depends/2,mod_options/1]).

%% ejabberd_hooks callbacks.
-export([disco_sm_features/5, check_iq/1]).

%% gen_iq_handler callback.
-export([process_iq/1, pre_process_iq/1]).

%% gen_server callbacks.
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

-export([
  delete_message/3,
  get_version/2
]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").

-record(state, {host = <<"">> :: binary()}).

-record(rewrite_job,
{
  server_id = <<>>                       :: binary() | '_',
  iq_id = <<>>                           :: binary() | '_',
  message_id = <<>>                      :: binary() | '_',
  usr = {<<>>, <<>>, <<>>}               :: {binary(), binary(), binary()} | '_',
  rewrite_ask = none                     :: rewriteask() | '_',
  xml = undefined                        :: any() | '_',
  type = <<"urn:xabber:chat">>           :: binary() | '_'
}).

-define(RETRACT_DEPTH, 5184000000000). %% Two months
-define(NS_XABBER_CHAT, <<"urn:xabber:chat">>).
-define(NS_OMEMO, <<"urn:xmpp:omemo:2">>).

-type rewriteask() :: none | retract | retractall | rewrite.
%%--------------------------------------------------------------------
%% gen_mod callbacks.
%%--------------------------------------------------------------------
-spec start(binary(), gen_mod:opts()) -> ok.
start(Host, Opts) ->
  gen_mod:start_child(?MODULE, Host, Opts).

-spec stop(binary()) -> ok.
stop(Host) ->
  gen_mod:stop_child(?MODULE, Host).

-spec reload(binary(), gen_mod:opts(), gen_mod:opts()) -> ok.
reload(Host, NewOpts, OldOpts) ->
  NewMod = gen_mod:db_mod(Host, NewOpts, ?MODULE),
  OldMod = gen_mod:db_mod(Host, OldOpts, ?MODULE),
  if NewMod /= OldMod ->
    NewMod:init(Host, NewOpts);
    true ->
      ok
  end.

-spec depends(binary(), gen_mod:opts()) -> [{module(), hard | soft}].
depends(_Host, _Opts) ->
  [].

mod_options(_Host) ->
  [].

%%--------------------------------------------------------------------
%% gen_server callbacks.
%%--------------------------------------------------------------------
init([Host, _Opts]) ->
  update_tables(),
  ejabberd_mnesia:create(?MODULE, rewrite_job,
    [{disc_only_copies, [node()]},
      {attributes, record_info(fields, rewrite_job)}]),
  register_iq_handlers(Host),
  register_hooks(Host),
  {ok, #state{host = Host}}.

terminate(_Reason, State) ->
  Host = State#state.host,
  unregister_hooks(Host),
  unregister_iq_handlers(Host).

handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast({From, #iq{id = IQID, sub_els = [El]} = IQ}, State) ->
  {Ask, StanzaID, XML, CType} =
    case El of
      #xabber_retract_message{id = ID, type = T} ->
        {retract, ID, [], check_type(T)};
      #xabber_replace{id = ID, type = T,
        xabber_replace_message = M} ->
        {rewrite, ID, M, check_type(T)}
    end,
  LJID = jid:tolower(From),
  NewID = randoms:get_alphanum_string(32),
  NewIQ = IQ#iq{id = NewID},
  set_rewrite_job(NewID, Ask, LJID, StanzaID, IQID, XML, CType),
  ejabberd_router:route(NewIQ),
  {noreply, State};
handle_cast(#iq{from = From, type = Type, id = ID} = IQ, State) ->
  case retrieve_job(ID) of
    #rewrite_job{usr = Usr, iq_id = IQID} when Type == error ->
      ?DEBUG("Got retract error ~p",[IQ]),
      FullJID = jid:make(Usr),
      NewIQ = IQ#iq{id = IQID, to = FullJID},
      ejabberd_router:route(NewIQ);
    #rewrite_job{message_id = StanzaID, rewrite_ask = Ask,
      usr = {LUser, LServer, LResource}} = Job ->
      ?DEBUG("Start ~p message ~p for ~s@~s/~s ",[Ask,
        StanzaID, LUser, LServer, LResource]),
      start_rewrite_job(Job, From);
    _ ->
      ok
  end,
  {noreply, State};
handle_cast(_Msg, State) ->
  ?DEBUG("Drop packet",[]),
  {noreply, State}.

handle_info({mnesia_system_event, {mnesia_down, _Node}}, State) ->
  mnesia:clear_table(rewrite_job),
  {noreply, State};
handle_info(_Info, State) ->
  {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%--------------------------------------------------------------------
%% Service discovery.
%%--------------------------------------------------------------------
-spec disco_sm_features(empty | {result, [binary()]} | {error, stanza_error()},
    jid(), jid(), binary(), binary())
      -> {result, [binary()]} | {error, stanza_error()}.
disco_sm_features(empty, From, To, Node, Lang) ->
  disco_sm_features({result, [?NS_XABBER_REWRITE]}, From, To, Node, Lang);
disco_sm_features({result, OtherFeatures}, _From, _To, <<"">>, _Lang) ->
  {result, [?NS_XABBER_REWRITE | OtherFeatures]};
disco_sm_features(Acc, _From, _To, _Node, _Lang) ->
  Acc.

%%--------------------------------------------------------------------
%% Register/unregister hooks.
%%--------------------------------------------------------------------
-spec register_hooks(binary()) -> ok.
register_hooks(Host) ->
  ejabberd_hooks:add(s2s_receive_packet, Host, ?MODULE,
    check_iq, 30),
  ejabberd_hooks:add(disco_local_features, Host, ?MODULE,
    disco_sm_features, 50),
  ejabberd_hooks:add(disco_sm_features, Host, ?MODULE,
    disco_sm_features, 50).

-spec unregister_hooks(binary()) -> ok.
unregister_hooks(Host) ->
  ejabberd_hooks:delete(s2s_receive_packet, Host, ?MODULE,
    check_iq, 10),
   ejabberd_hooks:delete(disco_local_features, Host, ?MODULE,
    disco_sm_features, 50),
  ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE,
    disco_sm_features, 50).

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

pre_process_iq(#iq{to = To} = IQ) ->
  LUser = To#jid.luser,
  LServer = To#jid.lserver,
  case mod_xabber_entity:get_entity_type(LUser,LServer) of
    group -> mod_groups_iq_handler:make_action(IQ);
    channel -> mod_channels_iq_handler:process_iq(IQ);
    _ -> process_iq(IQ)
  end.

-spec process_iq(iq()) -> iq().
process_iq(#iq{type = set, lang = Lang, sub_els = [#xabber_retract_query{}]} = IQ) ->
  Txt = <<"Value 'set' of 'type' attribute is not allowed">>,
  xmpp:make_error(IQ, xmpp:err_not_allowed(Txt, Lang));
%% Query the current version
process_iq(#iq{from = From, type = get, sub_els = [#xabber_retract_query{version = undefined}]} = IQ) ->
  {LUser, LServer, _LResource} = jid:tolower(From),
  Version = get_version(LServer, LUser),
  xmpp:make_iq_result(IQ, #xabber_retract_query{version = Version});
process_iq(#iq{from = From, type = get, sub_els = [
  #xabber_retract_query{version = Version, 'less-than' = Less0}]} = IQ) ->
  Less = if
           Less0 > 50 orelse Less0 == undefined -> 50;
           true -> Less0
         end,
  {LUser, LServer, _LResource} = jid:tolower(From),
  ChatList = get_count_events(LServer, LUser, Version),
  send_retract_query_messages(From, Version, Less, ChatList),
  LastVersion = get_version(LServer, LUser),
  xmpp:make_iq_result(IQ, #xabber_retract_query{version = LastVersion});
process_iq(#iq{type = set, sub_els = [#xabber_retract_message{id = undefined}]} = IQ) ->
  xmpp:make_error(IQ, xmpp:err_bad_request());
process_iq(#iq{type = set, sub_els = [#xabber_retract_message{type = <<>>}]} = IQ) ->
  xmpp:make_error(IQ, xmpp:err_bad_request());
process_iq(#iq{from = From, to = To, type = set, sub_els = [
  #xabber_retract_message{symmetric = false, id = StanzaID, type = CType}]} = IQ) ->
  case jid:remove_resource(From) of
    To ->
      LUser = To#jid.luser,
      LServer = To#jid.lserver,
      case get_bare_peer(LServer,LUser,StanzaID) of
        not_found ->
          xmpp:make_error(IQ, xmpp:err_item_not_found());
        PeerS ->
          PeerJID = jid:from_string(PeerS),
          Version = get_version(LServer, LUser) + 1,
          Retract = #xabber_retract_message{id = StanzaID, conversation = PeerJID,
            symmetric = false, version = Version, type = check_type(CType),
            xmlns = ?NS_XABBER_REWRITE_NOTIFY},
          start_retract_message(LUser, LServer, StanzaID, IQ, Retract, Version)
      end;
    _ ->
      xmpp:make_error(IQ, xmpp:err_not_allowed())
  end;
process_iq(#iq{from = From, to = To, type = set, sub_els = [
  #xabber_retract_message{symmetric = true, id = StanzaID, type = CTRaw}]} = IQ) ->
  CType = check_type(CTRaw),
  LUser = To#jid.luser,
  LServer = To#jid.lserver,
  IsToMyself = (jid:remove_resource(To) == jid:remove_resource(From)),
  if
    From#jid.lresource == <<>> andalso From#jid.lserver =/= LServer ->
      BarePeer = jid:to_string(jid:remove_resource(From)),
      case get_our_stanza_id(LServer, LUser, BarePeer, StanzaID) of
        not_found ->
          ?DEBUG("Not found ~p ~p~n iq~p",[BarePeer,StanzaID,IQ]),
          xmpp:make_iq_result(IQ);
        error ->
          ?DEBUG("Unknow error during retract ~p",[IQ]),
          xmpp:make_error(IQ, xmpp:err_internal_server_error());
        OurStanzaID ->
          Version = get_version(LServer,LUser) + 1,
          OurRetractAsk = #xabber_retract_message{
%%            by = OurUserJID,
            conversation = From,
            id = OurStanzaID,
            version = Version,
            type = CType,
            xmlns = ?NS_XABBER_REWRITE_NOTIFY},
          ?DEBUG("Delete message ~p in chat ~p by ~p~n Retract ~p",
            [StanzaID,jid:to_string(To),BarePeer,OurRetractAsk]),
          start_retract_message(LUser, LServer, OurStanzaID, IQ, OurRetractAsk, Version)
      end;
    IsToMyself ->
      PeerString = get_bare_peer(LServer,LUser,StanzaID),
      case PeerString of
        not_found ->
          ?DEBUG("Not found ",[]),
          xmpp:make_error(IQ, xmpp:err_item_not_found());
        _ ->
          PeerJID = jid:from_string(PeerString),
          case PeerJID#jid.lserver of
            LServer ->
              start_local_retract(LUser,PeerJID#jid.luser,LServer,StanzaID,IQ, CType);
            _ ->
              IQS = xmpp:set_from_to(IQ,jid:remove_resource(From),PeerJID),
              Proc = gen_mod:get_module_proc(LServer, ?MODULE),
              gen_server:cast(Proc, {From,IQS}),
              ignore
          end
      end;
    true ->
      ?ERROR_MSG("Bad symmetric retract:~p",[IQ]),
      xmpp:make_error(IQ, xmpp:err_bad_request())
  end;
process_iq(#iq{type = set, sub_els = [#xabber_retract_all{ type = <<>>}]} = IQ) ->
  xmpp:make_error(IQ, xmpp:err_bad_request());
process_iq(#iq{from = From, to = To, type = set, sub_els = [
  #xabber_retract_all{conversation = RetractUserJID, symmetric = false, type = CType}]} = IQ) ->
  case (jid:remove_resource(To) == jid:remove_resource(From)) of
    true ->
      LServer = From#jid.lserver,
      LUser = From#jid.luser,
      Version = get_version(LServer,LUser) + 1,
      NewRetractAsk = #xabber_retract_all{type = check_type(CType),
        conversation = RetractUserJID,
        version = Version, xmlns = ?NS_XABBER_REWRITE_NOTIFY},
      start_retract_all_message(LUser, LServer, IQ, NewRetractAsk, Version);
    _ ->
      xmpp:make_error(IQ, xmpp:err_bad_request())
  end;
process_iq(#iq{type = set,sub_els = [#xabber_replace{id = undefined}]} = IQ)->
  xmpp:make_error(IQ, xmpp:err_bad_request());
process_iq(#iq{type = set,sub_els = [#xabber_replace{type = <<>>}]} = IQ)->
  xmpp:make_error(IQ, xmpp:err_bad_request());
process_iq(#iq{from = From,to = To, type = set, sub_els = [
  #xabber_replace{id = StanzaID, xabber_replace_message = Message, type = CTRaw}]} = IQ) ->
  CType = check_type(CTRaw),
  LUser = To#jid.luser,
  LServer = To#jid.lserver,
  case jid:tolower(From) of
    {_, S, <<>>} when S /= LServer ->
      %% S2S query
      BarePeer = jid:to_string(From),
      case get_our_stanza_id(LServer, LUser, BarePeer, StanzaID) of
        not_found ->
          ?DEBUG("Not found ~p ~p~n iq~p",[BarePeer,StanzaID,IQ]),
          xmpp:make_error(IQ, xmpp:err_item_not_found());
        error ->
          ?DEBUG("Unknow error during retract ~p",[IQ]),
          xmpp:make_error(IQ, xmpp:err_internal_server_error());
        OurStanzaID ->
          Version = get_version(LServer, LUser) + 1,
          Replaced = #replaced{stamp = erlang:timestamp()},
          NewMessage = Message#xabber_replace_message{replaced = Replaced},
          OurReplaceAsk = #xabber_replace{
            type = CType, xmlns = ?NS_XABBER_REWRITE_NOTIFY,
            conversation = From,
            id = OurStanzaID, version = Version,
            xabber_replace_message = NewMessage},
          start_rewrite_message(LUser, LServer, OurStanzaID, IQ, OurReplaceAsk, Version)
      end;
    {LUser, LServer, _} ->
      %% C2S query
      PeerString = get_bare_peer(LServer, LUser, StanzaID),
      PeerJID = jid:from_string(PeerString),
      {PUser, PServer, _} = jid:tolower(PeerJID),
      case PServer of
        LServer when LUser == PUser ->
          %% replace saved(message to yourself) message
          replace_saved_msg(LUser,LServer,StanzaID,Message,IQ);
        LServer ->
          start_local_replace(LUser,PUser,LServer,StanzaID,Message,IQ, CType);
        _ ->
          IQS = xmpp:set_from_to(IQ,To,PeerJID),
          Proc = gen_mod:get_module_proc(LServer, ?MODULE),
          gen_server:cast(Proc, {From,IQS}),
          ignore
      end;
    _ ->
      xmpp:make_error(IQ, xmpp:err_not_allowed())
  end;
process_iq(IQ) ->
  ?DEBUG("IQ ~p",[IQ]),
  xmpp:make_error(IQ, xmpp:err_not_allowed()).

start_local_replace(User1,User2,LServer,StanzaID,Message,IQ,Type) ->
  User1JID = jid:make(User1,LServer),
  User2JID = jid:make(User2,LServer),
  User1JIDS = jid:to_string(User1JID),
  case get_our_stanza_id(LServer, User2, User1JIDS, StanzaID) of
    not_found ->
      ?DEBUG("Not found ~p ~p",[StanzaID,IQ]),
      xmpp:make_error(IQ, xmpp:err_item_not_found());
    error ->
      ?DEBUG("Unknow error during rewrite ~p",[IQ]),
      xmpp:make_error(IQ, xmpp:err_item_not_found());
    OurStanzaID ->
      Replaced = #replaced{stamp = erlang:timestamp()},
      NewMessage = Message#xabber_replace_message{replaced = Replaced},
      User1Version = get_version(LServer, User1) + 1,
      RetractAskUser1 = #xabber_replace{
        xabber_replace_message = NewMessage,
        type = Type,
        xmlns = ?NS_XABBER_REWRITE_NOTIFY,
        conversation = User2JID,
        version = User1Version,
        id = StanzaID},
      User2Version = get_version(LServer, User2) + 1,
      RetractAskUser2 = #xabber_replace{
        xabber_replace_message = NewMessage,
        type = Type,
        xmlns = ?NS_XABBER_REWRITE_NOTIFY,
        conversation = User1JID,
        version = User2Version,
        id = OurStanzaID},
      case replace_message(RetractAskUser2, User2, LServer, OurStanzaID,
        User2Version) of
        ok ->
          start_rewrite_message(User1, LServer, StanzaID, IQ, RetractAskUser1, User1Version);
        _ ->
          xmpp:make_error(IQ, xmpp:err_not_allowed())
      end
  end.

replace_saved_msg(LUser, LServer, StanzaID, Message, IQ) ->
  Version = get_version(LServer, LUser) + 1,
  Replaced = #replaced{stamp = erlang:timestamp()},
  NewMessage = Message#xabber_replace_message{replaced = Replaced},
  RetractAsk = #xabber_replace{
    xabber_replace_message = NewMessage,
    type = ?NS_XABBER_CHAT,
    xmlns = ?NS_XABBER_REWRITE_NOTIFY,
    conversation = jid:make(LUser, LServer),
    version = Version,
    id = StanzaID},
  start_rewrite_message(LUser, LServer, StanzaID, IQ, RetractAsk, Version).

start_local_retract(User1,User2,LServer,StanzaID,IQ, Type) ->
  User1JID = jid:make(User1,LServer),
  User2JID = jid:make(User2,LServer),
  BarePeer = jid:to_string(User1JID),
  case get_our_stanza_id(LServer, User2, BarePeer, StanzaID) of
    not_found ->
      ?DEBUG("Not found ~p ~p~n iq~p",[BarePeer,StanzaID,IQ]),
      xmpp:make_error(IQ, xmpp:err_item_not_found());
    error ->
      ?DEBUG("Unknow error during retract ~p",[IQ]),
      xmpp:make_error(IQ, xmpp:err_item_not_found());
    OurStanzaID ->
      User1Version = get_version(LServer, User1) + 1,
      RetractAskUser1 = #xabber_retract_message{
%%        by = User1JID,
        type = Type,
        xmlns = ?NS_XABBER_REWRITE_NOTIFY,
        conversation = User2JID,
        version = User1Version,
        id = StanzaID},
      User2Version = get_version(LServer, User2) + 1,
      RetractAskUser2 = #xabber_retract_message{
%%        by = User2JID,
        type = Type,
        xmlns = ?NS_XABBER_REWRITE_NOTIFY,
        conversation = User1JID,
        version = User2Version,
        id = OurStanzaID},
      case retract_message(RetractAskUser2, User2, LServer, OurStanzaID,
        User2Version) of
        ok ->
          start_retract_message(User1, LServer, StanzaID, IQ, RetractAskUser1,
            User1Version);
        {error, not_found} ->
          xmpp:make_error(IQ, xmpp:err_item_not_found());
        _ ->
          xmpp:make_error(IQ, xmpp:err_internal_server_error())
      end
  end.


start_rewrite_message(LUser, LServer, StanzaID, IQ, RetractAsk, Version) ->
  ?DEBUG("Start rewrite~p~nIQ ~p~n USER ~p~n StanzaID ~p~n Server ~p",
    [RetractAsk,IQ,LUser,StanzaID,LServer]),
  case replace_message(RetractAsk,LUser, LServer, StanzaID, Version) of
    ok ->
      ?DEBUG("SUCCESS REPLACE ~p~n IQ ~p ",[StanzaID,IQ]),
      xmpp:make_iq_result(IQ);
    {error, not_found} ->
      xmpp:make_error(IQ, xmpp:err_item_not_found());
    _ ->
      xmpp:make_error(IQ, xmpp:err_bad_request())
  end.

start_retract_message(LUser, LServer, StanzaID, IQ, RetractAsk, Version) ->
  ?DEBUG("Start retact ~p~nIQ ~p~n USER ~p~n StanzaID ~p~n Server ~p",[RetractAsk,IQ,LUser,StanzaID,LServer]),
  case retract_message(RetractAsk, LUser, LServer, StanzaID, Version) of
    ok ->
      ?DEBUG("SUCCESS RETRACT ~p~n IQ ~p ",[StanzaID,IQ]),
      xmpp:make_iq_result(IQ);
    {error, not_found} ->
      xmpp:make_error(IQ, xmpp:err_item_not_found());
    _ ->
      xmpp:make_error(IQ, xmpp:err_internal_server_error())
  end.

start_retract_all_message(LUser, LServer, IQ, RetractAsk, Version) ->
  case delete_all_message(RetractAsk, LUser, LServer, Version) of
    ok ->
      ?DEBUG("retract all ~p",[RetractAsk]),
      xmpp:make_iq_result(IQ);
    _ ->
      xmpp:make_error(IQ, xmpp:err_internal_server_error())
  end.

start_rewrite_job(#rewrite_job{rewrite_ask = rewrite, message_id = StanzaID,
  usr = {LUser, LServer, LResource}, iq_id = IQID, xml = Message, type = CType}, From) ->
  Replaced = #replaced{stamp = erlang:timestamp()},
  RMessage = Message#xabber_replace_message{replaced = Replaced},
  BareJID = jid:make(LUser,LServer),
  JID = jid:make(LUser,LServer,LResource),
  Version = get_version(LServer, LUser) + 1,
  RetractAsk = #xabber_replace{xabber_replace_message = RMessage,
    id = StanzaID, by = BareJID, conversation = From, version = Version,
    xmlns = ?NS_XABBER_REWRITE_NOTIFY, type = CType},
  IQ = #iq{id = IQID, type = set, to = BareJID, from = JID},
  NewIQ = case replace_message(RetractAsk, LUser, LServer, StanzaID, Version) of
            ok ->
              xmpp:make_iq_result(IQ);
            {error, not_found} ->
              xmpp:make_error(IQ, xmpp:err_item_not_found());
            _ ->
              xmpp:make_error(IQ, xmpp:err_bad_request())
          end,
  ?DEBUG("got result of replace ~p",[NewIQ]),
  ejabberd_router:route(NewIQ);
start_rewrite_job(#rewrite_job{rewrite_ask = retract, message_id = StanzaID,
  usr = {LUser, LServer, LResource}, iq_id = IQID, type = CType}, _From) ->
  BareJID = jid:make(LUser,LServer),
  JID = jid:make(LUser,LServer,LResource),
  BarePeer = get_bare_peer(LServer,LUser,StanzaID),
  Version = get_version(LServer, LUser) + 1,
  RetractAsk = #xabber_retract_message{by = BareJID, id = StanzaID,
    conversation = jid:from_string(BarePeer), version = Version,
    xmlns = ?NS_XABBER_REWRITE_NOTIFY, type = CType},
  IQ = #iq{id = IQID, type = set, to = BareJID, from = JID},
  NewIQ = case retract_message(RetractAsk, LUser, LServer,
    StanzaID, Version) of
            ok -> xmpp:make_iq_result(IQ);
            {error, not_found} ->
              xmpp:make_error(IQ, xmpp:err_item_not_found());
            _ ->
              xmpp:make_error(IQ, xmpp:err_internal_server_error())
       end,
  ejabberd_router:route(NewIQ);
start_rewrite_job(Job, _From) ->
  ?ERROR_MSG("Unsupported job: ~p",[Job]).
%%start_rewrite_job(retractall, LUser, LServer, LResource, Type, IQID, From) ->
%%  BareJID = jid:make(LUser,LServer),
%%  JID = jid:make(LUser,LServer,LResource),
%%  Version = get_version(LServer, LUser) + 1,
%%  RetractAsk = #xabber_retract_all{conversation = From, type = Type,
%%    version = Version, xmlns = ?NS_XABBER_REWRITE_NOTIFY},
%%  IQ = #iq{id = IQID, type = set, to = BareJID, from = JID},
%%  ?DEBUG("Start delete all message for ~p in chat ~p",[LUser,From]),
%%  NewIQ = start_retract_all_message(LUser, LServer, IQ, RetractAsk, Version),
%%  ?DEBUG("Result of hook ~p",[NewIQ]),
%%  ejabberd_router:route(NewIQ).

delete_all_message(RewriteAsk, LUser, LServer, Ver) ->
  #xabber_retract_all{conversation = Conv, type = TypeRaw} = RewriteAsk,
  BarePeer = jid:to_string(Conv),
  Type = case TypeRaw of
           <<>> -> ?NS_XABBER_CHAT;
           _ -> TypeRaw
         end,
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from archive where conversation_type=%(Type)s "
    " and bare_peer=%(BarePeer)s and username=%(LUser)s "
    " and %(LServer)H")) of
    {updated,_} ->
      store_event(RewriteAsk, LUser, LServer, Ver),
      notify(RewriteAsk, LUser, LServer),
      ok;
    Err ->
      ?ERROR_MSG("Error during delete",[Err]),
      {error, db_error}
  end.

get_message(LUser, LServer, StanzaID) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(xml)s from archive where timestamp=%(StanzaID)d "
    " and username=%(LUser)s and %(LServer)H")) of
    {selected,[{XML}]} ->
      xmpp:decode(fxml_stream:parse_element(XML));
    _ ->
      not_found
  end.

retract_message(RewriteAsk, LUser, LServer, StanzaID, Ver) ->
  case delete_message(LServer, LUser, StanzaID) of
    ok ->
      store_event(RewriteAsk, LUser, LServer, Ver),
      notify(RewriteAsk, LUser, LServer),
      ok;
    Err ->
      Err
  end.


replace_message(RewriteAsk, LUser, LServer, StanzaID, Version) ->
  case get_message(LUser, LServer, StanzaID) of
    not_found -> {error, not_found};
    Msg ->
      Replace = do_replace_message(Msg, RewriteAsk, LUser, LServer, StanzaID),
      store_event(Replace, LUser, LServer, Version),
      notify(Replace, LUser, LServer),
      ok
  end.

do_replace_message(OldMessage, RewriteAsk, LUser, LServer, StanzaID) ->
%%  todo: update message tags after replacement
  #xabber_replace{xabber_replace_message = ReplaceMessage} = RewriteAsk,
  Sub = ReplaceMessage#xabber_replace_message.sub_els,
  Lang = xmpp:get_lang(OldMessage),
  SubEls = xmpp:get_els(OldMessage),
  Replaced = ReplaceMessage#xabber_replace_message.replaced,
  NewEls = filter_old_els(SubEls) ++ filter_new_els(Sub),
  NewTXT = ReplaceMessage#xabber_replace_message.body,
  NewMessage = OldMessage#message{body = [#text{data = NewTXT,lang = Lang}], sub_els = NewEls ++ [Replaced]},
  NewXML = fxml:element_to_binary(xmpp:encode(NewMessage)),
  NewElsWithAll = set_stanza_id(NewEls,jid:make(LUser,LServer), StanzaID),
  NewReplaceMessage = ReplaceMessage#xabber_replace_message{sub_els = NewElsWithAll},
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("update archive set xml = %(NewXML)s, txt = %(NewTXT)s "
    " where timestamp=%(StanzaID)d and username=%(LUser)s and %(LServer)H")),
  RewriteAsk#xabber_replace{xabber_replace_message = NewReplaceMessage}.

store_event(RewriteAsk, LUser, LServer, Ver) ->
  XML = fxml:element_to_binary(xmpp:encode(RewriteAsk)),
  {Type, Conv} = get_conv(RewriteAsk),
  insert_event(LServer, LUser, XML, Ver, Conv, Type).

notify(Payload, LUser, LServer) ->
  BareJID = jid:make(LUser,LServer),
  Message = #message{id = randoms:get_string(), type = headline,
    from = BareJID, to = BareJID, sub_els = [Payload]},
  ejabberd_router:route(Message).

get_conv(#xabber_replace{conversation = C, type = T}) ->
  get_conv(T, C);
get_conv(#xabber_retract_message{conversation = C, type = T}) ->
  get_conv(T, C);
get_conv(#xabber_retract_all{conversation = C, type = T}) ->
  get_conv(T, C);
get_conv(_Type) ->
  {<<>>, <<>>}.

get_conv(<<>>,<<>>) ->
  {<<>>, <<>>};
get_conv(Type, JID) ->
  {Type, jid:to_string(jid:remove_resource(JID))}.

send_retract_query_messages(User, Version, Less, ChatList) ->
  {LUser, LServer, _LResource} = jid:tolower(User),
  Msg = #message{from = jid:remove_resource(User), to = User, type = headline},
  DropArchiveChats = lists:filter(
    fun({_, _, Count}) -> Count > Less end, ChatList),
  NotifyChats = ChatList -- DropArchiveChats,
  RetractNotifications = get_query(LServer, LUser, Version, NotifyChats),
  Msgs1 = lists:map(fun({TS, Element}) ->
    Event = fxml_stream:parse_element(Element),
    Delay = #delay{stamp = misc:usec_to_now(TS)},
    Msg#message{id= randoms:get_string(), sub_els = [Event, Delay]}
                      end, RetractNotifications),
  Msgs2 = lists:map(fun({Conv, CType, _}) ->
    Invalidate = #xabber_retract_invalidate{version = Version,
      conversation = jid:from_string(Conv),
      type = CType},
    Msg#message{id= randoms:get_string(), sub_els = [Invalidate]}
                    end, DropArchiveChats),

  lists:foreach(fun(M) -> ejabberd_router:route(M) end, Msgs1 ++ Msgs2).

%% sql functions

get_bare_peer(LServer,LUser,ID) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(bare_peer)s from archive where timestamp=%(ID)d "
    " and username=%(LUser)s and %(LServer)H")) of
    {selected,[]} ->
      not_found;
    {selected,[{}]} ->
      not_found;
    {selected,[{Peer}]} ->
      Peer;
    _ ->
      not_found
  end.

get_count_events(Server, Username, Version) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(conversation)s,@(type)s,@(count(*))d from message_retract "
    " where username = %(Username)s and version > %(Version)d "
    " and %(Server)H group by conversation, type")) of
    {selected, Count} ->
      Count;
    _->
      []
  end.

get_query(_Server, _Username, _Version, []) ->
  [];
get_query(Server, Username, Version, ChatList) ->
  ConvList = [<<C/binary,T/binary>> || {C, T, _} <- ChatList],
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("WITH retract_archive AS "
    " (SELECT conversation||type as cid,"
    " created,xml,version FROM message_retract"
    " where username=%(Username)s and version > %(Version)d "
    " and %(Server)H)"
    " SELECT @(created)d,@(xml)s FROM retract_archive "
    " where cid = ANY(%(ConvList)as) order by version")) of
    {selected,Query} ->
      Query;
    _ -> []
  end.

get_version(Server, Username) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select coalesce(max(@(version)d),0) from message_retract"
     " where username = %(Username)s and %(Server)H")) of
    {selected,[{Version}]} -> Version;
    {selected,_} -> 0;
    Err ->
      ?ERROR_MSG("failed to get retract version: ~p", [Err]),
      0
  end.

insert_event(LServer,Username,Txt,Version, Conv, Type) ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL_INSERT(
      "message_retract",
      [ "username=%(Username)s",
        "server_host=%(LServer)s",
        "xml=%(Txt)s",
        "conversation=%(Conv)s",
        "type=%(Type)s",
        "version=%(Version)d"
      ])).

delete_message(LServer, LUser, StanzaID) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from archive where timestamp=%(StanzaID)d "
    " and username=%(LUser)s and %(LServer)H")) of
    {updated,1} ->
      ?DEBUG("Message ~p deleted",[StanzaID]),
      ok;
    {updated,0} ->
      ?DEBUG("No sush message",[]),
      {error, not_found};
    Err ->
      ?ERROR_MSG("Error during delete: ~p",[Err]),
      {error, db_error}
  end.

%% check iq if it's result for us
-spec check_iq({stanza(), ejabberd_s2s_in:state()}) ->
  {stanza(), ejabberd_s2s_in:state()}.
check_iq({#iq{type = Type} = Packet, #{lserver := LServer} = S2SState})
  when Type == error orelse Type == result ->
  Proc = gen_mod:get_module_proc(LServer, ?MODULE),
  gen_server:cast(Proc, Packet),
  {Packet, S2SState};
check_iq({Packet, S2SState}) ->
  {Packet, S2SState}.

%% retract jobs

set_rewrite_job(ServerID, Ask, Usr, StanzaID, IQID, XML, CTypeRaw) ->
  RewriteJob = #rewrite_job{server_id = ServerID, iq_id = IQID, message_id = StanzaID,
    usr = Usr, rewrite_ask = Ask, xml = XML, type = check_type(CTypeRaw)},
  mnesia:dirty_write(RewriteJob).

retrieve_job(ServerID) ->
  FN = fun()->
    case mnesia:read(rewrite_job, ServerID) of
      [] -> error;
      [Job] ->
        mnesia:delete_object(Job),
        Job
    end end,
  {atomic, Job} = mnesia:transaction(FN),
  Job.

%% clean mnesia

update_tables() ->
  try mnesia:table_info(rewrite_job, attributes) of
    Attrs ->
      case lists:member(rewrite_message, Attrs) of
        true -> mnesia:delete_table(rewrite_job);
        _ ->
          mnesia:clear_table(rewrite_job)
      end,
      case lists:member(type, Attrs) of
        false -> mnesia:delete_table(rewrite_job);
        _ ->
          mnesia:clear_table(rewrite_job)
      end
  catch exit:_ -> ok
  end.

get_our_stanza_id(LServer, LUser, ForeignSJID, FID) when is_integer(FID) ->
  get_our_stanza_id(LServer, LUser, ForeignSJID, integer_to_binary(FID));
get_our_stanza_id(LServer, LUser, ForeignSJID, FID) ->
  %% For quickly search in database, we limit the search depth
  Depth = misc:now_to_usec(erlang:now()) - ?RETRACT_DEPTH,
  ForeignIDLike = <<"%<stanza-id %",
    (ejabberd_sql:escape(ejabberd_sql:escape_like_arg_circumflex(FID)))/binary,
    "%/>%">>,
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(timestamp)d,@(xml)s from archive "
    " where username=%(LUser)s and bare_peer=%(ForeignSJID)s "
    " and timestamp > %(Depth)s"
    " and xml like %(ForeignIDLike)s and %(LServer)H")) of
    {selected,[]} ->
      not_found;
    {selected,ValueList} ->
      FJID = jid:from_string(ForeignSJID),
      R = lists:filtermap(fun({TS, XML})->
        Pkt = xmpp:decode(fxml_stream:parse_element(XML)),
        case xmpp:get_subtag(Pkt, #stanza_id{}) of
          #stanza_id{by = FJID, id = FID} -> {true, TS};
          _ -> false
        end end, ValueList),
      case lists:sort(R) of
        [H | _] -> integer_to_binary(H);
        _ -> not_found
      end;
      _ ->
        error
  end.

filter_new_els(Els) ->
  lists:filter(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      IsGroupsNS = str:prefix(?NS_GROUPCHAT, NS),
      if
        (Name == <<"archived">> andalso NS == ?NS_MAM_TMP);
          (Name == <<"time">> andalso NS == ?NS_UNIQUE);
          (Name == <<"origin-id">> andalso NS == ?NS_SID_0);
          (Name == <<"stanza-id">> andalso NS == ?NS_SID_0);
          (Name == <<"x">> andalso IsGroupsNS) ->
          false;
        true ->
          true
      end
    end, Els).

filter_old_els(Els) ->
  lists:filter(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if
        (Name == <<"origin-id">> andalso NS == ?NS_SID_0);
          (Name == <<"stanza-id">> andalso NS == ?NS_SID_0) -> true;
        true -> false
      end
    end, Els).

-spec set_stanza_id(list(), jid(), binary()) -> list().
set_stanza_id(SubELS, JID, ID) ->
  TimeStamp = misc:usec_to_now(binary_to_integer(ID)),
  BareJID = jid:remove_resource(JID),
  Archived = #mam_archived{by = BareJID, id = ID},
  StanzaID = #stanza_id{by = BareJID, id = ID},
  Time = #unique_time{by = BareJID, stamp = TimeStamp},
  [Archived, StanzaID, Time|SubELS].

check_type(<<>>) -> ?NS_XABBER_CHAT;
check_type(Value) -> Value.
