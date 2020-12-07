%%%-------------------------------------------------------------------
%%% @author Andrey Gagarin andrey.gagarin@redsolution.ru
%%% @copyright (C) 2020, Redsolution Inc.
%%% @doc
%%%
%%% @end
%%% Created : 20. нояб. 2020 12:47
%%%-------------------------------------------------------------------
-module(mod_channel_message).
-author("andrey.gagarin@redsolution.ru").
-include("ejabberd.hrl").
-include("logger.hrl").
-include("xmpp.hrl").
%% API
-export([do_route/1]).

do_route(#message{body=[]}) ->
      ok;
do_route(#message{body=Body, type = chat} = Message) ->
  Text = xmpp:get_text(Body),
  Len = string:len(unicode:characters_to_list(Text)),
  case Text of
    <<>> ->
      ok;
    _  when Len > 0 ->
      message_hook(Message);
    _ ->
      ok
  end.

message_hook(#message{lang = Lang, to =To, from = From} = Pkt) ->
  User = jid:to_string(jid:remove_resource(From)),
  Channel = jid:to_string(jid:remove_resource(To)),
  LServer = To#jid.lserver,
  IsOwner = mod_channel_rights:has_right(LServer,Channel,User,<<"owner">>),
  case IsOwner of
    true ->
      transform_message(Pkt);
    _ ->
      Err = xmpp:err_not_allowed(<<"You have no permission to write">>,Lang),
      ejabberd_router:route_error(Pkt, Err)
  end.

transform_message(#message{id = Id,to =To,
  from = From, sub_els = Els, type = Type, meta = Meta, body = Body} = Pkt) ->
  Text = xmpp:get_text(Body),
  Server = To#jid.lserver,
  LUser = To#jid.luser,
  Channel = jid:to_string(jid:remove_resource(To)),
  User = jid:to_string(jid:remove_resource(From)),
  UserCard = mod_channels_users:form_user_card(User,Channel),
  Username = <<User/binary, ":", "\n">>,
  Length = binary_length(Username),
  Reference = #channel_x{xmlns = ?NS_CHANNELS, sub_els = [#xmppreference{type = <<"mutable">>, 'begin' = 0, 'end' = Length, sub_els = [UserCard]}]},
  NewBody = [#text{lang = <<>>,data = <<Username/binary, Text/binary >>}],
  Users = mod_channels_users:user_list_to_send(Server, Channel) -- [{User}],
  PktSanitarized1 = strip_x_elements(Pkt),
  PktSanitarized = strip_reference_elements(PktSanitarized1),
  Els2 = shift_references(PktSanitarized, Length),
  NewEls = [Reference|Els2],
  ToArchived = jid:remove_resource(From),
  ArchiveMsg = message_for_archive(Id,Type,NewBody,NewEls,Meta,From,ToArchived),
  OriginID = get_origin_id(xmpp:get_subtag(ArchiveMsg, #origin_id{})),
  Retry = xmpp:get_subtag(ArchiveMsg, #delivery_retry{}),
  case Retry of
    _ when Retry /= false andalso OriginID /= false ->
      case mod_unique:get_message(Server, LUser, OriginID) of
        #message{} = Found ->
          send_received(Found, From, OriginID,To);
        _ ->
          Pkt0 = strip_stanza_id(ArchiveMsg,Server),
          Pkt1 = mod_unique:remove_request(Pkt0,Retry),
          {Pkt2, _State2} = ejabberd_hooks:run_fold(
            user_send_packet, Server, {Pkt1, #{jid => To}}, []),
          case Retry of
            false ->
              send_message(Pkt2,Users,To);
            _ when OriginID /= false ->
              #message{meta = #{stanza_id := _StanzaID}} = Pkt2,
              send_received(Pkt2,From,OriginID,To),
              send_message(Pkt2,Users,To)
          end
      end;
    _ ->
      Pkt0 = strip_stanza_id(ArchiveMsg,Server),
      Pkt1 = mod_unique:remove_request(Pkt0,Retry),
      {Pkt2, _State2} = ejabberd_hooks:run_fold(
        user_send_packet, Server, {Pkt1, #{jid => To}}, []),
      ejabberd_hooks:run(groupchat_send_message,Server,[From,To,Pkt2]),
      case Retry of
        _ when OriginID =/= false ->
          #message{meta = #{stanza_id := _StanzaID}} = Pkt2,
          send_received(Pkt2,From,OriginID,To),
          send_message(Pkt2,Users,To);
        _ ->
          send_message(Pkt2,Users,To)
      end
  end.

get_origin_id(OriginId) ->
  case OriginId of
    false ->
      false;
    _ ->
      #origin_id{id = ID} = OriginId,
      ID
  end.

binary_length(Binary) ->
  B1 = binary:replace(Binary,<<"&">>,<<"&amp;">>,[global]),
  B2 = binary:replace(B1,<<">">>,<<"&gt;">>,[global]),
  B3 = binary:replace(B2,<<"<">>,<<"&lt;">>,[global]),
  B4 = binary:replace(B3,<<"\"">>,<<"&quot;">>,[global]),
  B5 = binary:replace(B4,<<"\'">>,<<"&apos;">>,[global]),
  string:len(unicode:characters_to_list(B5)).

shift_references(Pkt, Length) ->
  Els = xmpp:get_els(Pkt),
  NewEls = lists:filtermap(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"reference">> andalso NS == ?NS_REFERENCE_0) ->
        try xmpp:decode(El) of
          #xmppreference{type = Type, 'begin' = undefined, 'end' = undefined, sub_els = Sub} ->
            {true, #xmppreference{type = Type, 'begin' = undefined, 'end' = undefined, sub_els = Sub}};
          #xmppreference{type = Type, 'begin' = Begin, 'end' = End, sub_els = Sub} ->
            {true, #xmppreference{type = Type, 'begin' = Begin + Length, 'end' = End + Length, sub_els = Sub}}
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          true
      end
    end, Els),
  NewEls.

message_for_archive(Id,Type,Body,Els,Meta,From,To)->
  #message{id = Id,from = From, to = To, type = Type, body = Body, sub_els = Els, meta = Meta}.

  -spec strip_reference_elements(stanza()) -> stanza().
strip_reference_elements(Pkt) ->
  Els = xmpp:get_els(Pkt),
  NewEls = lists:filter(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"reference">> andalso NS == ?NS_REFERENCE_0) ->
        try xmpp:decode(El) of
          #xmppreference{type = <<"groupchat">>} ->
            false;
          #xmppreference{type = _Any} ->
            true
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          true
      end
    end, Els),
  xmpp:set_els(Pkt, NewEls).

-spec strip_x_elements(stanza()) -> stanza().
strip_x_elements(Pkt) ->
  Els = xmpp:get_els(Pkt),
  NewEls = lists:filter(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"x">> andalso NS == ?NS_GROUPCHAT) ->
        try xmpp:decode(El) of
          #xabbergroupchat_x{} ->
            false
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          true
      end
    end, Els),
  xmpp:set_els(Pkt, NewEls).

-spec strip_stanza_id(stanza(), binary()) -> stanza().
strip_stanza_id(Pkt, LServer) ->
  Els = xmpp:get_els(Pkt),
  NewEls = lists:filter(
    fun(El) ->
      Name = xmpp:get_name(El),
      NS = xmpp:get_ns(El),
      if (Name == <<"archived">> andalso NS == ?NS_MAM_TMP);
      (Name == <<"time">> andalso NS == ?NS_UNIQUE);
      (Name == <<"stanza-id">> andalso NS == ?NS_SID_0) ->
        try xmpp:decode(El) of
          #mam_archived{by = By} ->
            By#jid.lserver == LServer;
          #unique_time{by = By} ->
            By#jid.lserver == LServer;
          #stanza_id{by = By} ->
            By#jid.lserver == LServer
        catch _:{xmpp_codec, _} ->
          false
        end;
        true ->
          true
      end
    end, Els),
  xmpp:set_els(Pkt, NewEls).

send_received(
    Pkt,
    JID,
    _OriginID,ChatJID) ->
  JIDBare = jid:remove_resource(JID),
  Pkt2 = xmpp:set_from_to(Pkt,JID,ChatJID),
  UniqueReceived = #delivery_x{sub_els = [Pkt2]},
  Confirmation = #message{
    from = ChatJID,
    to = JIDBare,
    type = headline,
    sub_els = [UniqueReceived]},
  ejabberd_router:route(Confirmation).

send_message(_Message,[],_From) ->
%%  mod_groupchat_presence:send_message_to_index(From, Message),
  ok;
send_message(Message,Users,From) ->
  [{User}|RestUsers] = Users,
  To = jid:from_string(User),
  ejabberd_router:route(From,To,Message),
  send_message(Message,RestUsers,From).