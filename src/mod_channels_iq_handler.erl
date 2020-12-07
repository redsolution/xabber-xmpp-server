%%%-------------------------------------------------------------------
%%% File    : mod_channels.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Handle iq for channels
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
-module(mod_channels_iq_handler).
-author("andrey.gagarin@redsolution.ru").

-behavior(gen_mod).
-behavior(gen_server).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").

-export([start/2, stop/1, depends/2, mod_options/1, disco_sm_features/5, init/1, handle_call/3, handle_cast/2, terminate/2]).
-export([process_channel_iq/1, process_iq/1]).

%% records
-record(state, {host = <<"">> :: binary()}).

start(Host, Opts) ->
  gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
  gen_mod:stop_child(?MODULE, Host).

depends(_Host, _Opts) ->
  [].

mod_options(_) -> [].

init([Host, _Opts]) ->
  register_iq_handlers(Host),
  register_hooks(Host),
  {ok, #state{host = Host}}.

terminate(_Reason, State) ->
  Host = State#state.host,
  unregister_hooks(Host),
  unregister_iq_handlers(Host).

register_iq_handlers(Host) ->
  gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_CHANNELS, ?MODULE, process_channel_iq),
  gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_CHANNELS_DELETE, ?MODULE, process_channel_iq),
  gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_CHANNELS_CREATE, ?MODULE, process_channel_iq).

unregister_iq_handlers(Host) ->
  gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_CHANNELS),
  gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_CHANNELS_DELETE),
  gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_CHANNELS_CREATE).

register_hooks(Host) ->
  ejabberd_hooks:add(disco_sm_features, Host, ?MODULE, disco_sm_features, 50).

unregister_hooks(Host) ->
  ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE, disco_sm_features, 50).

handle_call(_Request, _From, _State) ->
  erlang:error(not_implemented).

handle_cast({channel_created,LServer,User,Channel,Lang}, State) ->
  ejabberd_hooks:run(channel_created, LServer, [LServer,User,Channel,Lang]),
  {noreply, State};
handle_cast(_Request, State) ->
  {noreply, State}.

process_iq(#iq{} = IQ) ->
  DecIQ = xmpp:decode_els(IQ),
  process_iq_to_channel(DecIQ).

process_channel_iq(#iq{lang = Lang, from = From, to = To, type = set, sub_els = [#channel_query{xmlns = ?NS_CHANNELS_CREATE, sub_els = SubEls}]} = IQ) ->
  Creator = From#jid.luser,
  LServer = To#jid.lserver,
  Host = From#jid.lserver,
  Result = ejabberd_hooks:run_fold(create_channel, LServer, [], [LServer,Creator,Host,SubEls,Lang]),
  ?INFO_MSG("Got stanza to create channel IQ ~p~nSubELS ~p~nResult ~p~n",[IQ,SubEls,Result]),
  case Result of
    {ok, Query, Channel} ->
      User = jid:to_string(jid:remove_resource(From)),
      Proc = gen_mod:get_module_proc(LServer, ?MODULE),
      gen_server:cast(Proc, {channel_created,LServer,User,Channel,Lang}),
      xmpp:make_iq_result(IQ,Query);
    {error,Err} ->
      xmpp:make_error(IQ,Err);
    _ ->
      xmpp:make_error(IQ, xmpp:err_bad_request())
  end;
process_channel_iq(IQ) ->
  xmpp:make_iq_result(IQ).

process_iq_to_channel(#iq{to = To,type = get, sub_els = [#disco_info{}]} = IQ) ->
  Channel = jid:to_string(jid:tolower(jid:remove_resource(To))),
  LServer = To#jid.lserver,
  case mod_channels:get_channel_info(LServer,Channel) of
    {ok, Info} ->
      {Name,_Index,_Membership,_Description,_Message,_Contacts,_Domains} = Info,
      Identity = #identity{category = <<"conference">>, type = <<"channel">>, name = Name},
      FeatureList = [?NS_AVATAR_METADATA,?NS_AVATAR_DATA,
        <<"jabber:iq:last">>,<<"urn:xmpp:time">>,<<"jabber:iq:version">>,<<"urn:xmpp:avatar:metadata+notify">>,
        ?NS_CHANNELS],
      Q = #disco_info{features = FeatureList, identities = [Identity]},
      ejabberd_router:route(xmpp:make_iq_result(IQ,Q));
    _ ->
      ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_bad_request()))
  end;
process_iq_to_channel(#iq{type = T, sub_els = [#pubsub{}]} = IQ) when T == set orelse T == get ->
  handle_pubsub(IQ);
process_iq_to_channel(#iq{type = T} = IQ) when T == set orelse T == get ->
  ejabberd_router:route(xmpp:make_error(IQ, xmpp:err_bad_request()));
process_iq_to_channel(IQ) ->
  ?DEBUG("Dropping iq ~p",[IQ]).

-spec disco_sm_features({error, stanza_error()} | {result, [binary()]} | empty,
    jid(), jid(), binary(), binary()) ->
  {error, stanza_error()} | {result, [binary()]}.
disco_sm_features({error, Err}, _From, _To, _Node, _Lang) ->
  {error, Err};
disco_sm_features(empty, _From, _To, <<"">>, _Lang) ->
  {result, [?NS_CHANNELS]};
disco_sm_features({result, Feats}, _From, _To, <<"">>, _Lang) ->
  {result, [?NS_CHANNELS|Feats]};
disco_sm_features(Acc, _From, _To, _Node, _Lang) ->
  Acc.

handle_pubsub(#iq{id = Id,type = Type,lang = Lang, meta = Meta, from = From, to = To,sub_els = [#pubsub{publish = Publish}] = SubEls} = IQ) ->
%%  #iq{id = Id,type = Type,lang = Lang, meta = Meta, from = From, to = To,sub_els = [#xmlel{name = <<"pubsub">>,
%%    attrs = [{<<"xmlns">>,<<"http://jabber.org/protocol/pubsub">>}]} ] = Children} = Iq,
  ?INFO_MSG("IQ ~p~n",[IQ]),
  ChannelJID = jid:replace_resource(To,<<"Channel">>),
  NewIq = #iq{from = ChannelJID,to = To,id = Id,type = Type,lang = Lang,meta = Meta,sub_els = SubEls},
  User = jid:to_string(jid:remove_resource(From)),
  Channel = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  Permission = mod_channel_rights:has_right(Server, Channel, User, <<"owner">>),
  #ps_publish{node = Node, items = _Items} = Publish,
  Result = case Permission of
             true ->
               mod_pubsub:iq_sm(NewIq);
             _ ->
               xmpp:err_not_allowed()
           end,
%%  Result = case Node of
%%             <<"urn:xmpp:avatar:data">> when Permission == yes->
%%               mod_pubsub:iq_sm(NewIq);
%%             <<"urn:xmpp:avatar:metadata">> when Permission == yes->
%%               mod_pubsub:iq_sm(NewIq);
%%             _ ->
%%               xmpp:err_bad_request()
%%           end,
  ?INFO_MSG("Result ~p~n",[Result]),
  Result.