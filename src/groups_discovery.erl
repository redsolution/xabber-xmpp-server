%%%-------------------------------------------------------------------
%%% File    : groups_discovery.erl
%%% Author  : Ilya Kalashnikov <ilya.kalashnikov@redsolution.com>
%%% Purpose : Service Discovery.
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

-module(groups_discovery).
-author('ilya.kalashnikov@redsolution.com').
-compile([{parse_transform, ejabberd_sql_pt}]).
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").

%% gen_mod
-export([start/2, stop/1, reload/3, process_disco_items/1]).
%% API
-export([get_local_items/5, get_local_identity/5, get_local_features/5,
  depends/2, mod_options/1, client_disco_info/1]).


%%====================================================================
%% gen_mod API
%%====================================================================
start(Host, _Opts) ->
  update_groups_caps(Host),
  ejabberd_hooks:add(disco_local_items, Host, ?MODULE,
    get_local_items, 50),
  ejabberd_hooks:add(disco_local_features, Host, ?MODULE,
    get_local_features, 50),
  ejabberd_hooks:add(disco_local_identity, Host, ?MODULE,
    get_local_identity, 50),
  ok.

stop(Host) ->
  ejabberd_hooks:delete(disco_local_identity, Host,
    ?MODULE, get_local_identity, 50),
  ejabberd_hooks:delete(disco_local_features, Host,
    ?MODULE, get_local_features, 50),
  ejabberd_hooks:delete(disco_local_items, Host, ?MODULE,
    get_local_items, 50).

reload(_Host, _NewOpts, _OldOpts) ->
  ok.

depends(_Host, _Opts) ->
  [{mod_adhoc, hard}, {mod_last, soft}].

mod_options(_Host) -> [].

client_disco_info(Privacy) ->
  Notify = case Privacy of
             public -> [ <<"urn:xmpp:avatar:metadata+notify">>,
               <<"http://jabber.org/protocol/nick+notify">>];
             _ -> []
           end,
  I = #identity{name = <<"Xabber Groups component">>,
    category = <<"client">>, type = <<"console">>},
  FL = [?NS_GROUPS,  ?NS_DISCO_INFO, ?NS_REFERENCES, ?NS_CHATSTATES,
    <<"urn:xmpp:chat-markers:0">>, ?NS_XABBER_REWRITE] ++ Notify,
  #disco_info{identities = [I], features = FL}.

get_local_items(Acc, _From, #jid{lserver = LServer} = To,
    <<"">>, _Lang) ->
  case gen_mod:is_loaded(LServer, mod_groups) of
    false -> Acc;
    _ ->
      Items = case Acc of
                {result, Its} -> Its;
                empty -> []
              end,
      DI = #disco_item{jid = To,
        node = ?NS_GROUPS,
        name = <<"Group Service">>},
      {result,Items ++ [DI]}
  end;
get_local_items(Acc, _From, _To, _Node, _Lang) ->
  Acc.

get_local_features(Acc, _From, _To, ?NS_GROUPS, _Lang) ->
  Items = case Acc of
            {result, Its} -> Its;
            empty -> []
          end,
  {result, Items ++[?NS_GROUPS,?NS_DISCO_INFO, ?NS_VCARD,
    ?NS_MAM_TMP, ?NS_MAM_0, ?NS_MAM_1, ?NS_MAM_2]};
get_local_features(Acc, _From, _To, _Node, _Lang) ->
  Acc.

get_local_identity(_Acc, _From, _To, ?NS_GROUPS, _Lang) ->
  [#identity{category = <<"conference">>,
    type = <<"text">>,
    name = <<"Groups Service">>}];
get_local_identity(Acc, _From, _To, _Node, _Lang) ->
  Acc.

-spec process_disco_items(iq()) -> iq().
process_disco_items(#iq{type = set, lang = Lang} = IQ) ->
  Txt = <<"Value 'set' of 'type' attribute is not allowed">>,
  xmpp:make_error(IQ, xmpp:err_not_allowed(Txt, Lang));
process_disco_items(#iq{type = get, from = From, to = To, lang = _Lang,
  sub_els = [#disco_items{node = ?NS_GROUPS, rsm = RSM}]} = IQ) ->
  {User,Host,_} = jid:tolower(From),
  ServerHost = ejabberd_router:host_of_route(To#jid.lserver),
  BareJID = jid:to_string(jid:make(User,Host)),
  {QueryChats, QueryCount} = make_sql_query(ServerHost, BareJID, Host, RSM),
  {selected, _, Res} = ejabberd_sql:sql_query(ServerHost, QueryChats),
  {selected, _, [[CountBinary]]} = ejabberd_sql:sql_query(ServerHost, QueryCount),
  Count = binary_to_integer(CountBinary),
  Items = lists:map(fun(C) ->
    [ChatJID,ChatName] = C,
    JID = jid:from_string(ChatJID),
    #disco_item{jid = JID, name = ChatName} end,
    Res
  ),
  ResRSM = case Items of
             [_|_] when RSM /= undefined ->
               #disco_item{jid = #jid{luser = FirstUser, lserver = FirstServer}} = hd(Items),
               #disco_item{jid = #jid{luser = LastUser, lserver = LastServer}} = lists:last(Items),
               First = jid:to_string(jid:make(FirstUser,FirstServer)),
               Last = jid:to_string(jid:make(LastUser,LastServer)),
               #rsm_set{first = #rsm_first{data = First},
                 last = Last,
                 count = Count};
             [] when RSM /= undefined ->
               #rsm_set{count = Count};
             _ ->
               undefined
           end,
  Q = #disco_items{node = ?NS_GROUPS, items = Items, rsm = ResRSM},
  xmpp:make_iq_result(IQ,Q);
process_disco_items(#iq{lang = Lang} = IQ) ->
  Txt = <<"No module is handling this query">>,
  xmpp:make_error(IQ, xmpp:err_service_unavailable(Txt, Lang)).

%%%===================================================================
%%% Internal functions
%%%===================================================================

make_sql_query(LServer, User, UserHost, RSM) ->
  {Max, Direction, Group} = get_max_direction_chat(RSM),
  SServer = ejabberd_sql:escape(LServer),
  SUser = ejabberd_sql:escape(User),
  LimitClause = if is_integer(Max), Max >= 0 ->
    [<<" limit ">>, integer_to_binary(Max)];
                  true ->
                    []
                end,
  ChatDiscovery = [<<"select jid,name from groupchats where searchable!='none' and
    jid not in (select chatgroup from groupchat_block where blocked = '">>,SUser,<<"'
    or blocked = '">>,UserHost,<<"')  and (model='open' or (model='private' and
    (select true from groupchat_users where username='">>,SUser,<<"'
     and chatgroup=jid and subscription='wait')))">>],
  PageClause = case Group of
                 B when is_binary(B) ->
                   case Direction of
                     before ->
                       [<<" AND jid < '">>, Group,<<"' ">>];
                     'after' ->
                       [<<" AND jid > '">>, Group,<<"' ">>];
                     _ ->
                       []
                   end;
                 _ ->
                   []
               end,
  Query = case ejabberd_sql:use_new_schema() of
            true ->
              [ChatDiscovery,<<" and server_host='">>,
                SServer, <<"'">>,PageClause];
            false ->
              [ChatDiscovery,PageClause]
          end,
  QueryPage =
  case Direction of
    before ->
      % ID can be empty because of
      % XEP-0059: Result Set Management
      % 2.5 Requesting the Last Page in a Result Set
      [<<"SELECT * FROM (">>, Query,
        <<"GROUP BY jid,name ORDER BY chatgroup DESC ">>,
        LimitClause, <<") AS c ORDER BY jid ASC;">>];
    _ ->
      [Query, <<"GROUP BY jid,name ORDER BY jid ASC ">>,
        LimitClause, <<";">>]
  end,
  case ejabberd_sql:use_new_schema() of
    true ->
      {QueryPage,[<<"SELECT COUNT(*) FROM (">>,ChatDiscovery,<<" and server_host='">>,
        SServer, <<"'">>,
        <<" GROUP BY jid,name) as subquery;">>]};
    false ->
      {QueryPage,[<<"SELECT COUNT(*) FROM (">>,ChatDiscovery,
        <<" GROUP BY jid,name) as subquery;">>]}
  end.

get_max_direction_chat(RSM) ->
  case RSM of
    #rsm_set{max = Max, before = Before} when is_binary(Before) ->
      {Max, before, Before};
    #rsm_set{max = Max, 'after' = After} when is_binary(After) ->
      {Max, 'after', After};
    #rsm_set{max = Max} ->
      {Max, undefined, <<>>};
    _ ->
      {undefined, undefined, <<>>}
  end.

update_groups_caps(Server) ->
  Mod = gen_mod:db_mod(Server, mod_caps),
  lists:foreach(fun(Privacy) ->
    DiscoInfo = client_disco_info(Privacy),
    Features = DiscoInfo#disco_info.features,
    Hash = mod_caps:compute_disco_hash(DiscoInfo, sha),
    NodePair = {?NS_GROUPS, Hash},
    Mod:caps_write(Server, NodePair, Features)
                end, [public, incognito]).