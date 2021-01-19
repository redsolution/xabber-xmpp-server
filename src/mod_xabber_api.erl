%%%-------------------------------------------------------------------
%%% File    : mod_xabber_api.erl
%%% Author  : Andrey Gagarin <andrey.gagarin@redsolution.com>
%%% Purpose : Xabber API methods
%%% Created : 05 Jul 2019 by Andrey Gagarin <andrey.gagarin@redsolution.com>
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

-module(mod_xabber_api).
-author('andrey.gagarin@redsolution.com').

-behaviour(gen_mod).

-include("logger.hrl").
-include("ejabberd_sql_pt.hrl").
-compile([{parse_transform, ejabberd_sql_pt}]).
-export([start/2, stop/1, reload/3, mod_options/1, xabber_commands/0,
  get_commands_spec/0, depends/2]).

% Commands API
-export([


  % Accounts
  xabber_registered_chats/3, xabber_register_chat/9,
  xabber_registered_chats_count/1, xabber_registered_users_count/1,
  set_password/3, can_perform/3, xabber_revoke_user_token/2,
  % Vcard
  set_vcard/4,set_vcard/5,set_nickname/3,get_vcard_multi/4,get_vcard/3,get_vcard/4, oauth_issue_token/5,

  % Count user
  xabber_num_online_users/1,
  xabber_test_api/0,  xabber_get_vcard/2,
  xabber_registered_vhosts/0, xabber_registered_users/1, xabber_get_one_message/3,
  % Other API
  xabber_get_table_size/1,
  xabber_get_db_size/1,
  xabber_sent_images_count/1, xabber_add_permission/4, common_comands/0
]).


-include("ejabberd.hrl").
-include("ejabberd_commands.hrl").
-include("mod_roster.hrl").
-include("mod_privacy.hrl").
-include("ejabberd_sm.hrl").
-include("xmpp.hrl").

%%%
%%% gen_mod
%%%

start(_Host, _Opts) ->
  ejabberd_commands:register_commands(get_commands_spec()).

stop(Host) ->
  case gen_mod:is_loaded_elsewhere(Host, ?MODULE) of
    false ->
      ejabberd_commands:unregister_commands(get_commands_spec());
    true ->
      ok
  end.

reload(_Host, _NewOpts, _OldOpts) ->
  ok.

depends(_Host, _Opts) ->
  [].

mod_options(_) -> [].

%%%
%%% Register commands
%%%

get_commands_spec() ->
  Vcard1FieldsString = "Some vcard field names in get/set_vcard are:\n"
  " FN		- Full Name\n"
  " NICKNAME	- Nickname\n"
  " BDAY		- Birthday\n"
  " TITLE		- Work: Position\n"
  " ROLE		- Work: Role",

  Vcard2FieldsString = "Some vcard field names and subnames in get/set_vcard2 are:\n"
  " N FAMILY	- Family name\n"
  " N GIVEN	- Given name\n"
  " N MIDDLE	- Middle name\n"
  " ADR CTRY	- Address: Country\n"
  " ADR LOCALITY	- Address: City\n"
  " TEL HOME      - Telephone: Home\n"
  " TEL CELL      - Telephone: Cellphone\n"
  " TEL WORK      - Telephone: Work\n"
  " TEL VOICE     - Telephone: Voice\n"
  " EMAIL USERID	- E-Mail Address\n"
  " ORG ORGNAME	- Work: Company\n"
  " ORG ORGUNIT	- Work: Department",

  VcardXEP = "For a full list of vCard fields check XEP-0054: vcard-temp at "
  "http://www.xmpp.org/extensions/xep-0054.html",
    [
      #ejabberd_commands{name = xabber_test_api, tags = [xabber],
        desc = "Test api",
        longdesc = "Test api",
        module = ?MODULE, function = xabber_test_api,
        args_desc = ["xabber_test_api"],
        args_example = [],
        args = [],
        result = {res, restuple},
        result_example = {ok, <<"Some information">>},
        result_desc = "Result tuple"},
      #ejabberd_commands{name = xabber_registered_users, tags = [xabber],
        desc = "List all registered vhosts in SERVER",
        module = ?MODULE, function = xabber_registered_users,
        result_desc = "List of available vhosts",
        result_example = [<<"example.com">>, <<"anon.example.com">>],
        args = [{host, binary}],
        args_desc = ["Name of HOST to check"],
        args_example = [<<"capulet.lit">>],
        result = {users, {list, {user, {tuple, [{name, string}, {auth, string}]}}}}},
      #ejabberd_commands{name = xabber_get_vcard, tags = [xabber],
        desc = "List all registered vhosts in SERVER",
        module = ?MODULE, function = xabber_get_vcard,
        result_desc = "List of available vhosts",
        result_example = [<<"example.com">>, <<"anon.example.com">>],
        args = [{user, binary},{host, binary}],
        args_desc = ["User and Host to check"],
        args_example = [<<"juliet">>,<<"capulet.lit">>],
        result = {result, {tuple, [{nick, string}, {first_name, string}, {last_name, string}, {photo, string}, {phone, string}]}}},
      #ejabberd_commands{name = xabber_get_one_message, tags = [xabber],
        policy = user,
        desc = "Get a single message",
        module = ?MODULE, function = xabber_get_one_message,
        result_desc = "One message",
        result_example = [<<"message-id-1">>],
        args = [{message_id, binary}],
        args_desc = ["User and Host to check"],
        args_example = [<<"message-123">>],
        result = {result, {tuple, [{message, string}]}}},
      #ejabberd_commands{name = xabber_revoke_user_token, tags = [xabber],
        desc = "Delete user's token",
        longdesc = "Type 'jid token' to delete selected token. Type 'jid all' - if you want to delete all tokens of user",
        module = ?MODULE, function = xabber_revoke_user_token,
        args_desc = ["User's jid", "Token (all - to delete all tokens)"],
        args_example = [<<"juliet@capulet.lit">>, <<"all">>],
        args = [{jid, binary}, {token, binary}],
        result = {res, rescode},
        result_example = 0,
        result_desc = "Returns integer code:\n"
        " - 0: operation succeeded\n"
        " - 1: error: sql query error"},
      #ejabberd_commands{name = xabber_num_online_users, tags = [xabber],
        desc = "Get number of users active in the last DAYS ",
        longdesc = "",
        module = ?MODULE, function = xabber_num_online_users,
        args_desc = ["Name of HOST to check"],
        args_example = [<<"capulet.lit">>],
        args = [{host, binary}],
        result = {users, integer},
        result_example = 123,
        result_desc = "Number of users online, exclude duplicated resources"},
      #ejabberd_commands{name = xabber_registered_users, tags = [accounts],
        desc = "List all registered users in HOST",
        module = ?MODULE, function = xabber_registered_users,
        args_desc = ["Local vhost"],
        args_example = [<<"example.com">>,30,1],
        result_desc = "List of registered accounts usernames",
        result_example = [<<"user1">>, <<"user2">>],
        args = [{host, binary},{limit,integer},{page,integer}],
        result = {users, {list, {username, string}}}},
      #ejabberd_commands{name = xabberuser_change_password, tags = [accounts],
        desc = "Change the password of an account",
        module = ?MODULE, function = set_password,
        args = [{user, binary}, {host, binary}, {newpass, binary}],
        args_example = [<<"peter">>, <<"myserver.com">>, <<"blank">>],
        args_desc = ["User name", "Server name",
          "New password for user"],
        result = {res, rescode},
        result_example = ok,
        result_desc = "Status code: 0 on success, 1 otherwise"},
      #ejabberd_commands{name = xabberuser_set_nickname, tags = [vcard],
        desc = "Set nickname in a user's vCard",
        module = ?MODULE, function = set_nickname,
        args = [{user, binary}, {host, binary}, {nickname, binary}],
        args_example = [<<"user1">>,<<"myserver.com">>,<<"User 1">>],
        args_desc = ["User name", "Server name", "Nickname"],
        result = {res, rescode}},
      #ejabberd_commands{name = xabberuser_get_vcard, tags = [vcard],
        desc = "Get content from a vCard field",
        longdesc = Vcard1FieldsString ++ "\n" ++ Vcard2FieldsString ++ "\n\n" ++ VcardXEP,
        module = ?MODULE, function = get_vcard,
        args = [{user, binary}, {host, binary}, {name, binary}],
        args_example = [<<"user1">>,<<"myserver.com">>,<<"NICKNAME">>],
        args_desc = ["User name", "Server name", "Field name"],
        result_example = "User 1",
        result_desc = "Field content",
        result = {content, string}},
      #ejabberd_commands{name = xabberuser_get_vcard2, tags = [vcard],
        desc = "Get content from a vCard subfield",
        longdesc = Vcard2FieldsString ++ "\n\n" ++ Vcard1FieldsString ++ "\n" ++ VcardXEP,
        module = ?MODULE, function = get_vcard,
        args = [{user, binary}, {host, binary}, {name, binary}, {subname, binary}],
        args_example = [<<"user1">>,<<"myserver.com">>,<<"N">>, <<"FAMILY">>],
        args_desc = ["User name", "Server name", "Field name", "Subfield name"],
        result_example = "Schubert",
        result_desc = "Field content",
        result = {content, string}},
      #ejabberd_commands{name = xabberuser_get_vcard2_multi, tags = [vcard],
        desc = "Get multiple contents from a vCard field",
        longdesc = Vcard2FieldsString ++ "\n\n" ++ Vcard1FieldsString ++ "\n" ++ VcardXEP,
        module = ?MODULE, function = get_vcard_multi,
        args = [{user, binary}, {host, binary}, {name, binary}, {subname, binary}],
        result = {contents, {list, {value, string}}}},

      #ejabberd_commands{name = xabberuser_set_vcard, tags = [vcard],
        desc = "Set content in a vCard field",
        longdesc = Vcard1FieldsString ++ "\n" ++ Vcard2FieldsString ++ "\n\n" ++ VcardXEP,
        module = ?MODULE, function = set_vcard,
        args = [{user, binary}, {host, binary}, {name, binary}, {content, binary}],
        args_example = [<<"user1">>,<<"myserver.com">>, <<"URL">>, <<"www.example.com">>],
        args_desc = ["User name", "Server name", "Field name", "Value"],
        result = {res, rescode}},
      #ejabberd_commands{name = xabberuser_set_vcard2, tags = [vcard],
        desc = "Set content in a vCard subfield",
        longdesc = Vcard2FieldsString ++ "\n\n" ++ Vcard1FieldsString ++ "\n" ++ VcardXEP,
        module = ?MODULE, function = set_vcard,
        args = [{user, binary}, {host, binary}, {name, binary}, {subname, binary}, {content, binary}],
        args_example = [<<"user1">>,<<"myserver.com">>,<<"TEL">>, <<"NUMBER">>, <<"123456">>],
        args_desc = ["User name", "Server name", "Field name", "Subfield name", "Value"],
        result = {res, rescode}},
      #ejabberd_commands{name = xabberuser_set_vcard2_multi, tags = [vcard],
        desc = "Set multiple contents in a vCard subfield",
        longdesc = Vcard2FieldsString ++ "\n\n" ++ Vcard1FieldsString ++ "\n" ++ VcardXEP,
        module = ?MODULE, function = set_vcard,
        args = [{user, binary}, {host, binary}, {name, binary}, {subname, binary}, {contents, {list, {value, binary}}}],
        result = {res, rescode}},
      #ejabberd_commands{name = xabber_register_chat, tags = [accounts],
        desc = "Create xabber groupchat with owner",
        module = ?MODULE, function = xabber_register_chat,
        args = [{host, binary},
          {user, binary},
          {userhost, binary},
          {name, binary},
          {localpart, binary},
          {privacy, binary},
          {index, binary},
          {membership, binary},
          {description, binary}
        ],
        args_example = [
          <<"myserver.com">>,
          <<"user1">>,
          <<"someserver.com">>,
          <<"Group 3">>,
          <<"group3">>,
          <<"public">>,
          <<"global">>,
          <<"open">>,
          <<"Group number 3">>
        ],
        args_desc = ["Host","Username", "User server name", "Groupchat name",
          "Groupchat identifier", "Groupchat privacy", "Groupchat index",
          "Groupchat membership", "Groupchat description"],
        result = {res, rescode},
        result_example = 0,
        result_desc = "Returns integer code:\n"
      " - 0: chat was created\n"
      " - 1: error: chat is exist\n"
      " - 2: error: bad params"},
      #ejabberd_commands{name = xabber_registered_chats, tags = [accounts],
        desc = "List all registered chats in HOST",
        module = ?MODULE, function = xabber_registered_chats,
        args_desc = ["Local vhost"],
        args_example = [<<"example.com">>,30,1],
        result_desc = "List of registered chats",
        result_example = [{<<"chat1">>,<<"user1@example.com">>,123}, {<<"chat2">>,<<"user@xabber.com">>,456,202}],
        args = [{host, binary},{limit,integer},{page,integer}],
        result = {chats, {list, {chat, {tuple,[
          {name, string},
          {owner,string},
          {number, integer},
          {private_chats, integer}
        ]
        }
        }}}},
      #ejabberd_commands{name = xabber_registered_chats_count, tags = [accounts],
        desc = "Count all registered chats in HOST",
        module = ?MODULE, function = xabber_registered_chats_count,
        args_desc = ["Local vhost"],
        args_example = [<<"example.com">>],
        result_desc = "Number of registered chats",
        result_example = [100500],
        args = [{host, binary}],
        result = {number, integer}
        },
      #ejabberd_commands{name = xabber_oauth_issue_token, tags = [xabber],
        desc = "Issue an oauth token for the given jid",
        module = ?MODULE, function = oauth_issue_token,
        args = [{jid, string},{ttl, integer}, {scopes, string}, {browser, binary}, {ip, binary}],
        policy = restricted,
        args_example = ["user@server.com", 3600, "connected_users_number;muc_online_rooms","Firefox 155", "192.168.100.111"],
        args_desc = ["Jid for which issue token",
          "Time to live of generated token in seconds",
          "List of scopes to allow, separated by ';'",
          "Name of web browser",
          "IP address"],
        result = {result, {tuple, [{token, string}, {scopes, string}, {expires_in, string}]}}
      },
      #ejabberd_commands{name = xabber_registered_users_count, tags = [accounts],
        desc = "Count all registered users in HOST",
        module = ?MODULE, function = xabber_registered_users_count,
        args_desc = ["Local vhost"],
        args_example = [<<"example.com">>],
        result_desc = "Number of registered users",
        result_example = [100500],
        args = [{host, binary}],
        result = {number, integer}
      },
      #ejabberd_commands{name = registered_users, tags = [accounts],
        desc = "List all registered users in HOST",
        module = ?MODULE, function = xabber_registered_users,
        args_desc = ["Local vhost"],
        args_example = [<<"example.com">>],
        result_desc = "List of registered accounts usernames",
        result_example = [<<"user1">>, <<"user2">>],
        args = [{host, binary}],
        result = {users, {list, {user, {tuple, [{name, string}, {auth, string}]}}}}},
      #ejabberd_commands{name = registered_vhosts, tags = [server],
        desc = "List all registered vhosts in SERVER",
        module = ?MODULE, function = xabber_registered_vhosts,
        result_desc = "List of available vhosts",
        result_example = [<<"example.com">>, <<"anon.example.com">>],
        args = [],
        result = {vhosts, {list, {vhost, string}}}},
      #ejabberd_commands{name = xabber_sent_images_count, tags = [xabber],
        desc = "Get number of sended images",
        longdesc = "",
        module = ?MODULE, function = xabber_sent_images_count,
        args_desc = ["Name of HOST to check"],
        args_example = [<<"capulet.lit">>],
        args = [{host, binary}],
        result = {images, integer},
        result_example = 123,
        result_desc = "Number of sended images"},
      #ejabberd_commands{name = xabber_get_db_size, tags = [xabber],
        desc = "Get db size of host",
        longdesc = "",
        module = ?MODULE, function = xabber_get_db_size,
        args_desc = ["Name of HOST to check"],
        args_example = [<<"capulet.lit">>],
        args = [{host, binary}],
        result = {size, string},
        result_example = <<"356 MB">>,
        result_desc = "Size of database"},
      #ejabberd_commands{name = xabber_get_table_size, tags = [accounts],
        desc = "Get size of tables of host database",
        module = ?MODULE, function = xabber_get_table_size,
        args_desc = ["Local vhost"],
        args_example = [<<"example.com">>],
        result_desc = "List of tables and their size",
        result_example = [<<"users">>, <<"124 MB">>],
        args = [{host, binary}],
        result = {tables, {list, {table, {tuple, [{name, string}, {size, string}]}}}}},
      #ejabberd_commands{name = xabber_set_permissions, tags = [xabber],
        desc = "Grant a permission to perform actions to user",
        longdesc = "Grant a permission to perform actions to user",
        module = ?MODULE, function = xabber_add_permission,
        args_desc = ["User", "Host", "Set admin", "Commands"],
        args_example = [<<"juliet">>, <<"capulet.lit">>, <<"true">>, <<"registered_users, get_vcard">>],
        args = [{user, binary}, {host, binary}, {set_admin, binary}, {commands, binary}],
        result = {res, rescode},
        result_example = 0,
        result_desc = "Returns integer code:\n"
        " - 0: operation succeeded\n"
        " - 1: error: sql query error"}
    ].

xabber_registered_vhosts() ->
  ?MYHOSTS.

xabber_registered_users(Host) ->
  Users = get_users(Host),
  SUsers = lists:sort(Users),
  UserAndBackends = lists:map(fun({U,_S, B}) -> {U,B} end, SUsers),
  UserAndBackends.

xabber_get_vcard(User, Server) ->
  convert_vcard(mod_vcard:get_vcard(User,Server)).

xabber_get_one_message(User, Server, StanzaID) ->
  ?INFO_MSG("Try to get message from user ~p @ ~p~n Stanza ID ~p",[User,Server,StanzaID]),
  {<<"some message">>}.

oauth_issue_token(Jid, TTLSeconds, ScopesString,Browser,IP) ->
  Scopes = [list_to_binary(Scope) || Scope <- string:tokens(ScopesString, ";")],
  try jid:decode(list_to_binary(Jid)) of
    #jid{luser =Username, lserver = Server} ->
      case oauth2:authorize_password({Username, Server},  Scopes, admin_generated) of
        {ok, {_Ctx,Authorization}} ->
          {ok, {_AppCtx2, Response}} = oauth2:issue_token(Authorization, [{expiry_time, TTLSeconds}]),
          {ok, AccessToken} = oauth2_response:access_token(Response),
          {ok, VerifiedScope} = oauth2_response:scope(Response),
          ejabberd_hooks:run(xabber_oauth_token_issued, Server, [Username, Server, AccessToken, TTLSeconds, Browser, IP]),
          {AccessToken, VerifiedScope, integer_to_list(TTLSeconds) ++ " seconds"};
        {error, Error} ->
          {error, Error}
      end
  catch _:{bad_jid, _} ->
    {error, "Invalid JID: " ++ Jid}
  end.

set_password(User, Host, Password) ->
  mod_admin_extra:set_password(User, Host, Password).

set_nickname(User, Host, Nickname) ->
  mod_admin_extra:set_nickname(User, Host, Nickname).

get_vcard(User, Host, Name) ->
  mod_admin_extra:get_vcard(User, Host, Name).

get_vcard(User, Host, Name, Subname) ->
  mod_admin_extra:get_vcard(User, Host, Name, Subname).

get_vcard_multi(User, Host, Name, Subname) ->
  mod_admin_extra:get_vcard_multi(User, Host, Name, Subname).

set_vcard(User, Host, Name, SomeContent) ->
  mod_admin_extra:set_vcard(User, Host, Name, SomeContent).

set_vcard(User, Host, Name, Subname, SomeContent) ->
  mod_admin_extra:set_vcard(User, Host, Name, Subname, SomeContent).

xabber_get_table_size(Host) ->
  case ejabberd_sql:sql_query(
    Host,
    [
      <<"SELECT nspname || '.' || relname AS relation,
    pg_size_pretty(pg_total_relation_size(C.oid)) AS total_size
  FROM pg_class C
  LEFT JOIN pg_namespace N ON (N.oid = C.relnamespace)
  WHERE nspname NOT IN ('pg_catalog', 'information_schema')
    AND C.relkind <> 'i'
    AND nspname !~ '^pg_toast'
  ORDER BY pg_total_relation_size(C.oid) DESC">>
    ]) of
    {selected,_Columns,Info} ->
      lists:map(fun(Tab) -> [TableName,TableSize] = Tab, {TableName,TableSize} end, Info);
    _ ->
      []
  end.

xabber_get_db_size(Host) ->
  SQLDATABASE = ejabberd_config:get_option(sql_database, undefined),
  case SQLDATABASE of
    _  when is_binary(SQLDATABASE) == true ->
      case ejabberd_sql:sql_query(
        Host,
        [
          <<"select pg_size_pretty(pg_database_size('">>,SQLDATABASE,<<"'));">>
        ]) of
        {selected,_Col,[[Value]]} ->
          Value;
        _ ->
          <<"No data">>
      end;
    _ ->
      <<"No data">>
  end.


xabber_sent_images_count(Host) ->
  DocRoot1 = gen_mod:get_module_opt(Host, mod_http_upload, docroot),
  DocRoot2 = mod_http_upload:expand_home(str:strip(DocRoot1, right, $/)),
  DocRoot3 = mod_http_upload:expand_host(DocRoot2, Host),
  {ok,Files} = file:list_dir(DocRoot3),
  FullPathFiles = lists:map(fun(File) -> FileB = list_to_binary(File), <<DocRoot3/binary,"/", FileB/binary>> end, Files),
  Directories = lists:filter(fun(E) -> filelib:is_dir(E) end, FullPathFiles),
  SearchPatern = lists:map(fun(Dir) -> binary_to_list(<<Dir/binary, "/*/*.{png,jpg,jpeg,JPEG,gif,webp}">>) end, Directories),
  sum(0,lists:map(fun(Patern) -> length(filelib:wildcard(Patern)) end, SearchPatern)).

sum(Acc,[]) ->
  Acc;
sum(Acc,[F|R]) ->
  sum(Acc + F, R).

xabber_registered_chats(Host,Limit,Page) ->
  mod_groupchat_chats:get_all_info(Host,Limit,Page).

xabber_registered_chats_count(Host) ->
  mod_groupchat_chats:get_count_chats(Host).

xabber_registered_users_count(Host) ->
  length(xabber_registered_users(Host)).

xabber_register_chat(Server,Creator,Host,Name,LocalJid,Anon,Searchable,Model,Description) ->
  case validate(Anon,Searchable,Model) of
    ok ->
      case mod_groupchat_inspector:create_chat(Creator,Host,Server,Name,Anon,LocalJid,Searchable,Description,Model,undefined,undefined,undefined) of
        {ok, _Created} ->
          ok;
        _ ->
          1
      end;
    _ ->
      2
  end.

xabber_num_online_users(Host) ->
  xabber_num_active_users(0, Host).

xabber_num_active_users(Days, Host) when Days == 0 ->
  xabber_num_active_users(Host, 0, 0);
xabber_num_active_users(Days, Host) ->
  case get_last_from_db(Days, Host) of
    {error, db_failure} ->
      0;
    {ok, UserLastList} ->
      xabber_num_active_users(UserLastList, Host, 0, 0)
  end.

xabber_revoke_user_token(BareJID,Token) ->
  ejabberd_oauth_sql:revoke_user_token(BareJID,Token).

xabber_num_active_users(Host, Offset, UserCount) ->
%%  UsersList = ejabberd_admin:registered_users(Host),
  Limit = 500,
  case ejabberd_auth:get_users(Host, [{limit, Limit}, {offset, Offset}]) of
    [] ->
      UserCount;
    UsersList ->
      UsersList2 = lists:filtermap(
        fun(U) ->
          {User, Host, _Type} = U,
          case ejabberd_sm:get_user_resources(User, Host) of
            [] ->
              false;
            _ ->
              {true, 0}
          end
        end,UsersList),
      xabber_num_active_users(Host, Offset+Limit, UserCount+length(UsersList2))
  end.

xabber_num_active_users(UserLastList, Host, Offset, UserCount) ->
  Limit = 500,
  case ejabberd_auth:get_users(Host, [{limit, Limit}, {offset, Offset}]) of
    [] ->
      UserCount;
    UsersList ->
      UsersList2 = lists:filtermap(
        fun(U) ->
          {User, Host} = U,
          case ejabberd_sm:get_user_resources(User, Host) of
            [] ->
              case lists:member({User},UserLastList) of
                false ->
                  false;
                true ->
                  {true, 0}
              end;
            _ ->
              {true, 0}
          end
        end,UsersList),
      xabber_num_active_users(UserLastList, Host, Offset+Limit, UserCount+length(UsersList2))
  end.

get_last_from_db(Days, LServer) ->
  CurrentTime = p1_time_compat:system_time(seconds),
  Diff = Days * 24 * 60 * 60,
  TimeStamp = CurrentTime - Diff,
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(username)s from last where seconds >= %(TimeStamp)s and %(LServer)H")) of
    {selected, LastList} ->
      {ok, LastList};
    _Reason ->
      {error, db_failure}
  end.

validate(Anon,Searchable,Model) ->
  IsPrivacyOkey = validate_privacy(Anon),
  IsMembershipOkey = validate_membership(Model),
  IsIndexOkey = validate_index(Searchable),
  case IsPrivacyOkey of
    true when IsMembershipOkey == true andalso IsIndexOkey == true ->
      ok;
    _ ->
      not_ok
  end.

xabber_commands() ->
  [xabber_oauth_issue_token,
    xabber_revoke_token,
    registered_vhosts,
    xabber_registered_users,
    xabber_registered_users_count,
    xabber_registered_chats,
    xabber_registered_chats_count,
    register,
    unregister,
    set_vcard,
    set_vcard2,
    get_vcard,
    get_vcard2,
    change_password,
    check_password,
    srg_get_info,
    srg_create,
    srg_delete,
    srg_user_add,
    srg_user_del,
    stats,
    xabberuser_change_password,
    xabberuser_set_vcard,
    xabberuser_set_vcard2,
    xabberuser_set_vcard2_multi,
    xabberuser_set_nickname,
    xabberuser_get_vcard,
    xabberuser_get_vcard2,
    xabberuser_get_vcard2_multi,
    xabber_num_online_users].

common_comands() ->
  [xabberuser_change_password,
    set_vcard,
    set_vcard2,
    get_vcard,
    get_vcard2,
    xabberuser_set_vcard,
    xabberuser_set_vcard2,
    xabberuser_set_vcard2_multi,
    xabberuser_set_nickname,
    xabberuser_get_vcard,
    xabberuser_get_vcard2,
    xabberuser_get_vcard2_multi].

can_perform(#{caller_module := mod_http_api} = Auth, Args, Command) ->
  IsCommon = lists:member(Command, common_comands()),
  #{usr := USR} = Auth,
  {U,S,_R} = USR,
  case IsCommon of
    true ->
      [LUser|Rest] = Args,
      [LServer|_R2] = Rest,
      case LUser of
        U  when S == LServer ->
          true;
        _ ->
          false
      end;
    _ ->
      check_user_permission(U, S, Command)
  end;
can_perform(_Auth,_Args,_Command) ->
  true.

check_user_permission(LUser, LServer, Command) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(is_admin)b,@(commands)s from user_permissions
    where username=%(LUser)s and %(LServer)H")) of
    {selected,[{IsAdmin,Commands}]} ->
      check_permissions(Command, IsAdmin, Commands);
    _ ->
      false
  end.

check_permissions(_Command, true, _Commands) ->
  true;
check_permissions(Command, _IsAdmin, Commands) ->
  CommandList = parse_command_string(Commands),
  lists:member(Command, CommandList).

parse_command_string(Commands) ->
  Splited = binary:split(Commands,<<",">>,[global]),
  Empty = [X||X <- Splited, X == <<>>],
  NotEmpty = Splited -- Empty,
  NotEmpty.

form_command_string(CommandList) ->
  SortedList = lists:usort(CommandList),
  list_to_binary(lists:map(fun(N)-> [N|[<<",">>]] end, SortedList)).

xabber_add_permission(LUser, LServer, SetAdmin, Command) ->
  case ejabberd_auth:user_exists(LUser, LServer) of
    true ->
      xabber_add_permission_checked(LUser, LServer, SetAdmin, Command);
    false ->
      1
  end.

xabber_add_permission_checked(LUser, LServer, <<"">>, _Command) ->
  delete_permission(LUser, LServer);
xabber_add_permission_checked(LUser, LServer, <<"false">>, <<"">>) ->
  delete_permission(LUser, LServer);
xabber_add_permission_checked(LUser, LServer, <<"true">>, _Command) ->
  set_admin(LUser, LServer);
xabber_add_permission_checked(LUser, LServer, SetAdmin, Commands) when SetAdmin == <<"false">> ->
  CommandList = parse_command_string(Commands),
  CheckedCommands = lists:map(fun(Command) ->
    lists:member(binary_to_atom(Command, latin1), xabber_commands())
                              end, CommandList),
  HasWrongCommand = lists:member(false, CheckedCommands),
  case HasWrongCommand of
    false ->
      change_permission_for_user(LUser, LServer, CommandList);
    _ ->
      1
  end;
xabber_add_permission_checked(_LUser, _LServer, _SetAdmin, _Command) ->
  1.

change_permission_for_user(LUser, LServer, CommandsToAdd) ->
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("select @(commands)s from user_permissions
    where username=%(LUser)s and %(LServer)H")) of
    {selected,[{Commands}]} ->
      CommandList = parse_command_string(Commands),
      NewList = CommandsToAdd,
      NewCommandList = lists:usort(NewList),
      case NewCommandList of
        CommandList ->
          0;
        _ ->
          update_commands(LUser, LServer, NewCommandList)
      end;
    _ ->
      add_commands(LUser, LServer, CommandsToAdd)
  end.

delete_permission(LUser, LServer) ->
  ejabberd_sql:sql_query(
    LServer,
    ?SQL("delete from user_permissions where username=%(LUser)s and %(LServer)H")).

set_admin(LUser, LServer) ->
  State = true,
  case ?SQL_UPSERT(LServer, "user_permissions",
    [ "!username=%(LUser)s",
      "!server_host=%(LServer)s",
      "is_admin=%(State)b"]) of
    ok ->
      ok;
    _Err ->
      {error, db_failure}
  end.

update_commands(LUser, LServer, CommandList) ->
  Commands = form_command_string(CommandList),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL("update user_permissions set commands = %(Commands)s where username=%(LUser)s and %(LServer)H")) of
    {updated, N} when N > 0 ->
      0;
    _ ->
      1
  end.

add_commands(LUser, LServer, CommandList) ->
  Commands = form_command_string(CommandList),
  case ejabberd_sql:sql_query(
    LServer,
    ?SQL_INSERT(
      "user_permissions",
      ["username=%(LUser)s",
        "server_host=%(LServer)s",
        "commands=%(Commands)s"])) of
    {updated, N} when N > 0 ->
      ok;
    _ ->
      error
  end.

xabber_test_api() ->
  Doc = {[{foo, [<<"bing">>, 2.3, true]}]},
  Res = jose_json_jiffy:encode(Doc),
  {ok, Res}.

convert_vcard([]) ->
  [{<<>>,<<>>,<<>>,<<>>,<<>>}];
convert_vcard([Vcard_X|_Rest]) ->
  Vcard = xmpp:decode(Vcard_X),
  [{set_default(Vcard#vcard_temp.nickname),set_default(Vcard#vcard_temp.nickname),set_default(Vcard#vcard_temp.nickname),set_default(Vcard#vcard_temp.photo),set_default(Vcard#vcard_temp.tel)}].

set_default(Value) ->
  case Value of
    undefined ->
      <<>>;
    _ ->
      Value
  end.

validate_privacy(Privacy) ->
  lists:member(Privacy,[<<"public">>, <<"incognito">>]).

validate_membership(Membership) ->
  lists:member(Membership,[<<"open">>, <<"member-only">>]).

validate_index(Index) ->
  lists:member(Index,[<<"none">>, <<"local">>, <<"global">>]).

get_users(Server) ->
  get_users(Server, []).


get_users(Server, Opts) ->
  case jid:nameprep(Server) of
    error -> [];
    LServer ->
      lists:flatmap(
        fun(M) -> db_get_users(LServer, Opts, M) end,
        auth_modules(LServer))
  end.

db_get_users(Server, Opts, {Mod,Auth}) ->
  case erlang:function_exported(Mod, get_users, 2) of
    true ->
      lists:map(fun({U,S}) ->
        {U,S,Auth} end,
      Mod:get_users(Server, Opts));
    false ->
      []
  end.

auth_modules(Server) ->
  LServer = jid:nameprep(Server),
  Default = [sql, ldap],
  Methods = ejabberd_config:get_option({auth_method, LServer}, Default),
  [{ejabberd:module_name([<<"ejabberd">>, <<"auth">>,
    misc:atom_to_binary(M)]), misc:atom_to_binary(M)}
    || M <- Methods].