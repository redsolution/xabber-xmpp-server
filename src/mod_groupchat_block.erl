%%%-------------------------------------------------------------------
%%% File    : mod_groupchat_block.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Check if user was blocked in group chat
%%% Created : 16 Jul 2018 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_groupchat_block).
-author('andrey.gagarin@redsolution.com').
-behavior(gen_mod).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).
-export([start/2, stop/1, depends/2, mod_options/1]).
-export([check_block/4, query/1, get_name_by_id/2]).
%% Hook handlers
-export([block_handler/2,block_iq_handler/2,unblock_iq_handler/2, block_elements/2, block_handler_pre/2, is_user_blocked/2]).
%% API
-export([get_owners/2, validate_domains/2, validate_data/2]).

start(Host, _Opts) ->
  ejabberd_hooks:add(groupchat_invite_hook, Host, ?MODULE, is_user_blocked, 10),
  ejabberd_hooks:add(groupchat_block_hook, Host, ?MODULE, validate_domains, 10),
  ejabberd_hooks:add(groupchat_block_hook, Host, ?MODULE, validate_data, 15),
  ejabberd_hooks:add(groupchat_block_hook, Host, ?MODULE, block_iq_handler, 20),
  ejabberd_hooks:add(groupchat_block_hook, Host, ?MODULE, block_elements, 25),
  ejabberd_hooks:add(groupchat_unblock_hook, Host, ?MODULE, unblock_iq_handler, 10),
  ejabberd_hooks:add(groupchat_presence_subscribed_hook, Host, ?MODULE, block_handler_pre, 15),
  ejabberd_hooks:add(groupchat_presence_hook, Host, ?MODULE, block_handler, 15).

stop(Host) ->
  ejabberd_hooks:delete(groupchat_invite_hook, Host, ?MODULE, is_user_blocked, 10),
  ejabberd_hooks:delete(groupchat_block_hook, Host, ?MODULE, validate_domains, 10),
  ejabberd_hooks:delete(groupchat_block_hook, Host, ?MODULE, validate_data, 15),
  ejabberd_hooks:delete(groupchat_block_hook, Host, ?MODULE, block_iq_handler, 20),
  ejabberd_hooks:delete(groupchat_block_hook, Host, ?MODULE, block_elements, 25),
  ejabberd_hooks:delete(groupchat_unblock_hook, Host, ?MODULE, unblock_iq_handler, 10),
  ejabberd_hooks:delete(groupchat_presence_subscribed_hook, Host, ?MODULE, block_handler_pre, 15),
  ejabberd_hooks:delete(groupchat_presence_hook, Host, ?MODULE, block_handler, 15).

depends(_Host, _Opts) -> [].

mod_options(_Opts) -> [].

validate_domains(_Acc, #iq{sub_els = Sub}) ->
  [El] = Sub,
  D = xmpp:decode(El),
  ValidatedDomains = lists:map(fun(Domain) -> validate(Domain) end, D#xabbergroup_block.domain),
  case lists:member(error, ValidatedDomains) of
    true ->
      {stop, not_ok};
    false ->
      #xabbergroup_block{domain = ValidatedDomains, jid = D#xabbergroup_block.jid, id = D#xabbergroup_block.id}
  end.

validate_data(D, #iq{from = From, to = To}) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  Admin = jid:to_string(jid:remove_resource(From)),
  UserJID = D#xabbergroup_block.jid,
  UserID = D#xabbergroup_block.id,
  UsersToBlock = lists:map(fun(U) ->
    {_Type,Cdata} = U,
    get_name_by_id(Server,Cdata) end, UserID),
  IDsContainsNonExistedUsers = lists:member(no_id,UsersToBlock),
  IDsContainsUser = lists:member(Admin,UsersToBlock),
  UserContainsHimself = lists:member({block_jid,Admin},UserJID),
  ValidateUserJIDList = lists:map(fun(UserByJID) ->
    {_Type, UserJ} = UserByJID,
    mod_groupchat_restrictions:validate_users(Server,Chat,Admin,UserJ) end, UserJID
  ),
  ValidateUserIDList = case IDsContainsNonExistedUsers of
                         true ->
                           [not_ok];
                         _ ->
                           lists:map(fun(UserByID) ->
                             mod_groupchat_restrictions:validate_users(Server,Chat,Admin,UserByID) end, UsersToBlock)
                       end,
  NotValidJIDs = lists:member(not_ok,ValidateUserJIDList),
  NotValidIDs = lists:member(not_ok,ValidateUserIDList),
  case UserJID of
    _ when UserContainsHimself == true ->
      {stop, not_ok};
    _ when UserID =/= [] andalso (IDsContainsNonExistedUsers == true orelse IDsContainsUser == true) ->
      {stop, not_ok};
    _ when NotValidJIDs == true orelse NotValidIDs == true->
      {stop,not_ok};
    _ ->
      D
  end.

block_iq_handler(D, #iq{to = To, from = From}) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  Admin = jid:to_string(jid:remove_resource(From)),
  {selected,_Rows,Owners} = get_owners(Server,Chat),
  OwnerJIDs = [JID||[JID,_ID] <- Owners],
  OwnerIDS = [ID||[_JID,ID] <- Owners],
  OwnerDomains = get_domains(OwnerJIDs),
  OJ = check(jid,OwnerJIDs,D#xabbergroup_block.jid),
  OS = check(domain,OwnerDomains,D#xabbergroup_block.domain),
  OId = check(id,OwnerIDS,D#xabbergroup_block.id),
  case mod_groupchat_restrictions:is_permitted(<<"set-restrictions">>,Admin,Chat) of
    true when OJ == false andalso OS == false andalso OId == false ->
      D;
    _ ->
      {stop,not_ok}
  end.

unblock_iq_handler(_Acc, #iq{to = To, from = From, sub_els = Sub}) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  Admin = jid:to_string(jid:remove_resource(From)),
  [El] = Sub,
  D = xmpp:decode(El),
  Elements = D#xabbergroup_unblock.domain ++ D#xabbergroup_unblock.jid ++ D#xabbergroup_unblock.id,
  case mod_groupchat_restrictions:is_permitted(<<"set-restrictions">>,Admin,Chat) of
    true ->
      unblock_elements(Elements,Server,Chat);
    _ ->
      {stop,not_ok}
  end.

block_handler_pre(_Acc,{Server,From,Chat,_Lang}) ->
  User = jid:to_string(jid:remove_resource(From)),
  Domain = From#jid.lserver,
  check_block(Server,Chat,User,Domain).

block_handler(_Acc, Presence) ->
  #presence{to = To, from = From} = Presence,
  Chat = jid:to_string(jid:remove_resource(To)),
  User = jid:to_string(jid:remove_resource(From)),
  Domain = From#jid.lserver,
  Server = To#jid.lserver,
  check_block(Server,Chat,User,Domain).

is_user_blocked(_Acc, {_Admin,Chat,Server,
  #xabbergroupchat_invite{invite_jid = User, reason = _Reason, send = _Send}}) ->
  JID = jid:from_string(User),
  Domain = JID#jid.lserver,
  check_block(Server,Chat,User,Domain).

check_block(Server,Chat,User,Domain) ->
  case  ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(blocked)s from groupchat_block where chatgroup=%(Chat)s and blocked=%(User)s or blocked=%(Domain)s")) of
    {selected,[]} ->
      ok;
    {selected,[{_Info}]} ->
      {stop,not_ok};
    _ ->
      {stop,error}
  end.

query(To) ->
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  {selected,Elements} = show_elements(Server,Chat),
  {xmlel,<<"query">>,[{<<"xmlns">>,<<"https://xabber.com/protocol/groups#block">>}],
    elements(Elements,[])}.


%%%% Internal functions

%%%%
%%   Query of blocked elements
%%%%
elements([],Acc) ->
  Acc;
elements(Elements,Acc) ->
  [First|Rest] = Elements,
  elements(Rest,[item(First)|Acc]).

item(Item) ->
  {Element,Type,Id} = Item,
  case Type of
    <<"user">> when Id =/= null ->
      #xmlel{name = Type, attrs = [{<<"jid">>,Element}], children = [{xmlcdata,Id}]};
    <<"user">> when Id == null ->
      #xmlel{name = Type, attrs = [{<<"jid">>,Element}]};
    <<"domain">> ->
      #xmlel{name = Type, children = [{xmlcdata,Element}]}
  end.

%%%% SQL functions

show_elements(Server,Chat) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(blocked)s,@(type)s,@(anonim_id)s from groupchat_block where chatgroup=%(Chat)s")).

%%%%
%%   End of section query
%%%%

%%%%
%%   Blocking / unblocking users
%%%%
check_if_exist(Server,User,Chat,Admin) ->
  block(Server,User,<<"user">>,Admin,Chat),
  case mod_groupchat_users:check_user(Server,User,Chat) of
    not_exist ->
      false;
    _ ->
      Card = mod_groupchat_users:form_user_card(User,Chat),
      {true,Card}
  end.

block_elements(D, #iq{to = To, from = From} = Iq)->
  Elements = D#xabbergroup_block.domain ++ D#xabbergroup_block.jid ++ D#xabbergroup_block.id,
  Chat = jid:to_string(jid:remove_resource(To)),
  Server = To#jid.lserver,
  Admin = jid:to_string(jid:remove_resource(From)),
  {Owner,OwnerId} = get_owner(Server,Chat),
  Kicked = lists:filtermap(fun(El) ->
    {Type,Cdata} = El,
    case Type of
      block_domain ->
        false;
      block_jid when Cdata =/= Owner->
        check_if_exist(Server,Cdata,Chat,Admin);
      block_id when Cdata =/= OwnerId ->
        UserName = get_name_by_id(Server,Cdata),
        case UserName of
          no_id ->
            false;
          _ ->
            Card = mod_groupchat_users:form_user_card(UserName,Chat),
            {true,Card}
        end;
      _ ->
        false
    end end, Elements
  ),
  lists:foreach( fun(Element) ->
    {Type,Cdata} = Element,
    OwnStr = jid:from_string(Owner),
    OwnerServer = OwnStr#jid.lserver,
    case Type of
      block_domain when Cdata =/= OwnerServer->
        block(Server,Cdata,<<"domain">>,Admin,Chat);
      block_jid when Cdata =/= Owner->
        mod_groupchat_inspector:kick_user(Server,Cdata,Chat);
      block_id when Cdata =/= OwnerId ->
        UserName = get_name_by_id(Server,Cdata),
        case UserName of
          no_id ->
            ok;
          _ ->
            block_by_id(Server,Cdata,Admin,Chat),
            mod_groupchat_inspector:kick_user(Server,UserName,Chat)
        end;
      _ ->
        {stop,not_ok}
    end end, Elements),
  mod_groupchat_service_message:users_blocked(Kicked, Iq),
  D.

unblock_elements([],_Server,_Chat)->
  {stop,ok};
unblock_elements(Elements,Server,Chat)->
  [Element|Rest] = Elements,
  {Type,Cdata} = Element,
  case Type of
    block_domain ->
      unblock(Server,Cdata,Chat);
    block_jid ->
      unblock(Server,Cdata,Chat);
    block_id ->
      unblock_by_id(Server,Cdata,Chat)
  end,
  unblock_elements(Rest,Server,Chat).

%%%% SQL functions
block_by_id(Server,Id,IssuedBy,Chat) ->
   Type = <<"user">>,
    Blocked = get_name_by_id(Server,Id),
  ejabberd_sql:sql_query(
    Server,
    [<<"INSERT INTO groupchat_block (chatgroup,type,blocked,anonim_id,issued_by,issued_at) values(">>
      ,<<"'">>,Chat,<<"',">>,
      <<"'">>,Type,<<"',">>,
      <<"'">>,Blocked,<<"',">>,
      <<"'">>,Id,<<"',">>,
      <<"'">>,IssuedBy,<<"',">>,
      <<"CURRENT_TIMESTAMP)">>
    ]).

get_name_by_id(Server,Id) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s from groupchat_users where id = %(Id)s")) of
    {selected,[]} ->
      no_id;
    {selected,[{}]} ->
      no_id;
    {selected,[{Username}]} ->
      Username;
    _ ->
      no_id
  end.

block(Server,Blocked,Type,IssuedBy,Chat) ->
  ejabberd_sql:sql_query(
    Server,
    [<<"INSERT INTO groupchat_block (chatgroup,type,blocked,issued_by,issued_at) values(">>
      ,<<"'">>,Chat,<<"',">>,
      <<"'">>,Type,<<"',">>,
      <<"'">>,Blocked,<<"',">>,
      <<"'">>,IssuedBy,<<"',">>,
      <<"CURRENT_TIMESTAMP)">>
    ]).


unblock(Server,Blocked,Chat) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_block where
         blocked=%(Blocked)s and chatgroup=%(Chat)s")).

unblock_by_id(Server,Id,Chat) ->
  ejabberd_sql:sql_query(
    Server,
    ?SQL("delete from groupchat_block where
         anonim_id=%(Id)s and chatgroup=%(Chat)s")).

get_owner(Server,Chat) ->
  case ejabberd_sql:sql_query(
    Server,
    ?SQL("select @(username)s,@(id)s from groupchat_users where role = 'owner' and chatgroup = %(Chat)s")) of
    {selected,[{}]} ->
      no_id;
    {selected,[User]} ->
      User;
    _ ->
      error
  end.

get_owners(Server,Chat) ->
  ejabberd_sql:sql_query(
    Server,
    [<<"select  groupchat_users.username,groupchat_users.id from
    groupchat_users left join groupchat_policy
    on groupchat_policy.username =  groupchat_users.username and
    groupchat_policy.chatgroup = groupchat_users.chatgroup
    where groupchat_policy.chatgroup = '">>,Chat,<<"'
    and groupchat_policy.right_name = 'owner';">>]).

get_domains(Users) ->
  lists:map(fun(User) -> JID = jid:from_string(User), JID#jid.lserver end, Users).

check(domain,Owners,BlockList) ->
  Checked = lists:map(fun(Owner) ->
    lists:member({block_domain,Owner},BlockList) end, Owners),
  lists:member(true, Checked);
check(id,Owners,BlockList) ->
  Checked = lists:map(fun(Owner) ->
    lists:member({block_id,Owner},BlockList) end, Owners),
  lists:member(true, Checked);
check(jid,Owners,BlockList) ->
  Checked = lists:map(fun(Owner) ->
    lists:member({block_jid,Owner},BlockList) end, Owners),
  lists:member(true, Checked).

validate([]) ->
  [];
validate({block_domain, Domain}) ->
  JID = jid:from_string(Domain),
  case JID of
    error ->
      error;
    _ ->
      {User, Host, Res} = jid:tolower(JID),
      case Host of
        <<>> ->
          error;
        _ when User == <<>> andalso Res == <<>> ->
          {block_domain, Host};
        _ ->
          error
      end
  end;
validate({B,V}) ->
  {B,V}.

%%%%
%%   End of Blocking/Unblocking section
%%%%