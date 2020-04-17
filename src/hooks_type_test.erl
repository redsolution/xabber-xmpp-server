-module(hooks_type_test).

%% run hooks
-export([backend_api_call/3,
         backend_api_error/3,
         backend_api_response_time/4,
         backend_api_timeout/3,
         caps_add/3,
         caps_update/3,
         component_connected/1,
         component_disconnected/2,
         config_reloaded/0,
         create_room/3,
         forbidden_session_hook/1,
         groupchat_changed/4,
         groupchat_created/4,
         groupchat_got_displayed/3,
         groupchat_send_message/3,
         host_down/1,
         host_up/1,
         http_request_debug/1,
         iq_result_from_remote_server/1,
         join_room/4,
         leave_room/4,
         local_send_to_resource_hook/1,
         muc_invite/5,
         oauth_token_issued/4,
         presence_probe_hook/3,
         pubsub_create_node/5,
         pubsub_delete_node/4,
         pubsub_publish_item/6,
         pubsub_subscribe_node/5,
         pubsub_unsubscribe_node/5,
         register_user/2,
         remove_room/3,
         remove_user/2,
         reopen_log_hook/0,
         roster_out_subscription/1,
         rotate_log_hook/0,
         route_registered/1,
         route_unregistered/1,
         s2s_send_packet/1,
         set_presence_hook/4,
         sm_register_connection_hook/3,
         sm_remove_connection_hook/3,
         unset_presence_hook/4,
         user_ping_timeout/1,
         xabber_oauth_token_issued/6]).

%% run_fold hooks
-export([adhoc_local_commands/4,
         adhoc_local_items/4,
         adhoc_sm_commands/4,
         adhoc_sm_items/4,
         c2s_auth_result/3,
         c2s_authenticated_packet/2,
         c2s_closed/2,
         c2s_copy_session/2,
         c2s_filter_send/1,
         c2s_handle_call/3,
         c2s_handle_cast/2,
         c2s_handle_cdata/2,
         c2s_handle_info/2,
         c2s_handle_recv/3,
         c2s_handle_send/3,
         c2s_init/2,
         c2s_post_auth_features/2,
         c2s_pre_auth_features/2,
         c2s_presence_in/2,
         c2s_self_presence/1,
         c2s_session_opened/1,
         c2s_session_pending/1,
         c2s_session_resumed/1,
         c2s_stream_started/2,
         c2s_terminated/2,
         c2s_unauthenticated_packet/2,
         c2s_unbinded_packet/2,
         change_user_settings/6,
         chat_status_options/2,
         component_init/2,
         component_send_packet/1,
         create_groupchat/5,
         csi_activity/2,
         disco_info/5,
         disco_local_features/5,
         disco_local_identity/5,
         disco_local_items/5,
         disco_sm_features/5,
         disco_sm_identity/5,
         disco_sm_items/5,
         ejabberd_ctl_process/2,
         filter_packet/1,
         get_previous_id/5,
         get_room_config/4,
         groupchat_block_hook/2,
         groupchat_default_rights_form/5,
         groupchat_info/4,
         groupchat_info_change/5,
         groupchat_invite_hook/2,
         groupchat_message_hook/2,
         groupchat_peer_to_peer/4,
         groupchat_presence_hook/2,
         groupchat_presence_subscribed_hook/2,
         groupchat_presence_unsubscribed_hook/2,
         groupchat_unblock_hook/2,
         groupchat_update_user_hook/8,
         groupchat_user_change_own_avatar/3,
         groupchat_user_change_some_avatar/4,
         http_request_handlers/3,
         http_upload_slot_request/5,
         message_is_archived/3,
         muc_filter_message/3,
         muc_filter_presence/3,
         muc_process_iq/2,
         offline_message_hook/1,
         privacy_check_packet/4,
         receive_message_stored/1,
         replace_message/2,
         request_change_user_settings/6,
         request_own_rights/5,
         retract_all/2,
         retract_all_in_messages/6,
         retract_all_messages/6,
         retract_local_message/6,
         retract_message/2,
         retract_query/2,
         retract_user/2,
         rewrite_local_message/6,
         roster_get/2,
         roster_get_jid_info/4,
         roster_groups/2,
         roster_in_subscription/2,
         roster_process_item/2,
         roster_remote_access/2,
         s2s_allow_host/3,
         s2s_in_auth_result/3,
         s2s_in_authenticated_packet/2,
         s2s_in_closed/2,
         s2s_in_handle_call/3,
         s2s_in_handle_cast/2,
         s2s_in_handle_cdata/2,
         s2s_in_handle_info/2,
         s2s_in_handle_recv/3,
         s2s_in_handle_send/3,
         s2s_in_init/2,
         s2s_in_post_auth_features/2,
         s2s_in_pre_auth_features/2,
         s2s_in_unauthenticated_packet/2,
         s2s_out_auth_result/2,
         s2s_out_closed/2,
         s2s_out_downgraded/2,
         s2s_out_handle_call/3,
         s2s_out_handle_cast/2,
         s2s_out_handle_cdata/2,
         s2s_out_handle_info/2,
         s2s_out_handle_recv/3,
         s2s_out_handle_send/3,
         s2s_out_init/2,
         s2s_out_packet/2,
         s2s_receive_packet/1,
         sasl_success/2,
         save_previous_id/4,
         sent_message_stored/5,
         set_groupchat_default_rights/5,
         set_room_option/3,
         sm_receive_packet/1,
         store_mam_message/6,
         store_offline_message/1,
         synchronization_request/5,
         unique_received/2,
         user_receive_packet/1,
         user_send_packet/1,
         vcard_iq_set/1,
         webadmin_menu_host/3,
         webadmin_menu_hostnode/4,
         webadmin_menu_main/2,
         webadmin_menu_node/3,
         webadmin_page_host/3,
         webadmin_page_hostnode/6,
         webadmin_page_main/2,
         webadmin_page_node/5,
         webadmin_user/4,
         webadmin_user_parse_query/5]).

%% called at src/rest.erl:127
backend_api_call(_, _, _) -> ok.

%% called at src/rest.erl:141
backend_api_error(_, _, _) -> ok.

%% called at src/rest.erl:132
backend_api_response_time(_, _, _, _) -> ok.

%% called at src/rest.erl:138
backend_api_timeout(_, _, _) -> ok.

%% -spec mod_pubsub:caps_add(jid(), jid(), [binary()]) -> ok.
%% called at src/mod_caps.erl:234
caps_add(A, B, C) ->
    mod_pubsub:caps_add(A, B, C).

%% -spec mod_pubsub:caps_update(jid(), jid(), [binary()]) -> ok.
%% called at src/mod_caps.erl:239
caps_update(A, B, C) ->
    mod_pubsub:caps_update(A, B, C).

%% -spec mod_privilege:component_connected(binary()) -> ok.
%% -spec mod_delegation:component_connected(binary()) -> ok.
%% called at src/ejabberd_service.erl:174
component_connected(A) ->
    mod_privilege:component_connected(A),
    mod_delegation:component_connected(A).

%% -spec mod_privilege:component_disconnected(binary(), binary()) -> ok.
%% -spec mod_delegation:component_disconnected(binary(), binary()) -> ok.
%% called at src/ejabberd_service.erl:238
component_disconnected(A, B) ->
    mod_privilege:component_disconnected(A, B),
    mod_delegation:component_disconnected(A, B).

%% -spec acl:reload_from_config() -> ok.
%% -spec ejabberd_rdbms:config_reloaded() -> ok.
%% -spec shaper:load_from_config() -> ok | {error, any()}.
%% -spec ejabberd_acme:register_certfiles() -> ok.
%% -spec ejabberd_router:config_reloaded() -> ok.
%% -spec ejabberd_router:config_reloaded() -> ok.
%% -spec gen_mod:config_reloaded() -> ok.
%% -spec ejabberd_sm:config_reloaded() -> ok.
%% -spec ejabberd_access_permissions:invalidate() -> ok.
%% called at src/ejabberd_config.erl:218
config_reloaded() ->
    acl:reload_from_config(),
    ejabberd_riak_sup:config_reloaded(),
    ejabberd_redis_sup:config_reloaded(),
    ejabberd_rdbms:config_reloaded(),
    shaper:load_from_config(),
    ejabberd_pkix:config_reloaded(),
    ejabberd_acme:register_certfiles(),
    ejabberd_auth:config_reloaded(),
    ejabberd_oauth:config_reloaded(),
    ejabberd_router:config_reloaded(),
    ejabberd_router:config_reloaded(),
    gen_mod:config_reloaded(),
    ejabberd_captcha:config_reloaded(),
    ejabberd_sm:config_reloaded(),
    ejabberd_listener:config_reloaded(),
    ejabberd_access_permissions:invalidate().

%% called at src/mod_muc.erl:270
create_room(_, _, _) -> ok.

%% called at src/ejabberd_c2s.erl:407
forbidden_session_hook(_) -> ok.

%% called at src/mod_groupchat_iq_handler.erl:709
groupchat_changed(A, B, C, D) ->
    mod_groupchat_presence:groupchat_changed(A, B, C, D),
    mod_groupchat_service_message:groupchat_changed(A, B, C, D).

%% called at src/mod_groupchat_iq_handler.erl:83
groupchat_created(A, B, C, D) ->
    mod_groupchat_service_message:chat_created(A, B, C, D),
    mod_groupchat_presence:chat_created(A, B, C, D).

%% called at src/mod_groupchat_messages.erl:325
groupchat_got_displayed(A, B, C) ->
    mod_xep_ccc:groupchat_got_displayed(A, B, C).

%% called at src/mod_groupchat_messages.erl:497
groupchat_send_message(A, B, C) ->
    mod_xep_ccc:groupchat_send_message(A, B, C).

%% -spec ejabberd_sm:host_down(binary()) -> ok.
%% -spec gen_mod:stop_modules(binary()) -> ok.
%% -spec ejabberd_rdbms:stop_host(binary()) -> ok.
%% called at src/ejabberd_config.erl:216
host_down(A) ->
    ejabberd_captcha:host_down(A),
    ejabberd_s2s:host_down(A),
    ejabberd_sm:host_down(A),
    gen_mod:stop_modules(A),
    ejabberd_auth:host_down(A),
    ejabberd_rdbms:stop_host(A),
    ejabberd_local:host_down(A).

%% -spec ejabberd_rdbms:start_host(binary()) -> ok.
%% -spec gen_mod:start_modules(binary()) -> ok.
%% -spec ejabberd_sm:host_up(binary()) -> ok.
%% called at src/ejabberd_config.erl:212
host_up(A) ->
    ejabberd_local:host_up(A),
    ejabberd_riak_sup:host_up(A),
    ejabberd_redis_sup:host_up(A),
    ejabberd_rdbms:start_host(A),
    ejabberd_auth:host_up(A),
    gen_mod:start_modules(A),
    ejabberd_s2s:host_up(A),
    ejabberd_captcha:host_up(A),
    ejabberd_sm:host_up(A).

%% called at src/ejabberd_http.erl:376
http_request_debug(_) -> ok.

%% called at src/mod_xep_rrr.erl:184
iq_result_from_remote_server(A) ->
    mod_xep_ccc:iq_result_from_remote_server(A).

%% called at src/mod_muc_room.erl:4242
join_room(_, _, _, _) -> ok.

%% called at src/mod_muc_room.erl:4250
leave_room(_, _, _, _) -> ok.

%% -spec mod_privilege:process_message(stanza()) -> stop | ok.
%% -spec mod_announce:announce(stanza()) -> ok | stop.
%% -spec ejabberd_local:bounce_resource_packet(stanza()) -> ok | stop.
%% called at src/ejabberd_local.erl:204
local_send_to_resource_hook(A) ->
    mod_privilege:process_message(A),
    mod_announce:announce(A),
    ejabberd_local:bounce_resource_packet(A).

%% called at src/mod_muc_room.erl:4188
muc_invite(_, _, _, _, _) -> ok.

%% called at src/ejabberd_oauth.erl:118
oauth_token_issued(A, B, C, D) ->
    mod_x_auth_token:oauth_token_issued(A, B, C, D).

%% -spec mod_pubsub:presence_probe(jid(), jid(), pid()) -> ok.
%% called at src/ejabberd_c2s.erl:638
presence_probe_hook(A, B, C) ->
    mod_pubsub:presence_probe(A, B, C).

%% called at src/mod_pubsub.erl:1536
pubsub_create_node(_, _, _, _, _) -> ok.

%% called at src/mod_pubsub.erl:1610
pubsub_delete_node(_, _, _, _) -> ok.

%% called at src/mod_pubsub.erl:1826
pubsub_publish_item(A, B, C, D, E, F) ->
    mod_avatar:pubsub_publish_item(A, B, C, D, E, F).

%% called at src/mod_pubsub.erl:1709
pubsub_subscribe_node(_, _, _, _, _) -> ok.

%% called at src/mod_pubsub.erl:1749
pubsub_unsubscribe_node(_, _, _, _, _) -> ok.

%% -spec mod_metrics:register_user(binary(), binary()) -> any().
%% -spec mod_shared_roster:register_user(binary(), binary()) -> ok.
%% -spec mod_last:register_user(binary(), binary()) -> any().
%% called at src/ejabberd_auth.erl:273
register_user(A, B) ->
    mod_metrics:register_user(A, B),
    mod_shared_roster:register_user(A, B),
    mod_last:register_user(A, B).

%% -spec mod_mam:remove_room(binary(), binary(), binary()) -> ok.
%% called at src/mod_muc.erl:177
remove_room(A, B, C) ->
    mod_mam:remove_room(A, B, C).

%% -spec mod_metrics:remove_user(binary(), binary()) -> any().
%% -spec mod_shared_roster:remove_user(binary(), binary()) -> ok.
%% -spec mod_roster:remove_user(binary(), binary()) -> ok.
%% -spec mod_vcard:remove_user(binary(), binary()) -> ok.
%% -spec mod_private:remove_user(binary(), binary()) -> ok.
%% -spec mod_last:remove_user(binary(), binary()) -> any().
%% -spec mod_pubsub:remove_user(binary(), binary()) -> ok.
%% -spec mod_privacy:remove_user(binary(), binary()) -> ok.
%% -spec mod_vcard_xupdate:remove_user(binary(), binary()) -> ok.
%% -spec mod_offline:remove_user(binary(), binary()) -> ok.
%% -spec mod_http_upload:remove_user(binary(), binary()) -> ok.
%% -spec mod_push:remove_user(binary(), binary()) -> ok | {error, err_reason()}.
%% -spec mod_mam:remove_user(binary(), binary()) -> ok.
%% -spec ejabberd_sm:disconnect_removed_user(binary(), binary()) -> ok.
%% called at src/ejabberd_auth.erl:432
remove_user(A, B) ->
    mod_metrics:remove_user(A, B),
    mod_shared_roster:remove_user(A, B),
    mod_roster:remove_user(A, B),
    mod_vcard:remove_user(A, B),
    mod_private:remove_user(A, B),
    mod_last:remove_user(A, B),
    mod_pubsub:remove_user(A, B),
    mod_privacy:remove_user(A, B),
    mod_vcard_xupdate:remove_user(A, B),
    mod_offline:remove_user(A, B),
    mod_http_upload:remove_user(A, B),
    mod_push:remove_user(A, B),
    mod_mam:remove_user(A, B),
    mod_x_auth_token:remove_user(A, B),
    ejabberd_sm:disconnect_removed_user(A, B).

%% called at src/ejabberd_admin.erl:390
reopen_log_hook() ->
    mod_http_fileserver:reopen_log().

%% -spec mod_shared_roster:out_subscription(presence()) -> boolean().
%% -spec mod_shared_roster_ldap:out_subscription(presence()) -> boolean().
%% -spec mod_roster:out_subscription(presence()) -> boolean().
%% -spec mod_pubsub:out_subscription(presence()) -> any().
%% called at src/ejabberd_c2s.erl:663
roster_out_subscription(A) ->
    mod_shared_roster:out_subscription(A),
    mod_shared_roster_ldap:out_subscription(A),
    mod_roster:out_subscription(A),
    mod_pubsub:out_subscription(A).

%% called at src/ejabberd_admin.erl:394
rotate_log_hook() -> ok.

%% called at src/ejabberd_router.erl:180
route_registered(A) ->
    ejabberd_pkix:route_registered(A).

%% called at src/ejabberd_router.erl:209
route_unregistered(_) -> ok.

%% -spec mod_metrics:s2s_send_packet(stanza()) -> any().
%% called at src/ejabberd_s2s.erl:379
s2s_send_packet(A) ->
    mod_metrics:s2s_send_packet(A).

%% called at src/ejabberd_sm.erl:293
set_presence_hook(_, _, _, _) -> ok.

%% -spec mod_metrics:sm_register_connection_hook(ejabberd_sm:sid(), jid(), ejabberd_sm:info()) -> any().
%% -spec ejabberd_auth_anonymous:register_connection(ejabberd_sm:sid(), jid(), ejabberd_sm:info()) -> ok.
%% -spec mod_ping:user_online(ejabberd_sm:sid(), jid(), ejabberd_sm:info()) -> ok.
%% called at src/ejabberd_sm.erl:161
sm_register_connection_hook(A, B, C) ->
    mod_metrics:sm_register_connection_hook(A, B, C),
    ejabberd_auth_anonymous:register_connection(A, B, C),
    mod_ping:user_online(A, B, C).

%% -spec mod_metrics:sm_remove_connection_hook(ejabberd_sm:sid(), jid(), ejabberd_sm:info()) -> any().
%% -spec node_online:user_offline(ejabberd_sm:sid(), jid(), ejabberd_sm:info()) -> _.
%% -spec ejabberd_auth_anonymous:unregister_connection(ejabberd_sm:sid(), jid(), ejabberd_sm:info()) -> any().
%% -spec mod_ping:user_offline(ejabberd_sm:sid(), jid(), ejabberd_sm:info()) -> ok.
%% called at src/ejabberd_sm.erl:185
sm_remove_connection_hook(A, B, C) ->
    mod_metrics:sm_remove_connection_hook(A, B, C),
    node_online:user_offline(A, B, C),
    ejabberd_auth_anonymous:unregister_connection(A, B, C),
    mod_ping:user_offline(A, B, C).

%% -spec mod_carboncopy:remove_connection(binary(), binary(), binary(), binary()) -> ok.
%% -spec mod_shared_roster:unset_presence(binary(), binary(), binary(), binary()) -> ok.
%% -spec mod_last:on_presence_update(binary(), binary(), binary(), binary()) -> any().
%% called at src/ejabberd_sm.erl:314
unset_presence_hook(A, B, C, D) ->
    mod_carboncopy:remove_connection(A, B, C, D),
    mod_shared_roster:unset_presence(A, B, C, D),
    mod_last:on_presence_update(A, B, C, D).

%% called at src/mod_ping.erl:128
user_ping_timeout(_) -> ok.

%% called at src/mod_xabber_api.erl:365
xabber_oauth_token_issued(A, B, C, D, E, F) ->
    mod_x_auth_token:xabber_oauth_token_issued(A, B, C, D, E, F).

%% -spec mod_configure:adhoc_local_commands(adhoc_command(), jid(), jid(), adhoc_command()) ->
%% 				  adhoc_command() | {error, stanza_error()}.
%% -spec mod_announce:announce_commands(empty | adhoc_command(), jid(), jid(), adhoc_command()) ->
%% 			       adhoc_command() | {error, stanza_error()}.
%% -spec mod_adhoc:ping_command(adhoc_command(), jid(), jid(), adhoc_command()) ->
%% 			  adhoc_command() | {error, stanza_error()}.
%% called at src/mod_adhoc.erl:218
adhoc_local_commands(Acc0, A, B, C) ->
    Acc1 = mod_configure:adhoc_local_commands(Acc0, A, B, C),
    Acc2 = mod_announce:announce_commands(Acc1, A, B, C),
    Acc3 = mod_adhoc:ping_command(Acc2, A, B, C),
    Acc3.

%% -spec mod_configure:adhoc_local_items(empty | {error, stanza_error()} | {result, [disco_item()]},
%% 			jid(), jid(), binary()) -> {error, stanza_error()} |
%% 						   {result, [disco_item()]} |
%% 						   empty.
%% -spec mod_announce:announce_items(empty | {error, stanza_error()} | {result, [disco_item()]},
%% 			jid(), jid(), binary()) -> {error, stanza_error()} |
%% 						   {result, [disco_item()]} |
%% 						   empty.
%% -spec mod_adhoc:ping_item(empty | {error, stanza_error()} | {result, [disco_item()]},
%% 		jid(), jid(), binary()) -> {result, [disco_item()]}.
%% called at src/mod_adhoc.erl:113
adhoc_local_items(Acc0, A, B, C) ->
    Acc1 = mod_configure:adhoc_local_items(Acc0, A, B, C),
    Acc2 = mod_announce:announce_items(Acc1, A, B, C),
    Acc3 = mod_adhoc:ping_item(Acc2, A, B, C),
    Acc3.

%% -spec mod_configure:adhoc_sm_commands(adhoc_command(), jid(), jid(), adhoc_command()) -> adhoc_command().
%% called at src/mod_adhoc.erl:221
adhoc_sm_commands(Acc0, A, B, C) ->
    Acc1 = mod_configure:adhoc_sm_commands(Acc0, A, B, C),
    Acc1.

%% -spec mod_configure:adhoc_sm_items(empty | {error, stanza_error()} | {result, [disco_item()]},
%% 		     jid(), jid(), binary()) -> {error, stanza_error()} |
%% 						{result, [disco_item()]} |
%% 						empty.
%% called at src/mod_adhoc.erl:141
adhoc_sm_items(Acc0, A, B, C) ->
    Acc1 = mod_configure:adhoc_sm_items(Acc0, A, B, C),
    Acc1.

%% -spec mod_fail2ban:c2s_auth_result(ejabberd_c2s:state(), boolean(), binary())
%%       -> ejabberd_c2s:state() | {stop, ejabberd_c2s:state()}.
%% called at src/ejabberd_c2s.erl:450
c2s_auth_result(Acc0, A, B) ->
    Acc1 = mod_fail2ban:c2s_auth_result(Acc0, A, B),
    Acc1.

%% -spec mod_client_state:c2s_authenticated_packet(c2s_state(), xmpp_element()) -> c2s_state().
%% called at src/ejabberd_c2s.erl:464
c2s_authenticated_packet(Acc0, A) ->
    Acc1 = mod_client_state:c2s_authenticated_packet(Acc0, A),
    Acc2 = mod_stream_mgmt:c2s_authenticated_packet(Acc1, A),
    Acc2.

%% called at src/ejabberd_c2s.erl:429
c2s_closed(Acc0, A) ->
    Acc1 = mod_stream_mgmt:c2s_closed(Acc0, A),
    Acc2 = ejabberd_c2s:process_closed(Acc1, A),
    Acc2.

%% -spec mod_privacy:c2s_copy_session(c2s_state(), c2s_state()) -> c2s_state().
%% -spec mod_offline:c2s_copy_session(c2s_state(), c2s_state()) -> c2s_state().
%% -spec mod_client_state:c2s_copy_session(c2s_state(), c2s_state()) -> c2s_state().
%% -spec mod_push:c2s_copy_session(c2s_state(), c2s_state()) -> c2s_state().
%% -spec mod_push_keepalive:c2s_copy_session(c2s_state(), c2s_state()) -> c2s_state().
%% called at src/ejabberd_c2s.erl:200
c2s_copy_session(Acc0, A) ->
    Acc1 = mod_privacy:c2s_copy_session(Acc0, A),
    Acc2 = mod_offline:c2s_copy_session(Acc1, A),
    Acc3 = mod_client_state:c2s_copy_session(Acc2, A),
    Acc4 = mod_push:c2s_copy_session(Acc3, A),
    Acc5 = mod_push_keepalive:c2s_copy_session(Acc4, A),
    Acc5.

%% -spec mod_client_state:filter_presence(filter_acc()) -> filter_acc().
%% -spec mod_client_state:filter_chat_states(filter_acc()) -> filter_acc().
%% -spec mod_client_state:filter_pep(filter_acc()) -> filter_acc().
%% -spec mod_client_state:filter_presence(filter_acc()) -> filter_acc().
%% -spec mod_client_state:filter_chat_states(filter_acc()) -> filter_acc().
%% -spec mod_client_state:filter_pep(filter_acc()) -> filter_acc().
%% -spec mod_client_state:filter_other(filter_acc()) -> filter_acc().
%% called at src/ejabberd_c2s.erl:144
c2s_filter_send(Acc0) ->
    Acc1 = mod_client_state:filter_presence(Acc0),
    Acc2 = mod_client_state:filter_chat_states(Acc1),
    Acc3 = mod_client_state:filter_pep(Acc2),
    Acc4 = mod_client_state:filter_presence(Acc3),
    Acc5 = mod_client_state:filter_chat_states(Acc4),
    Acc6 = mod_client_state:filter_pep(Acc5),
    Acc7 = mod_client_state:filter_other(Acc6),
    Acc7.

%% called at src/ejabberd_c2s.erl:550
c2s_handle_call(Acc0, A, B) ->
    Acc1 = mod_stream_mgmt:c2s_handle_call(Acc0, A, B),
    Acc1.

%% -spec mod_push_keepalive:c2s_handle_cast(c2s_state(), any()) -> c2s_state().
%% -spec mod_push:c2s_handle_cast(c2s_state(), any()) -> c2s_state() | {stop, c2s_state()}.
%% called at src/ejabberd_c2s.erl:554
c2s_handle_cast(Acc0, A) ->
    Acc1 = mod_push_keepalive:c2s_handle_cast(Acc0, A),
    Acc2 = mod_push:c2s_handle_cast(Acc1, A),
    Acc3 = ejabberd_c2s:handle_unexpected_cast(Acc2, A),
    Acc3.

%% called at src/ejabberd_c2s.erl:494
c2s_handle_cdata(Acc, _) -> Acc.

%% -spec mod_pubsub:c2s_handle_info(ejabberd_c2s:state(), term()) -> ejabberd_c2s:state().
%% -spec mod_offline:c2s_handle_info(c2s_state(), term()) -> c2s_state().
%% -spec mod_push_keepalive:c2s_handle_info(c2s_state(), any()) -> c2s_state() | {stop, c2s_state()}.
%% called at src/ejabberd_c2s.erl:557
c2s_handle_info(Acc0, A) ->
    Acc1 = mod_pubsub:c2s_handle_info(Acc0, A),
    Acc2 = mod_offline:c2s_handle_info(Acc1, A),
    Acc3 = ejabberd_sm:c2s_handle_info(Acc2, A),
    Acc4 = mod_stream_mgmt:c2s_handle_info(Acc3, A),
    Acc5 = mod_push_keepalive:c2s_handle_info(Acc4, A),
    Acc6 = ejabberd_c2s:process_info(Acc5, A),
    Acc6.

%% called at src/ejabberd_c2s.erl:498
c2s_handle_recv(Acc0, A, B) ->
    Acc1 = mod_stream_mgmt:c2s_handle_recv(Acc0, A, B),
    Acc2 = mod_x_auth_token:c2s_handle_recv(Acc1, A, B),
    Acc2.

%% -spec mod_push:c2s_stanza(c2s_state(), xmpp_element() | xmlel(), term()) -> c2s_state().
%% -spec mod_push_keepalive:c2s_stanza(c2s_state(), xmpp_element() | xmlel(), term()) -> c2s_state().
%% called at src/ejabberd_c2s.erl:501
c2s_handle_send(Acc0, A, B) ->
    Acc1 = mod_push:c2s_stanza(Acc0, A, B),
    Acc2 = mod_stream_mgmt:c2s_handle_send(Acc1, A, B),
    Acc3 = mod_push_keepalive:c2s_stanza(Acc2, A, B),
    Acc3.

%% called at src/ejabberd_c2s.erl:535
c2s_init(Acc0, A) ->
    Acc1 = mod_stream_mgmt:c2s_stream_init(Acc0, A),
    Acc1.

%% -spec mod_roster:get_versioning_feature([xmpp_element()], binary()) -> [xmpp_element()].
%% -spec mod_client_state:add_stream_feature([xmpp_element()], binary()) -> [xmpp_element()].
%% -spec mod_caps:caps_stream_features([xmpp_element()], binary()) -> [xmpp_element()].
%% called at src/ejabberd_c2s.erl:360
c2s_post_auth_features(Acc0, A) ->
    Acc1 = mod_roster:get_versioning_feature(Acc0, A),
    Acc2 = mod_xep_ccc:c2s_stream_features(Acc1, A),
    Acc3 = mod_x_auth_token:c2s_stream_features(Acc2, A),
    Acc4 = mod_client_state:add_stream_feature(Acc3, A),
    Acc5 = mod_stream_mgmt:c2s_stream_features(Acc4, A),
    Acc6 = mod_caps:caps_stream_features(Acc5, A),
    Acc6.

%% -spec mod_register:stream_feature_register([xmpp_element()], binary()) -> [xmpp_element()].
%% -spec mod_legacy_auth:c2s_stream_features([xmpp_element()], binary()) -> [xmpp_element()].
%% called at src/ejabberd_c2s.erl:357
c2s_pre_auth_features(Acc0, A) ->
    Acc1 = mod_register:stream_feature_register(Acc0, A),
    Acc2 = mod_legacy_auth:c2s_stream_features(Acc1, A),
    Acc2.

%% -spec mod_caps:c2s_presence_in(ejabberd_c2s:state(), presence()) -> ejabberd_c2s:state().
%% called at src/ejabberd_c2s.erl:604
c2s_presence_in(Acc0, A) ->
    Acc1 = mod_caps:c2s_presence_in(Acc0, A),
    Acc1.

%% -spec mod_shared_roster:c2s_self_presence({presence(), ejabberd_c2s:state()})
%%       -> {presence(), ejabberd_c2s:state()}.
%% -spec mod_roster:c2s_self_presence({presence(), ejabberd_c2s:state()})
%%       -> {presence(), ejabberd_c2s:state()}.
%% -spec mod_announce:send_motd({presence(), ejabberd_c2s:state()}) -> {presence(), ejabberd_c2s:state()}.
%% -spec mod_pubsub:on_self_presence({presence(), ejabberd_c2s:state()})
%% 		    -> {presence(), ejabberd_c2s:state()}.
%% -spec mod_x_auth_token:update_presence({presence(), ejabberd_c2s:state()})
%%       -> {presence(), ejabberd_c2s:state()}.
%% -spec mod_vcard_xupdate:update_presence({presence(), ejabberd_c2s:state()})
%%       -> {presence(), ejabberd_c2s:state()}.
%% called at src/ejabberd_c2s.erl:718
c2s_self_presence(Acc0) ->
    Acc1 = mod_shared_roster:c2s_self_presence(Acc0),
    Acc2 = mod_roster:c2s_self_presence(Acc1),
    Acc3 = mod_offline:c2s_self_presence(Acc2),
    Acc4 = mod_announce:send_motd(Acc3),
    Acc5 = mod_pubsub:on_self_presence(Acc4),
    Acc6 = mod_x_auth_token:update_presence(Acc5),
    Acc7 = mod_vcard_xupdate:update_presence(Acc6),
    Acc7.

%% called at src/ejabberd_c2s.erl:401
c2s_session_opened(Acc0) ->
    Acc1 = mod_x_auth_token:check_session(Acc0),
    Acc1.

%% -spec mod_push:c2s_session_pending(c2s_state()) -> c2s_state().
%% -spec mod_push_keepalive:c2s_session_pending(c2s_state()) -> c2s_state().
%% called at src/mod_stream_mgmt.erl:461
c2s_session_pending(Acc0) ->
    Acc1 = mod_push:c2s_session_pending(Acc0),
    Acc2 = mod_push_keepalive:c2s_session_pending(Acc1),
    Acc2.

%% -spec mod_client_state:c2s_session_resumed(c2s_state()) -> c2s_state().
%% -spec mod_push_keepalive:c2s_session_resumed(c2s_state()) -> c2s_state().
%% called at src/mod_stream_mgmt.erl:441
c2s_session_resumed(Acc0) ->
    Acc1 = mod_client_state:c2s_session_resumed(Acc0),
    Acc2 = mod_push_keepalive:c2s_session_resumed(Acc1),
    Acc2.

%% -spec mod_client_state:c2s_stream_started(c2s_state(), stream_start()) -> c2s_state().
%% -spec mod_fail2ban:c2s_stream_started(ejabberd_c2s:state(), stream_start())
%%       -> ejabberd_c2s:state() | {stop, ejabberd_c2s:state()}.
%% called at src/ejabberd_c2s.erl:423
c2s_stream_started(Acc0, A) ->
    Acc1 = mod_client_state:c2s_stream_started(Acc0, A),
    Acc2 = mod_stream_mgmt:c2s_stream_started(Acc1, A),
    Acc3 = mod_fail2ban:c2s_stream_started(Acc2, A),
    Acc3.

%% -spec mod_pubsub:on_user_offline(ejabberd_c2s:state(), atom()) -> ejabberd_c2s:state().
%% called at src/ejabberd_c2s.erl:560
c2s_terminated(Acc0, A) ->
    Acc1 = mod_stream_mgmt:c2s_terminated(Acc0, A),
    Acc2 = mod_pubsub:on_user_offline(Acc1, A),
    Acc3 = ejabberd_c2s:process_terminated(Acc2, A),
    Acc3.

%% -spec mod_legacy_auth:c2s_unauthenticated_packet(c2s_state(), iq()) ->
%%       c2s_state() | {stop, c2s_state()}.
%% called at src/ejabberd_c2s.erl:456
c2s_unauthenticated_packet(Acc0, A) ->
    Acc1 = mod_register:c2s_unauthenticated_packet(Acc0, A),
    Acc2 = mod_legacy_auth:c2s_unauthenticated_packet(Acc1, A),
    Acc3 = mod_stream_mgmt:c2s_unauthenticated_packet(Acc2, A),
    Acc4 = ejabberd_c2s:reject_unauthenticated_packet(Acc3, A),
    Acc4.

%% called at src/ejabberd_c2s.erl:453
c2s_unbinded_packet(Acc0, A) ->
    Acc1 = mod_stream_mgmt:c2s_unbinded_packet(Acc0, A),
    Acc1.

%% called at src/mod_groupchat_iq_handler.erl:567
change_user_settings(Acc0, A, B, C, D, E) ->
    Acc1 = mod_groupchat_users:check_if_exist(Acc0, A, B, C, D, E),
    Acc2 = mod_groupchat_users:check_if_request_user_exist(Acc1, A, B, C, D, E),
    Acc3 = mod_groupchat_users:validate_request(Acc2, A, B, C, D, E),
    Acc4 = mod_groupchat_users:change_user_rights(Acc3, A, B, C, D, E),
    Acc5 = mod_groupchat_service_message:user_rights_changed(Acc4, A, B, C, D, E),
    Acc5.

%% called at src/mod_groupchat_chats.erl:831
chat_status_options(Acc, _) -> Acc.

%% called at src/ejabberd_service.erl:116
component_init(Acc, _) -> Acc.

%% called at src/ejabberd_service.erl:194
component_send_packet(Acc) -> Acc.

%% called at src/mod_groupchat_iq_handler.erl:101
create_groupchat(Acc0, A, B, C, D) ->
    Acc1 = mod_groupchat_chats:check_localpart(Acc0, A, B, C, D),
    Acc2 = mod_groupchat_chats:check_unsupported_stanzas(Acc1, A, B, C, D),
    Acc3 = mod_groupchat_chats:check_params(Acc2, A, B, C, D),
    Acc4 = mod_groupchat_chats:create_chat(Acc3, A, B, C, D),
    Acc4.

%% -spec mod_client_state:csi_activity(c2s_state(), active | inactive) -> c2s_state().
%% called at src/mod_client_state.erl:204
csi_activity(Acc0, A) ->
    Acc1 = mod_client_state:csi_activity(Acc0, A),
    Acc1.

%% -spec mod_offline:get_info([xdata()], binary(), module(), binary(), binary()) -> [xdata()];
%% 	      ([xdata()], jid(), jid(), binary(), binary()) -> [xdata()].
%% -spec mod_caps:disco_info([xdata()], binary(), module(), binary(), binary()) -> [xdata()];
%% 		([xdata()], jid(), jid(), binary(), binary()) -> [xdata()].
%% -spec mod_mix:disco_info([xdata()], binary(), module(), binary(), binary()) -> [xdata()];
%% 		([xdata()], jid(), jid(), binary(), binary()) -> [xdata()].
%% -spec mod_disco:get_info([xdata()], binary(), module(), binary(), binary()) -> [xdata()];
%% 	      ([xdata()], jid(), jid(), binary(), binary()) -> [xdata()].
%% called at src/mod_disco.erl:343
disco_info(Acc0, A, B, C, D) ->
    Acc1 = mod_offline:get_info(Acc0, A, B, C, D),
    Acc2 = mod_caps:disco_info(Acc1, A, B, C, D),
    Acc3 = mod_mix:disco_info(Acc2, A, B, C, D),
    Acc4 = mod_disco:get_info(Acc3, A, B, C, D),
    Acc4.

%% -spec mod_xep_rrr:disco_sm_features(empty | {result, [binary()]} | {error, stanza_error()},
%%     jid(), jid(), binary(), binary())
%%       -> {result, [binary()]} | {error, stanza_error()}.
%% -spec mod_privacy:disco_features({error, stanza_error()} | {result, [binary()]} | empty,
%% 		     jid(), jid(), binary(), binary()) ->
%% 			    {error, stanza_error()} | {result, [binary()]}.
%% -spec mod_delegation:disco_local_features(disco_acc(), jid(), jid(), binary(), binary()) -> disco_acc().
%% -spec mod_unique:disco_sm_features({error, stanza_error()} | {result, [binary()]} | empty,
%% 		     jid(), jid(), binary(), binary()) ->
%% 			    {error, stanza_error()} | {result, [binary()]}.
%% -spec mod_carboncopy:disco_features({error, stanza_error()} | {result, [binary()]} | empty,
%% 		     jid(), jid(), binary(), binary()) ->
%% 			    {error, stanza_error()} | {result, [binary()]}.
%% -spec mod_blocking:disco_features({error, stanza_error()} | {result, [binary()]} | empty,
%% 		     jid(), jid(), binary(), binary()) ->
%% 			    {error, stanza_error()} | {result, [binary()]}.
%% -spec mod_pubsub:disco_local_features({error, stanza_error()} | {result, [binary()]} | empty,
%% 			   jid(), jid(), binary(), binary()) ->
%% 				  {error, stanza_error()} | {result, [binary()]} | empty.
%% -spec mod_caps:disco_features({error, stanza_error()} | {result, [binary()]} | empty,
%% 		     jid(), jid(),
%% 		     binary(), binary()) ->
%% 			    {error, stanza_error()} | {result, [binary()]} | empty.
%% -spec mod_adhoc:get_local_features({error, stanza_error()} | {result, [binary()]} | empty,
%% 			 jid(), jid(), binary(), binary()) ->
%% 				{error, stanza_error()} | {result, [binary()]} | empty.
%% -spec mod_mix:disco_features({error, stanza_error()} | {result, [binary()]} | empty,
%% 		     jid(), jid(), binary(), binary()) -> {result, [binary()]}.
%% -spec mod_vcard:disco_features({error, stanza_error()} | {result, [binary()]} | empty,
%% 		     jid(), jid(), binary(), binary()) ->
%% 			    {error, stanza_error()} | {result, [binary()]}.
%% -spec mod_disco:get_local_features(features_acc(), jid(), jid(), binary(), binary()) ->
%% 				{error, stanza_error()} | {result, [binary()]}.
%% called at src/mod_disco.erl:169
disco_local_features(Acc0, A, B, C, D) ->
    Acc1 = mod_xep_rrr:disco_sm_features(Acc0, A, B, C, D),
    Acc2 = mod_groupchat_discovery:get_local_features(Acc1, A, B, C, D),
    Acc3 = mod_privacy:disco_features(Acc2, A, B, C, D),
    Acc4 = mod_configure:get_local_features(Acc3, A, B, C, D),
    Acc5 = mod_delegation:disco_local_features(Acc4, A, B, C, D),
    Acc6 = mod_offline:get_sm_features(Acc5, A, B, C, D),
    Acc7 = mod_announce:disco_features(Acc6, A, B, C, D),
    Acc8 = mod_unique:disco_sm_features(Acc7, A, B, C, D),
    Acc9 = mod_carboncopy:disco_features(Acc8, A, B, C, D),
    Acc10 = mod_blocking:disco_features(Acc9, A, B, C, D),
    Acc11 = mod_pubsub:disco_local_features(Acc10, A, B, C, D),
    Acc12 = mod_caps:disco_features(Acc11, A, B, C, D),
    Acc13 = mod_adhoc:get_local_features(Acc12, A, B, C, D),
    Acc14 = mod_mix:disco_features(Acc13, A, B, C, D),
    Acc15 = mod_vcard:disco_features(Acc14, A, B, C, D),
    Acc16 = mod_disco:get_local_features(Acc15, A, B, C, D),
    Acc16.

%% -spec mod_groupchat_discovery:get_local_identity(disco_acc(), jid(), jid(), binary(), binary()) -> disco_acc().
%% -spec mod_delegation:disco_local_identity(disco_acc(), jid(), jid(), binary(), binary()) -> disco_acc().
%% -spec mod_pubsub:disco_local_identity([identity()], jid(), jid(),
%% 			   binary(), binary()) -> [identity()].
%% -spec mod_caps:disco_identity([identity()], jid(), jid(),
%% 		     binary(), binary()) ->
%% 			    [identity()].
%% -spec mod_vcard:disco_identity([identity()], jid(), jid(),
%% 		     binary(),  binary()) -> [identity()].
%% -spec mod_disco:get_local_identity([identity()], jid(), jid(),
%% 			 binary(), binary()) ->	[identity()].
%% called at src/mod_disco.erl:165
disco_local_identity(Acc0, A, B, C, D) ->
    Acc1 = mod_groupchat_discovery:get_local_identity(Acc0, A, B, C, D),
    Acc2 = mod_configure:get_local_identity(Acc1, A, B, C, D),
    Acc3 = mod_delegation:disco_local_identity(Acc2, A, B, C, D),
    Acc4 = mod_announce:disco_identity(Acc3, A, B, C, D),
    Acc5 = mod_pubsub:disco_local_identity(Acc4, A, B, C, D),
    Acc6 = mod_caps:disco_identity(Acc5, A, B, C, D),
    Acc7 = mod_adhoc:get_local_identity(Acc6, A, B, C, D),
    Acc8 = mod_mix:disco_identity(Acc7, A, B, C, D),
    Acc9 = mod_vcard:disco_identity(Acc8, A, B, C, D),
    Acc10 = mod_disco:get_local_identity(Acc9, A, B, C, D),
    Acc10.

%% -spec mod_pubsub:disco_local_items({error, stanza_error()} | {result, [disco_item()]} | empty,
%% 			jid(), jid(), binary(), binary()) ->
%% 			       {error, stanza_error()} | {result, [disco_item()]} | empty.
%% -spec mod_vcard:disco_items({error, stanza_error()} | {result, [disco_item()]} | empty,
%% 		  jid(), jid(), binary(), binary()) ->
%% 			 {error, stanza_error()} | {result, [disco_item()]}.
%% -spec mod_disco:get_local_services(items_acc(), jid(), jid(), binary(), binary()) ->
%% 				{error, stanza_error()} | {result, [disco_item()]}.
%% called at src/mod_disco.erl:149
disco_local_items(Acc0, A, B, C, D) ->
    Acc1 = mod_groupchat_discovery:get_local_items(Acc0, A, B, C, D),
    Acc2 = mod_configure:get_local_items(Acc1, A, B, C, D),
    Acc3 = mod_announce:disco_items(Acc2, A, B, C, D),
    Acc4 = mod_pubsub:disco_local_items(Acc3, A, B, C, D),
    Acc5 = mod_adhoc:get_local_commands(Acc4, A, B, C, D),
    Acc6 = mod_mix:disco_items(Acc5, A, B, C, D),
    Acc7 = mod_vcard:disco_items(Acc6, A, B, C, D),
    Acc8 = mod_disco:get_local_services(Acc7, A, B, C, D),
    Acc8.

%% -spec mod_vcard:get_sm_features({error, stanza_error()} | empty | {result, [binary()]},
%% 		      jid(), jid(), binary(), binary()) ->
%% 			     {error, stanza_error()} | empty | {result, [binary()]}.
%% -spec mod_xep_rrr:disco_sm_features(empty | {result, [binary()]} | {error, stanza_error()},
%%     jid(), jid(), binary(), binary())
%%       -> {result, [binary()]} | {error, stanza_error()}.
%% -spec mod_avatar:get_sm_features({error, stanza_error()} | empty | {result, [binary()]},
%% 		      jid(), jid(), binary(), binary()) ->
%% 			     {error, stanza_error()} | empty | {result, [binary()]}.
%% -spec mod_x_auth_token:disco_sm_features({error, stanza_error()} | {result, [binary()]} | empty,
%%                                              jid(), jid(), binary(), binary()) ->
%%                                 {error, stanza_error()} | {result, [binary()]}.
%% -spec mod_delegation:disco_sm_features(disco_acc(), jid(), jid(), binary(), binary()) -> disco_acc().
%% -spec mod_unique:disco_sm_features({error, stanza_error()} | {result, [binary()]} | empty,
%% 		     jid(), jid(), binary(), binary()) ->
%% 			    {error, stanza_error()} | {result, [binary()]}.
%% -spec mod_groupchat_iq_handler:disco_sm_features({error, stanza_error()} | {result, [binary()]} | empty,
%%                                              jid(), jid(), binary(), binary()) ->
%%                                 {error, stanza_error()} | {result, [binary()]}.
%% -spec mod_push:disco_sm_features(empty | {result, [binary()]} | {error, stanza_error()},
%% 			jid(), jid(), binary(), binary())
%%       -> {result, [binary()]} | {error, stanza_error()}.
%% -spec mod_previous:disco_sm_features({error, stanza_error()} | {result, [binary()]} | empty,
%% 		     jid(), jid(), binary(), binary()) ->
%% 			    {error, stanza_error()} | {result, [binary()]}.
%% -spec mod_pubsub:disco_sm_features({error, stanza_error()} | {result, [binary()]} | empty,
%% 			jid(), jid(), binary(), binary()) ->
%% 			       {error, stanza_error()} | {result, [binary()]}.
%% -spec mod_mix:disco_features({error, stanza_error()} | {result, [binary()]} | empty,
%% 		     jid(), jid(), binary(), binary()) -> {result, [binary()]}.
%% -spec mod_disco:get_sm_features(features_acc(), jid(), jid(), binary(), binary()) ->
%% 			     {error, stanza_error()} | {result, [binary()]}.
%% called at src/mod_disco.erl:345
disco_sm_features(Acc0, A, B, C, D) ->
    Acc1 = mod_vcard:get_sm_features(Acc0, A, B, C, D),
    Acc2 = mod_xep_rrr:disco_sm_features(Acc1, A, B, C, D),
    Acc3 = mod_avatar:get_sm_features(Acc2, A, B, C, D),
    Acc4 = mod_x_auth_token:disco_sm_features(Acc3, A, B, C, D),
    Acc5 = mod_configure:get_sm_features(Acc4, A, B, C, D),
    Acc6 = mod_delegation:disco_sm_features(Acc5, A, B, C, D),
    Acc7 = mod_offline:get_sm_features(Acc6, A, B, C, D),
    Acc8 = mod_unique:disco_sm_features(Acc7, A, B, C, D),
    Acc9 = mod_groupchat_iq_handler:disco_sm_features(Acc8, A, B, C, D),
    Acc10 = mod_push:disco_sm_features(Acc9, A, B, C, D),
    Acc11 = mod_previous:disco_sm_features(Acc10, A, B, C, D),
    Acc12 = mod_mam:disco_sm_features(Acc11, A, B, C, D),
    Acc13 = mod_pubsub:disco_sm_features(Acc12, A, B, C, D),
    Acc14 = mod_adhoc:get_sm_features(Acc13, A, B, C, D),
    Acc15 = mod_mix:disco_features(Acc14, A, B, C, D),
    Acc16 = mod_disco:get_sm_features(Acc15, A, B, C, D),
    Acc16.

%% -spec mod_delegation:disco_sm_identity(disco_acc(), jid(), jid(), binary(), binary()) -> disco_acc().
%% -spec mod_pubsub:disco_sm_identity([identity()], jid(), jid(),
%% 			binary(), binary()) -> [identity()].
%% -spec mod_disco:get_sm_identity([identity()], jid(), jid(),
%% 		      binary(), binary()) -> [identity()].
%% called at src/mod_disco.erl:340
disco_sm_identity(Acc0, A, B, C, D) ->
    Acc1 = mod_configure:get_sm_identity(Acc0, A, B, C, D),
    Acc2 = mod_delegation:disco_sm_identity(Acc1, A, B, C, D),
    Acc3 = mod_offline:get_sm_identity(Acc2, A, B, C, D),
    Acc4 = mod_pubsub:disco_sm_identity(Acc3, A, B, C, D),
    Acc5 = mod_adhoc:get_sm_identity(Acc4, A, B, C, D),
    Acc6 = mod_mix:disco_identity(Acc5, A, B, C, D),
    Acc7 = mod_disco:get_sm_identity(Acc6, A, B, C, D),
    Acc7.

%% -spec mod_pubsub:disco_sm_items({error, stanza_error()} | {result, [disco_item()]} | empty,
%% 		     jid(), jid(), binary(), binary()) ->
%% 			    {error, stanza_error()} | {result, [disco_item()]}.
%% -spec mod_disco:get_sm_items(items_acc(), jid(), jid(), binary(), binary()) ->
%% 			  {error, stanza_error()} | {result, [disco_item()]}.
%% called at src/mod_disco.erl:273
disco_sm_items(Acc0, A, B, C, D) ->
    Acc1 = mod_configure:get_sm_items(Acc0, A, B, C, D),
    Acc2 = mod_offline:get_sm_items(Acc1, A, B, C, D),
    Acc3 = mod_pubsub:disco_sm_items(Acc2, A, B, C, D),
    Acc4 = mod_adhoc:get_sm_commands(Acc3, A, B, C, D),
    Acc5 = mod_mix:disco_items(Acc4, A, B, C, D),
    Acc6 = mod_disco:get_sm_items(Acc5, A, B, C, D),
    Acc6.

%% called at src/ejabberd_ctl.erl:300
ejabberd_ctl_process(Acc, _) -> Acc.

%% -spec mod_previous:filter_packet(stanza()) -> stanza().
%% called at src/ejabberd_router.erl:358
filter_packet(Acc0) ->
    Acc1 = mod_previous:filter_packet(Acc0),
    Acc1.

%% -spec mod_previous:get_previous_id(unknown, binary(), {binary(), binary()},
%%     chat | groupchat, jid()) -> error | null | binary().
%% called at src/mod_mam.erl:968
get_previous_id(Acc0, A, B, C, D) ->
    Acc1 = mod_previous:get_previous_id(Acc0, A, B, C, D),
    Acc1.

%% -spec mod_mam:get_room_config([muc_roomconfig:property()], mod_muc_room:state(),
%% 		      jid(), binary()) -> [muc_roomconfig:property()].
%% called at src/mod_muc_room.erl:3332
get_room_config(Acc0, A, B, C) ->
    Acc1 = mod_mam:get_room_config(Acc0, A, B, C),
    Acc1.

%% called at src/mod_groupchat_iq_handler.erl:185
groupchat_block_hook(Acc0, A) ->
    Acc1 = mod_groupchat_block:validate_domains(Acc0, A),
    Acc2 = mod_groupchat_block:validate_data(Acc1, A),
    Acc3 = mod_groupchat_block:block_iq_handler(Acc2, A),
    Acc4 = mod_groupchat_block:block_elements(Acc3, A),
    Acc5 = mod_groupchat_service_message:users_kicked(Acc4, A),
    Acc5.

%% called at src/mod_groupchat_iq_handler.erl:671
groupchat_default_rights_form(Acc0, A, B, C, D) ->
    Acc1 = mod_groupchat_default_restrictions:check_if_exist(Acc0, A, B, C, D),
    Acc2 = mod_groupchat_default_restrictions:check_if_has_rights(Acc1, A, B, C, D),
    Acc2.

%% called at src/mod_groupchat_iq_handler.erl:695
groupchat_info(Acc0, A, B, C) ->
    Acc1 = mod_groupchat_chats:check_user_rights(Acc0, A, B, C),
    Acc1.

%% called at src/mod_groupchat_iq_handler.erl:706
groupchat_info_change(Acc0, A, B, C, D) ->
    Acc1 = mod_groupchat_chats:check_user_permission(Acc0, A, B, C, D),
    Acc2 = mod_groupchat_chats:validate_fs(Acc1, A, B, C, D),
    Acc3 = mod_groupchat_chats:change_chat(Acc2, A, B, C, D),
    Acc3.

%% called at src/mod_groupchat_iq_handler.erl:297
groupchat_invite_hook(Acc0, A) ->
    Acc1 = mod_groupchat_block:is_user_blocked(Acc0, A),
    Acc2 = mod_groupchat_inspector:invite_right(Acc1, A),
    Acc3 = mod_groupchat_inspector:user_exist(Acc2, A),
    Acc4 = mod_groupchat_inspector:add_user_in_chat(Acc3, A),
    Acc5 = mod_groupchat_users:add_user_vcard(Acc4, A),
    Acc6 = mod_groupchat_inspector:send_invite(Acc5, A),
    Acc6.

%% called at src/mod_groupchat_messages.erl:118
groupchat_message_hook(Acc0, A) ->
    Acc1 = mod_groupchat_messages:check_invite(Acc0, A),
    Acc2 = mod_groupchat_messages:check_permission_write(Acc1, A),
    Acc2.

%% called at src/mod_groupchat_iq_handler.erl:117
groupchat_peer_to_peer(Acc0, A, B, C) ->
    Acc1 = mod_groupchat_chats:check_creator(Acc0, A, B, C),
    Acc2 = mod_groupchat_chats:check_chat(Acc1, A, B, C),
    Acc3 = mod_groupchat_chats:check_user(Acc2, A, B, C),
    Acc4 = mod_groupchat_chats:check_if_peer_to_peer_exist(Acc3, A, B, C),
    Acc5 = mod_groupchat_chats:create_peer_to_peer(Acc4, A, B, C),
    Acc6 = mod_groupchat_chats:send_invite(Acc5, A, B, C),
    Acc6.

%% called at src/mod_groupchat_presence.erl:270
groupchat_presence_hook(Acc0, A) ->
    Acc1 = mod_groupchat_block:block_handler(Acc0, A),
    Acc2 = mod_groupchat_access_model:model_access_handler(Acc1, A),
    Acc3 = mod_groupchat_domains:domain_access(Acc2, A),
    Acc4 = mod_groupchat_users:subscribe_user(Acc3, A),
    Acc4.

%% called at src/mod_groupchat_presence.erl:285
groupchat_presence_subscribed_hook(Acc0, A) ->
    Acc1 = mod_groupchat_block:block_handler_pre(Acc0, A),
    Acc2 = mod_groupchat_domains:domain_access_pre(Acc1, A),
    Acc3 = mod_groupchat_access_model:model_pre_access_handler(Acc2, A),
    Acc4 = mod_groupchat_users:get_vcard(Acc3, A),
    Acc5 = mod_groupchat_users:pre_approval(Acc4, A),
    Acc6 = mod_groupchat_users:is_owner(Acc5, A),
    Acc7 = mod_groupchat_service_message:user_join(Acc6, A),
    Acc7.

%% called at src/mod_groupchat_presence.erl:320
groupchat_presence_unsubscribed_hook(Acc0, A) ->
    Acc1 = mod_groupchat_users:is_lonely_owner(Acc0, A),
    Acc2 = mod_groupchat_users:delete_user(Acc1, A),
    Acc3 = mod_groupchat_service_message:user_left(Acc2, A),
    Acc4 = mod_groupchat_chats:delete_chat(Acc3, A),
    Acc4.

%% called at src/mod_groupchat_iq_handler.erl:175
groupchat_unblock_hook(Acc0, A) ->
    Acc1 = mod_groupchat_block:unblock_iq_handler(Acc0, A),
    Acc1.

%% called at src/mod_groupchat_iq_handler.erl:499
groupchat_update_user_hook(Acc0, A, B, C, D, E, F, G) ->
    Acc1 = mod_groupchat_users:validate_data(Acc0, A, B, C, D, E, F, G),
    Acc2 = mod_groupchat_users:validate_rights(Acc1, A, B, C, D, E, F, G),
    Acc3 = mod_groupchat_users:update_user(Acc2, A, B, C, D, E, F, G),
    Acc4 = mod_groupchat_service_message:user_updated(Acc3, A, B, C, D, E, F, G),
    Acc4.

%% called at src/mod_groupchat_vcard.erl:253
groupchat_user_change_own_avatar(Acc0, A, B) ->
    Acc1 = mod_groupchat_service_message:user_change_own_avatar(Acc0, A, B),
    Acc1.

%% called at src/mod_groupchat_vcard.erl:316
groupchat_user_change_some_avatar(Acc0, A, B, C) ->
    Acc1 = mod_groupchat_service_message:user_change_avatar(Acc0, A, B, C),
    Acc1.

%% called at src/ejabberd_http.erl:470
http_request_handlers(Acc0, A, B) ->
    Acc1 = acme_challenge:acme_handler(Acc0, A, B),
    Acc1.

%% -spec mod_http_upload_quota:handle_slot_request(allow | deny, jid(), binary(),
%% 			  non_neg_integer(), binary()) -> allow | deny.
%% called at src/mod_http_upload.erl:571
http_upload_slot_request(Acc0, A, B, C, D) ->
    Acc1 = mod_http_upload_quota:handle_slot_request(Acc0, A, B, C, D),
    Acc1.

%% -spec mod_mam:message_is_archived(boolean(), c2s_state(), message()) -> boolean().
%% -spec mod_mam:message_is_archived(boolean(), c2s_state(), message()) -> boolean().
%% called at src/mod_stream_mgmt.erl:610
message_is_archived(Acc0, A, B) ->
    Acc1 = mod_mam:message_is_archived(Acc0, A, B),
    Acc2 = mod_mam:message_is_archived(Acc1, A, B),
    Acc2.

%% -spec mod_mam:muc_filter_message(message(), mod_muc_room:state(),
%% 			 binary()) -> message().
%% called at src/mod_muc_room.erl:762
muc_filter_message(Acc0, A, B) ->
    Acc1 = mod_mam:muc_filter_message(Acc0, A, B),
    Acc1.

%% called at src/mod_muc_room.erl:987
muc_filter_presence(Acc, _, _) -> Acc.

%% -spec mod_mam:muc_process_iq(ignore | iq(), mod_muc_room:state()) -> ignore | iq().
%% called at src/mod_muc_room.erl:276
muc_process_iq(Acc0, A) ->
    Acc1 = mod_mam:muc_process_iq(Acc0, A),
    Acc1.

%% -spec mod_metrics:offline_message_hook({any(), message()}) -> {any(), message()}.
%% -spec mod_offline:store_packet({any(), message()}) -> {any(), message()}.
%% -spec mod_mam:offline_message({any(), message()}) -> {any(), message()}.
%% -spec ejabberd_sm:bounce_offline_message({bounce, message()} | any()) -> any().
%% called at src/ejabberd_sm.erl:789
offline_message_hook(Acc0) ->
    Acc1 = mod_metrics:offline_message_hook(Acc0),
    Acc2 = mod_block_strangers:filter_offline_msg(Acc1),
    Acc3 = mod_offline:store_packet(Acc2),
    Acc4 = mod_mam:offline_message(Acc3),
    Acc5 = ejabberd_sm:bounce_offline_message(Acc4),
    Acc5.

%% -spec mod_pres_counter:check_packet(allow | deny, ejabberd_c2s:state() | jid(),
%% 		   stanza(), in | out) -> allow | deny.
%% -spec mod_privacy:check_packet(allow | deny, c2s_state() | jid(), stanza(), in | out) -> allow | deny.
%% called at src/ejabberd_c2s.erl:829
privacy_check_packet(Acc0, A, B, C) ->
    Acc1 = mod_pres_counter:check_packet(Acc0, A, B, C),
    Acc2 = mod_last:privacy_check_packet(Acc1, A, B, C),
    Acc3 = mod_privacy:check_packet(Acc2, A, B, C),
    Acc3.

%% -spec mod_previous:receive_message_stored({ok, message()} | any())
%%         -> {ok, message()} | any().
%% -spec mod_unique:receive_message_stored({ok, message()} | any())
%%       -> {ok, message()} | any().
%% called at src/mod_mam.erl:334
receive_message_stored(Acc0) ->
    Acc1 = mod_previous:receive_message_stored(Acc0),
    Acc2 = mod_unique:receive_message_stored(Acc1),
    Acc2.

%% called at src/mod_groupchat_iq_handler.erl:660
replace_message(Acc0, A) ->
    Acc1 = mod_groupchat_retract:check_user_replace(Acc0, A),
    Acc2 = mod_groupchat_retract:check_replace_permission(Acc1, A),
    Acc3 = mod_groupchat_retract:replace_message(Acc2, A),
    Acc4 = mod_groupchat_retract:store_event_replace(Acc3, A),
    Acc5 = mod_groupchat_retract:send_notifications_replace(Acc4, A),
    Acc5.

%% called at src/mod_groupchat_iq_handler.erl:547
request_change_user_settings(Acc0, A, B, C, D, E) ->
    Acc1 = mod_groupchat_users:check_if_exist(Acc0, A, B, C, D, E),
    Acc2 = mod_groupchat_users:check_if_request_user_exist(Acc1, A, B, C, D, E),
    Acc3 = mod_groupchat_users:get_user_rights(Acc2, A, B, C, D, E),
    Acc3.

%% called at src/mod_groupchat_iq_handler.erl:535
request_own_rights(Acc0, A, B, C, D) ->
    Acc1 = mod_groupchat_users:check_if_user_exist(Acc0, A, B, C, D),
    Acc2 = mod_groupchat_users:send_user_rights(Acc1, A, B, C, D),
    Acc2.

%% called at src/mod_groupchat_iq_handler.erl:636
retract_all(Acc0, A) ->
    Acc1 = mod_groupchat_retract:check_user_before_all(Acc0, A),
    Acc2 = mod_groupchat_retract:check_user_permission_to_delete_all(Acc1, A),
    Acc3 = mod_groupchat_retract:check_pinned_messages(Acc2, A),
    Acc4 = mod_groupchat_retract:delete_messages(Acc3, A),
    Acc5 = mod_groupchat_retract:store_event(Acc4, A),
    Acc6 = mod_groupchat_retract:send_notifications(Acc5, A),
    Acc6.

%% called at src/mod_xep_rrr.erl:615
retract_all_in_messages(Acc0, A, B, C, D, E) ->
    Acc1 = mod_xep_rrr:have_right_to_delete_all_incoming(Acc0, A, B, C, D, E),
    Acc2 = mod_xep_rrr:delete_all_incoming_messages(Acc1, A, B, C, D, E),
    Acc3 = mod_xep_rrr:store_event(Acc2, A, B, C, D, E),
    Acc4 = mod_xep_rrr:notificate(Acc3, A, B, C, D, E),
    Acc4.

%% called at src/mod_xep_rrr.erl:626
retract_all_messages(Acc0, A, B, C, D, E) ->
    Acc1 = mod_xep_rrr:have_right_to_delete_all(Acc0, A, B, C, D, E),
    Acc2 = mod_xep_rrr:delete_all_message(Acc1, A, B, C, D, E),
    Acc3 = mod_xep_rrr:store_event(Acc2, A, B, C, D, E),
    Acc4 = mod_xep_rrr:notificate(Acc3, A, B, C, D, E),
    Acc4.

%% called at src/mod_xep_rrr.erl:661
retract_local_message(Acc0, A, B, C, D, E) ->
    Acc1 = mod_xep_rrr:message_exist(Acc0, A, B, C, D, E),
    Acc2 = mod_xep_rrr:delete_message(Acc1, A, B, C, D, E),
    Acc3 = mod_xep_rrr:store_event(Acc2, A, B, C, D, E),
    Acc4 = mod_xep_rrr:notificate(Acc3, A, B, C, D, E),
    Acc4.

%% called at src/mod_groupchat_iq_handler.erl:594
retract_message(Acc0, A) ->
    Acc1 = mod_groupchat_retract:check_user(Acc0, A),
    Acc2 = mod_groupchat_retract:check_user_permission(Acc1, A),
    Acc3 = mod_groupchat_retract:check_if_message_exist(Acc2, A),
    Acc4 = mod_groupchat_retract:check_if_message_pinned(Acc3, A),
    Acc5 = mod_groupchat_retract:delete_message(Acc4, A),
    Acc6 = mod_groupchat_retract:store_event(Acc5, A),
    Acc7 = mod_groupchat_retract:send_notifications(Acc6, A),
    Acc7.

%% called at src/mod_groupchat_iq_handler.erl:432
retract_query(Acc0, A) ->
    Acc1 = mod_groupchat_retract:user_in_chat(Acc0, A),
    Acc2 = mod_groupchat_retract:check_if_less(Acc1, A),
    Acc3 = mod_groupchat_retract:send_query(Acc2, A),
    Acc3.

%% called at src/mod_groupchat_iq_handler.erl:616
retract_user(Acc0, A) ->
    Acc1 = mod_groupchat_retract:check_user(Acc0, A),
    Acc2 = mod_groupchat_retract:check_user_permission_to_delete_messages(Acc1, A),
    Acc3 = mod_groupchat_retract:check_and_unpin_message(Acc2, A),
    Acc4 = mod_groupchat_retract:delete_user_messages(Acc3, A),
    Acc5 = mod_groupchat_retract:store_event(Acc4, A),
    Acc6 = mod_groupchat_retract:send_notifications(Acc5, A),
    Acc6.

%% called at src/mod_xep_rrr.erl:643
rewrite_local_message(Acc0, A, B, C, D, E) ->
    Acc1 = mod_xep_rrr:message_exist(Acc0, A, B, C, D, E),
    Acc2 = mod_xep_rrr:replace_message(Acc1, A, B, C, D, E),
    Acc3 = mod_xep_rrr:store_replace_event(Acc2, A, B, C, D, E),
    Acc4 = mod_xep_rrr:notificate_replace(Acc3, A, B, C, D, E),
    Acc4.

%% -spec mod_roster:get_user_roster([#roster{}], {binary(), binary()}) -> [#roster{}].
%% -spec mod_shared_roster:get_user_roster([#roster{}], {binary(), binary()}) -> [#roster{}].
%% -spec mod_shared_roster_ldap:get_user_roster([#roster{}], {binary(), binary()}) -> [#roster{}].
%% called at src/ejabberd_c2s.erl:797
roster_get(Acc0, A) ->
    Acc1 = mod_roster:get_user_roster(Acc0, A),
    Acc2 = mod_shared_roster:get_user_roster(Acc1, A),
    Acc3 = mod_shared_roster_ldap:get_user_roster(Acc2, A),
    Acc3.

%% -spec mod_roster:get_jid_info({subscription(), ask(), [binary()]}, binary(), binary(), jid())
%%       -> {subscription(), ask(), [binary()]}.
%% -spec mod_shared_roster:get_jid_info({subscription(), ask(), [binary()]}, binary(), binary(), jid())
%%       -> {subscription(), ask(), [binary()]}.
%% -spec mod_shared_roster_ldap:get_jid_info({subscription(), ask(), [binary()]}, binary(), binary(), jid())
%%       -> {subscription(), ask(), [binary()]}.
%% called at src/mod_mam.erl:839
roster_get_jid_info(Acc0, A, B, C) ->
    Acc1 = mod_roster:get_jid_info(Acc0, A, B, C),
    Acc2 = mod_shared_roster:get_jid_info(Acc1, A, B, C),
    Acc3 = mod_shared_roster_ldap:get_jid_info(Acc2, A, B, C),
    Acc3.

%% called at src/mod_pubsub.erl:3088
roster_groups(Acc, _) -> Acc.

%% -spec ejabberd_sm:check_in_subscription(boolean(), presence()) -> boolean() | {stop, false}.
%% -spec mod_shared_roster:in_subscription(boolean(), presence()) -> boolean().
%% -spec mod_shared_roster_ldap:in_subscription(boolean(), presence()) -> boolean().
%% -spec mod_roster:in_subscription(boolean(), presence()) -> boolean().
%% -spec mod_pubsub:in_subscription(boolean(), presence()) -> true.
%% called at src/ejabberd_sm.erl:650
roster_in_subscription(Acc0, A) ->
    Acc1 = ejabberd_sm:check_in_subscription(Acc0, A),
    Acc2 = mod_block_strangers:filter_subscription(Acc1, A),
    Acc3 = mod_shared_roster:in_subscription(Acc2, A),
    Acc4 = mod_shared_roster_ldap:in_subscription(Acc3, A),
    Acc5 = mod_roster:in_subscription(Acc4, A),
    Acc6 = mod_pubsub:in_subscription(Acc5, A),
    Acc6.

%% -spec mod_shared_roster:process_item(#roster{}, binary()) -> #roster{}.
%% -spec mod_shared_roster_ldap:process_item(#roster{}, binary()) -> #roster{}.
%% called at src/mod_roster.erl:451
roster_process_item(Acc0, A) ->
    Acc1 = mod_shared_roster:process_item(Acc0, A),
    Acc2 = mod_shared_roster_ldap:process_item(Acc1, A),
    Acc2.

%% -spec mod_privilege:roster_access(boolean(), iq()) -> boolean().
%% called at src/mod_roster.erl:153
roster_remote_access(Acc0, A) ->
    Acc1 = mod_privilege:roster_access(Acc0, A),
    Acc1.

%% called at src/ejabberd_s2s.erl:646
s2s_allow_host(Acc, _, _) -> Acc.

%% called at src/ejabberd_s2s_in.erl:208
s2s_in_auth_result(Acc, _, _) -> Acc.

%% called at src/ejabberd_s2s_in.erl:224
s2s_in_authenticated_packet(Acc0, A) ->
    Acc1 = mod_s2s_dialback:s2s_in_packet(Acc0, A),
    Acc1.

%% called at src/ejabberd_s2s_in.erl:178
s2s_in_closed(Acc0, A) ->
    Acc1 = ejabberd_s2s_in:process_closed(Acc0, A),
    Acc1.

%% called at src/ejabberd_s2s_in.erl:276
s2s_in_handle_call(Acc, _, _) -> Acc.

%% called at src/ejabberd_s2s_in.erl:284
s2s_in_handle_cast(Acc0, A) ->
    Acc1 = ejabberd_s2s_in:handle_unexpected_cast(Acc0, A),
    Acc1.

%% called at src/ejabberd_s2s_in.erl:238
s2s_in_handle_cdata(Acc, _) -> Acc.

%% called at src/ejabberd_s2s_in.erl:287
s2s_in_handle_info(Acc0, A) ->
    Acc1 = ejabberd_s2s_in:handle_unexpected_info(Acc0, A),
    Acc1.

%% called at src/ejabberd_s2s_in.erl:242
s2s_in_handle_recv(Acc0, A, B) ->
    Acc1 = mod_s2s_dialback:s2s_in_recv(Acc0, A, B),
    Acc1.

%% called at src/ejabberd_s2s_in.erl:245
s2s_in_handle_send(Acc, _, _) -> Acc.

%% called at src/ejabberd_s2s_in.erl:273
s2s_in_init(Acc, _) -> Acc.

%% -spec mod_caps:caps_stream_features([xmpp_element()], binary()) -> [xmpp_element()].
%% called at src/ejabberd_s2s_in.erl:164
s2s_in_post_auth_features(Acc0, A) ->
    Acc1 = mod_s2s_dialback:s2s_in_features(Acc0, A),
    Acc2 = mod_caps:caps_stream_features(Acc1, A),
    Acc2.

%% called at src/ejabberd_s2s_in.erl:161
s2s_in_pre_auth_features(Acc0, A) ->
    Acc1 = mod_s2s_dialback:s2s_in_features(Acc0, A),
    Acc1.

%% called at src/ejabberd_s2s_in.erl:212
s2s_in_unauthenticated_packet(Acc0, A) ->
    Acc1 = mod_s2s_dialback:s2s_in_packet(Acc0, A),
    Acc2 = ejabberd_s2s_in:reject_unauthenticated_packet(Acc1, A),
    Acc2.

%% called at src/ejabberd_s2s_out.erl:231
s2s_out_auth_result(Acc0, A) ->
    Acc1 = mod_s2s_dialback:s2s_out_auth_result(Acc0, A),
    Acc2 = ejabberd_s2s_out:process_auth_result(Acc1, A),
    Acc2.

%% called at src/ejabberd_s2s_out.erl:238
s2s_out_closed(Acc0, A) ->
    Acc1 = mod_s2s_dialback:s2s_out_closed(Acc0, A),
    Acc2 = ejabberd_s2s_out:process_closed(Acc1, A),
    Acc2.

%% called at src/ejabberd_s2s_out.erl:241
s2s_out_downgraded(Acc0, A) ->
    Acc1 = mod_s2s_dialback:s2s_out_downgraded(Acc0, A),
    Acc2 = ejabberd_s2s_out:process_downgraded(Acc1, A),
    Acc2.

%% called at src/ejabberd_s2s_out.erl:286
s2s_out_handle_call(Acc, _, _) -> Acc.

%% called at src/ejabberd_s2s_out.erl:294
s2s_out_handle_cast(Acc0, A) ->
    Acc1 = ejabberd_s2s_out:handle_unexpected_cast(Acc0, A),
    Acc1.

%% called at src/ejabberd_s2s_out.erl:249
s2s_out_handle_cdata(Acc, _) -> Acc.

%% called at src/ejabberd_s2s_out.erl:309
s2s_out_handle_info(Acc0, A) ->
    Acc1 = ejabberd_s2s_out:handle_unexpected_info(Acc0, A),
    Acc1.

%% called at src/ejabberd_s2s_out.erl:252
s2s_out_handle_recv(Acc, _, _) -> Acc.

%% called at src/ejabberd_s2s_out.erl:255
s2s_out_handle_send(Acc, _, _) -> Acc.

%% called at src/ejabberd_s2s_out.erl:283
s2s_out_init(Acc0, A) ->
    Acc1 = mod_s2s_dialback:s2s_out_init(Acc0, A),
    Acc1.

%% called at src/ejabberd_s2s_out.erl:234
s2s_out_packet(Acc0, A) ->
    Acc1 = mod_s2s_dialback:s2s_out_packet(Acc0, A),
    Acc1.

%% -spec mod_metrics:s2s_receive_packet({stanza(), ejabberd_s2s_in:state()}) ->
%% 				{stanza(), ejabberd_s2s_in:state()}.
%% -spec mod_xep_rrr:check_iq({stanza(), ejabberd_s2s_in:state()}) ->
%%   {stanza(), ejabberd_s2s_in:state()}.
%% called at src/ejabberd_s2s_in.erl:226
s2s_receive_packet(Acc0) ->
    Acc1 = mod_metrics:s2s_receive_packet(Acc0),
    Acc2 = mod_xep_rrr:check_iq(Acc1),
    Acc2.

%% called at src/xmpp_stream_in.erl:838
sasl_success(Acc0, A) ->
    Acc1 = mod_x_auth_token:sasl_success(Acc0, A),
    Acc1.

%% -spec mod_xep_rrr:save_id_in_conversation({ok, message()}, binary(),
%%     binary(), null | binary()) -> {ok, message()} | any().
%% -spec mod_previous:save_previous_id({ok, message()}, binary(),
%%     binary(), null | binary()) -> {ok, message()} | any().
%% called at src/mod_mam.erl:977
save_previous_id(Acc0, A, B, C) ->
    Acc1 = mod_xep_rrr:save_id_in_conversation(Acc0, A, B, C),
    Acc2 = mod_previous:save_previous_id(Acc1, A, B, C),
    Acc2.

%% called at src/mod_mam.erl:366
sent_message_stored(Acc0, A, B, C, D) ->
    Acc1 = mod_unique:sent_message_stored(Acc0, A, B, C, D),
    Acc1.

%% called at src/mod_groupchat_iq_handler.erl:682
set_groupchat_default_rights(Acc0, A, B, C, D) ->
    Acc1 = mod_groupchat_default_restrictions:check_if_exist(Acc0, A, B, C, D),
    Acc2 = mod_groupchat_default_restrictions:check_values(Acc1, A, B, C, D),
    Acc3 = mod_groupchat_default_restrictions:set_values(Acc2, A, B, C, D),
    Acc3.

%% -spec mod_mam:set_room_option({pos_integer(), _}, muc_roomconfig:property(), binary())
%%       -> {pos_integer(), _}.
%% called at src/mod_muc_room.erl:3406
set_room_option(Acc0, A, B) ->
    Acc1 = mod_mam:set_room_option(Acc0, A, B),
    Acc1.

%% -spec mod_mam:sm_receive_packet(stanza()) -> stanza().
%% -spec mod_xep_ccc:sm_receive_packet(stanza()) -> stanza().
%% -spec mod_push:sm_receive_packet(stanza()) -> stanza().
%% called at src/ejabberd_sm.erl:143
sm_receive_packet(Acc0) ->
    Acc1 = mod_mam:sm_receive_packet(Acc0),
    Acc2 = mod_xep_ccc:sm_receive_packet(Acc1),
    Acc3 = mod_push:sm_receive_packet(Acc2),
    Acc3.

%% -spec mod_push:mam_message(message() | drop, binary(), binary(), jid(),
%% 		  chat | groupchat, recv | send) -> message().
%% called at src/mod_mam.erl:949
store_mam_message(Acc0, A, B, C, D, E) ->
    Acc1 = mod_push:mam_message(Acc0, A, B, C, D, E),
    Acc1.

%% -spec mod_push:offline_message(message()) -> message().
%% called at src/mod_offline.erl:402
store_offline_message(Acc0) ->
    Acc1 = mod_push:offline_message(Acc0),
    Acc1.

%% called at src/mod_groupchat_iq_handler.erl:449
synchronization_request(Acc0, A, B, C, D) ->
    Acc1 = mod_xep_ccc:check_user_for_sync(Acc0, A, B, C, D),
    Acc2 = mod_xep_ccc:try_to_sync(Acc1, A, B, C, D),
    Acc3 = mod_xep_ccc:make_responce_to_sync(Acc2, A, B, C, D),
    Acc3.

%% -spec mod_previous:unique_received(message(), message()) -> message().
%% called at src/mod_unique.erl:174
unique_received(Acc0, A) ->
    Acc1 = mod_previous:unique_received(Acc0, A),
    Acc1.

%% -spec mod_metrics:user_receive_packet({stanza(), ejabberd_c2s:state()}) -> {stanza(), ejabberd_c2s:state()}.
%% -spec mod_privilege:process_presence_in({stanza(), ejabberd_c2s:state()}) -> {stanza(), ejabberd_c2s:state()}.
%% -spec mod_privacy:user_receive_packet({stanza(), c2s_state()}) -> {stanza(), c2s_state()}.
%% -spec mod_service_log:log_user_receive({stanza(), ejabberd_c2s:state()}) -> {stanza(), ejabberd_c2s:state()}.
%% -spec mod_caps:user_receive_packet({stanza(), ejabberd_c2s:state()}) -> {stanza(), ejabberd_c2s:state()}.
%% -spec mod_mam:user_receive_packet({stanza(), c2s_state()}) -> {stanza(), c2s_state()}.
%% -spec mod_carboncopy:user_receive_packet({stanza(), ejabberd_c2s:state()})
%%       -> {stanza(), ejabberd_c2s:state()} | {stop, {stanza(), ejabberd_c2s:state()}}.
%% called at src/ejabberd_c2s.erl:230
user_receive_packet(Acc0) ->
    Acc1 = mod_metrics:user_receive_packet(Acc0),
    Acc2 = mod_block_strangers:filter_packet(Acc1),
    Acc3 = mod_privilege:process_presence_in(Acc2),
    Acc4 = mod_privacy:user_receive_packet(Acc3),
    Acc5 = mod_service_log:log_user_receive(Acc4),
    Acc6 = mod_caps:user_receive_packet(Acc5),
    Acc7 = mod_mam:user_receive_packet(Acc6),
    Acc8 = mod_carboncopy:user_receive_packet(Acc7),
    Acc8.

%% -spec mod_unique:user_send_packet({stanza(), c2s_state()})
%%       -> {stanza(), c2s_state()}.
%% -spec mod_previous:user_send_packet({stanza(), c2s_state()})
%%       -> {stanza(), c2s_state()}.
%% -spec mod_metrics:user_send_packet({stanza(), ejabberd_c2s:state()}) -> {stanza(), ejabberd_c2s:state()}.
%% -spec mod_privilege:process_presence_out({stanza(), ejabberd_c2s:state()}) -> {stanza(), ejabberd_c2s:state()}.
%% -spec mod_privacy:user_send_packet({stanza(), c2s_state()}) -> {stanza(), c2s_state()}.
%% -spec mod_service_log:log_user_send({stanza(), ejabberd_c2s:state()}) -> {stanza(), ejabberd_c2s:state()}.
%% -spec mod_vcard_xupdate:user_send_packet({presence(), ejabberd_c2s:state()})
%%       -> {presence(), ejabberd_c2s:state()}.
%% -spec mod_caps:user_send_packet({stanza(), ejabberd_c2s:state()}) -> {stanza(), ejabberd_c2s:state()}.
%% -spec mod_mam:user_send_packet({stanza(), c2s_state()})
%%       -> {stanza(), c2s_state()}.
%% -spec mod_carboncopy:user_send_packet({stanza(), ejabberd_c2s:state()})
%%       -> {stanza(), ejabberd_c2s:state()} | {stop, {stanza(), ejabberd_c2s:state()}}.
%% -spec mod_ping:user_send({stanza(), ejabberd_c2s:state()}) -> {stanza(), ejabberd_c2s:state()}.
%% -spec mod_xep_ccc:user_send_packet({stanza(), c2s_state()})
%%       -> {stanza(), c2s_state()}.
%% -spec mod_mam:user_send_packet_strip_tag({stanza(), c2s_state()})
%%       -> {stanza(), c2s_state()}.
%% called at src/ejabberd_c2s.erl:467
user_send_packet(Acc0) ->
    Acc1 = mod_unique:user_send_packet(Acc0),
    Acc2 = mod_previous:user_send_packet(Acc1),
    Acc3 = mod_metrics:user_send_packet(Acc2),
    Acc4 = mod_privilege:process_presence_out(Acc3),
    Acc5 = mod_privacy:user_send_packet(Acc4),
    Acc6 = mod_service_log:log_user_send(Acc5),
    Acc7 = mod_vcard_xupdate:user_send_packet(Acc6),
    Acc8 = mod_caps:user_send_packet(Acc7),
    Acc9 = mod_mam:user_send_packet(Acc8),
    Acc10 = mod_carboncopy:user_send_packet(Acc9),
    Acc11 = mod_ping:user_send(Acc10),
    Acc12 = mod_xep_ccc:user_send_packet(Acc11),
    Acc13 = mod_mam:user_send_packet_strip_tag(Acc12),
    Acc13.

%% -spec mod_avatar:vcard_iq_convert(iq()) -> iq() | {stop, stanza_error()}.
%% -spec mod_vcard:vcard_iq_set(iq()) -> iq() | {stop, stanza_error()}.
%% -spec mod_vcard_xupdate:vcard_set(iq()) -> iq().
%% -spec mod_avatar:vcard_iq_publish(iq()) -> iq() | {stop, stanza_error()}.
%% called at src/mod_avatar.erl:365
vcard_iq_set(Acc0) ->
    Acc1 = mod_avatar:vcard_iq_convert(Acc0),
    Acc2 = mod_vcard:vcard_iq_set(Acc1),
    Acc3 = mod_vcard_xupdate:vcard_set(Acc2),
    Acc4 = mod_avatar:vcard_iq_publish(Acc3),
    Acc4.

%% called at src/ejabberd_web_admin.erl:2636
webadmin_menu_host(Acc0, A, B) ->
    Acc1 = mod_muc_admin:web_menu_host(Acc0, A, B),
    Acc2 = mod_shared_roster:webadmin_menu(Acc1, A, B),
    Acc2.

%% called at src/ejabberd_web_admin.erl:2633
webadmin_menu_hostnode(Acc, _, _, _) -> Acc.

%% called at src/ejabberd_web_admin.erl:2642
webadmin_menu_main(Acc0, A) ->
    Acc1 = mod_muc_admin:web_menu_main(Acc0, A),
    Acc1.

%% called at src/ejabberd_web_admin.erl:2639
webadmin_menu_node(Acc, _, _) -> Acc.

%% called at src/ejabberd_web_admin.erl:776
webadmin_page_host(Acc0, A, B) ->
    Acc1 = mod_shared_roster:webadmin_page(Acc0, A, B),
    Acc2 = mod_roster:webadmin_page(Acc1, A, B),
    Acc3 = mod_offline:webadmin_page(Acc2, A, B),
    Acc4 = mod_muc_admin:web_page_host(Acc3, A, B),
    Acc4.

%% called at src/ejabberd_web_admin.erl:2006
webadmin_page_hostnode(Acc, _, _, _, _, _) -> Acc.

%% called at src/ejabberd_web_admin.erl:773
webadmin_page_main(Acc0, A) ->
    Acc1 = mod_muc_admin:web_page_main(Acc0, A),
    Acc1.

%% called at src/ejabberd_web_admin.erl:2003
webadmin_page_node(Acc, _, _, _, _) -> Acc.

%% called at src/ejabberd_web_admin.erl:1394
webadmin_user(Acc0, A, B, C) ->
    Acc1 = mod_roster:webadmin_user(Acc0, A, B, C),
    Acc2 = mod_offline:webadmin_user(Acc1, A, B, C),
    Acc2.

%% called at src/ejabberd_web_admin.erl:1458
webadmin_user_parse_query(Acc0, A, B, C, D) ->
    Acc1 = mod_offline:webadmin_user_parse_query(Acc0, A, B, C, D),
    Acc1.

