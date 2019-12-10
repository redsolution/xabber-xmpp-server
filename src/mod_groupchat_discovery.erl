%%%-------------------------------------------------------------------
%%% File    : mod_groupchat_discovery.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Discovery for group chats on server
%%% Created : 09 Oct 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_groupchat_discovery).
-author('andrey.gagarin@redsolution.com').
-behaviour(gen_mod).

%% API
-export([start/2, stop/1, reload/3, process_disco_info/1, process_disco_items/1]).
-export([disco_local_items/5, get_local_items/5, get_local_identity/5, get_local_features/5,
  depends/2, mod_options/1]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("translate.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).
-type disco_acc() :: {error, stanza_error()} | {result, [binary()]} | empty.

%%====================================================================
%% gen_mod API
%%====================================================================
start(Host, _Opts) ->
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

mod_options(_) -> [].

get_local_items(Acc, _From, #jid{lserver = LServer} = _To,
    <<"">>, _Lang) ->
  case gen_mod:is_loaded(LServer, mod_groupchat_discovery) of
    false -> Acc;
    _ ->
      Items = case Acc of
                {result, Its} -> Its;
                empty -> []
              end,
      D = #disco_item{jid = jid:make(LServer),
        node = ?NS_GROUPCHAT,
        name = <<"Groupchat Service">>},
      {result,Items ++ [D]}
      end;
get_local_items(Acc, _From, _To, _Node, _Lang) ->
  Acc.

get_local_features(Acc, _From, _To, ?NS_GROUPCHAT, _Lang) ->
  Items = case Acc of
            {result, Its} -> Its;
            empty -> []
          end,
  {result, Items ++[?NS_GROUPCHAT,?NS_DISCO_INFO,?NS_DISCO_ITEMS]};
get_local_features(Acc, _From, _To, _Node, _Lang) ->
  Acc.

-spec get_local_identity(disco_acc(), jid(), jid(), binary(), binary()) -> disco_acc().
get_local_identity(_Acc, _From, _To, ?NS_GROUPCHAT, _Lang) ->
  [#identity{category = <<"conference">>,
    type = <<"server">>,
    name = <<"Groupchat Service">>}];
get_local_identity(Acc, _From, _To, _Node, _Lang) ->
  Acc.


-spec process_disco_info(iq()) -> iq().
process_disco_info(#iq{type = set, lang = Lang} = IQ) ->
  Txt = <<"Value 'set' of 'type' attribute is not allowed">>,
  xmpp:make_error(IQ, xmpp:err_not_allowed(Txt, Lang));
process_disco_info(#iq{type = get, to = To, lang = _Lang,
  sub_els = [#disco_info{node = ?NS_GROUPCHAT}]} = IQ) ->
  ServerHost = ejabberd_router:host_of_route(To#jid.lserver),
  Features = [?NS_GROUPCHAT],
  Name = gen_mod:get_module_opt(ServerHost, ?MODULE, name),
  Identity = #identity{category = <<"conference">>,
    type = <<"server">>,
    name = Name},
  xmpp:make_iq_result(
    IQ, #disco_info{features = Features,
      identities = [Identity]});
process_disco_info(#iq{type = get, lang = Lang,
  sub_els = [#disco_info{}]} = IQ) ->
  xmpp:make_error(IQ, xmpp:err_item_not_found(<<"Node not found">>, Lang));
process_disco_info(#iq{lang = Lang} = IQ) ->
  Txt = <<"No module is handling this query">>,
  xmpp:make_error(IQ, xmpp:err_service_unavailable(Txt, Lang)).

-spec process_disco_items(iq()) -> iq().
process_disco_items(#iq{type = set, lang = Lang} = IQ) ->
  Txt = <<"Value 'set' of 'type' attribute is not allowed">>,
  xmpp:make_error(IQ, xmpp:err_not_allowed(Txt, Lang));
process_disco_items(#iq{type = get, from = From, to = To, lang = _Lang,
  sub_els = [#disco_items{node = ?NS_GROUPCHAT, rsm = RSM}]} = IQ) ->
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
  Q = #disco_items{node = ?NS_GROUPCHAT, items = Items, rsm = ResRSM},
  xmpp:make_iq_result(IQ,Q);
process_disco_items(#iq{lang = Lang} = IQ) ->
  Txt = <<"No module is handling this query">>,
  xmpp:make_error(IQ, xmpp:err_service_unavailable(Txt, Lang)).

-spec disco_local_items({error, stanza_error()} | {result, [binary()]} | empty,
    jid(), jid(), binary(), binary()) ->
  {error, stanza_error()} | {result, [binary()]}.
disco_local_items({error, Err}, _From, _To, _Node, _Lang) ->
  {error, Err};
disco_local_items(empty, _From, _To, <<"">>, _Lang) ->
  {result, []};
disco_local_items(Acc, _From, #jid{lserver = LServer} = _To, <<"">>, _Lang) ->
  case gen_mod:is_loaded(LServer, mod_adhoc) of
    false ->
      Acc;
    _ ->
      Items = case Acc of
                {result, I} -> I;
                _ -> []
              end,
      ServerHost = ejabberd_router:host_of_route(LServer),
      Name = gen_mod:get_module_opt(ServerHost, ?MODULE, name),
      D = #disco_item{jid = jid:make(<<"groupchat.", ServerHost/binary>>)},
      ItemsNew = Items -- [D],
      Nodes = [#disco_item{jid = jid:make(<<"groupchat.", ServerHost/binary>>),
        node = ?NS_GROUPCHAT,
        name = Name}],
      {result, ItemsNew ++ Nodes}
  end;
disco_local_items(Acc, _From, _To, _Node, _Lang) ->
  Acc.

%%%===================================================================
%%% Internal functions
%%%===================================================================

make_sql_query(LServer, User, UserHost, RSM) ->
  {Max, Direction, Chat} = get_max_direction_chat(RSM),
  SServer = ejabberd_sql:escape(LServer),
  SUser = ejabberd_sql:escape(User),
  LimitClause = if is_integer(Max), Max >= 0 ->
    [<<" limit ">>, integer_to_binary(Max)];
                  true ->
                    []
                end,
  ChatDiscovery = [<<"select chatgroup,name
    from groupchat_users inner join groupchats on jid=chatgroup
    where chatgroup IN ((select jid from groupchats
    where model='open' and (searchable='local' or searchable='global') EXCEPT select chatgroup from groupchat_block
    where blocked = '">>,SUser,<<"' or blocked = '">>,UserHost,<<"')
   UNION (select jid from groupchats where model='member-only' and (searchable='local' or searchable='global'))
   INTERSECT select chatgroup from groupchat_users where username = '">>,SUser,<<"')">>],
  PageClause = case Chat of
                 B when is_binary(B) ->
                   case Direction of
                     before ->
                       [<<" AND chatgroup < '">>, Chat,<<"' ">>];
                     'after' ->
                       [<<" AND chatgroup > '">>, Chat,<<"' ">>];
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
        <<"GROUP BY chatgroup,name ORDER BY chatgroup DESC ">>,
        LimitClause, <<") AS c ORDER BY chatgroup ASC;">>];
    _ ->
      [Query, <<"GROUP BY chatgroup,name ORDER BY chatgroup ASC ">>,
        LimitClause, <<";">>]
  end,
  case ejabberd_sql:use_new_schema() of
    true ->
      {QueryPage,[<<"SELECT COUNT(*) FROM (">>,ChatDiscovery,<<" and server_host='">>,
        SServer, <<"'">>,
        <<" GROUP BY chatgroup,name) as subquery;">>]};
    false ->
      {QueryPage,[<<"SELECT COUNT(*) FROM (">>,ChatDiscovery,
        <<" GROUP BY chatgroup,name) as subquery;">>]}
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