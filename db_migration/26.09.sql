CREATE INDEX CONCURRENTLY i_archive_sh_user_bpeer_ctype_ts
      ON archive USING btree (server_host, username, bare_peer, conversation_type, timestamp);

DROP INDEX CONCURRENTLY IF EXISTS i_archive_sh_username_bare_peer;
DROP INDEX CONCURRENTLY IF EXISTS i_archive_sh_username_peer;

CREATE TABLE external_group_message_meta (
    group_user text NOT NULL,
    group_server text NOT NULL,
    stanza_id text NOT NULL,
    author_id text NOT NULL DEFAULT '',
    timestamp BIGINT NOT NULL,
    deleted boolean NOT NULL DEFAULT false,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    PRIMARY KEY (group_user, group_server, stanza_id)
);

CREATE INDEX i_external_group_message_meta_group_ts
    ON external_group_message_meta USING btree (group_user, group_server, timestamp)
    WHERE deleted = false;
