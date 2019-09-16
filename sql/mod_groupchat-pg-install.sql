--
-- Author Andrey Gagarin <andrey.gagarin@redsolution.ru>
-- Copyright: (C) 2018, Redsolution Inc.
-- XEP-0GGG: Group chats
--

CREATE TABLE groupchats (
    name text NOT NULL,
    localpart text NOT NULL PRIMARY KEY,
    jid text NOT NULL UNIQUE,
    anonymous text NOT NULL,
    searchable text NOT NULL,
    model text NOT NULL,
    description text,
    owner text NOT NULL,
    avatar_id text DEFAULT '',
    message bigint DEFAULT 0,
    contacts text,
    domains text,
    parent_chat text DEFAULT '0'
);


CREATE TABLE groupchat_users (
    username text NOT NULL,
    role text NOT NULL,
    id text NOT NULL,
    avatar_id text,
    avatar_type text,
    avatar_url text,
    avatar_size integer not null default 0,
    nickname text default '',
    parse_vcard timestamp NOT NULL default now(),
    parse_avatar text NOT NULL default 'yes',
    badge text,
    chatgroup text NOT NULL REFERENCES groupchats (jid) ON DELETE CASCADE,
    subscription text NOT NULL,
    p2p_state text DEFAULT 'true',
    last_seen timestamp NOT NULL default now(),
    user_updated_at timestamp NOT NULL default now(),
    CONSTRAINT UC_groupchat_users UNIQUE (username,chatgroup),
    CONSTRAINT UC_groupchat_users_id UNIQUE (id)
);

CREATE TABLE groupchat_present (
    username text NOT NULL,
    chatgroup text NOT NULL REFERENCES groupchats (jid) ON DELETE CASCADE,
    resource text NOT NULL
);

CREATE TABLE groupchat_users_vcard (
    jid text PRIMARY KEY,
    givenfamily text,
    fn text,
    nickname text,
    image text,
    hash text,
    fullupdate text
);

CREATE TABLE groupchat_rights (
    name text NOT NULL UNIQUE,
    type text NOT NULL,
    description text NOT NULL
);


CREATE TABLE groupchat_policy (
    username text NOT NULL,
    chatgroup text NOT NULL REFERENCES groupchats (jid) ON DELETE CASCADE,
    right_name text NOT NULL REFERENCES groupchat_rights(name),
    valid_from timestamp NOT NULL,
    valid_until timestamp NOT NULL,
    issued_by text NOT NULL,
    issued_at timestamp NOT NULL,
    CONSTRAINT UC_groupchat_policy UNIQUE (username,chatgroup,right_name)
);

INSERT INTO groupchat_rights (name,description,type) values
('send-messages','Send messages','restriction'),
('read-messages','Read messages','restriction'),
('owner','Owner','permission'),
('restrict-participants','Restrict participants','permission'),
('block-participants','Block participants','permission'),
('send-invitations','Send invitations','restriction'),
('send-audio','Send audio','restriction'),
('send-images','Send images','restriction'),
('administrator','Administrator','permission'),
('change-badges','Change badges','permission'),
('change-nicknames','Change nicknames','permission'),
('delete-messages','Delete messages','permission')
;

CREATE TABLE groupchat_block (
    chatgroup text NOT NULL REFERENCES groupchats (jid) ON DELETE CASCADE,
    blocked text NOT NULL,
    type text NOT NULL,
    anonim_id text,
    issued_by text NOT NULL,
    issued_at timestamp NOT NULL,
    CONSTRAINT UC_groupchat_block UNIQUE (chatgroup,blocked)
);

CREATE TABLE groupchat_log (
    chatgroup text NOT NULL REFERENCES groupchats (jid) ON DELETE CASCADE,
    username text NOT NULL,
    log_event text NOT NULL,
    happend_at timestamp NOT NULL,
    CONSTRAINT UC_groupchat_log UNIQUE (username,chatgroup,log_event),
    FOREIGN KEY (username,chatgroup) REFERENCES groupchat_users (username,chatgroup) ON DELETE CASCADE
);

CREATE TABLE groupchat_users_info(
    chatgroup text NOT NULL REFERENCES groupchats (jid) ON DELETE CASCADE,
    username text NOT NULL,
    nickname text NOT NULL,
    avatar text,
    CONSTRAINT UC_groupchat_users_info UNIQUE (username,chatgroup,nickname),
    FOREIGN KEY (username,chatgroup) REFERENCES groupchat_users (username,chatgroup) ON DELETE CASCADE
);

CREATE TABLE groupchat_default_restrictions(
    chatgroup text NOT NULL REFERENCES groupchats (jid) ON DELETE CASCADE,
    right_name text NOT NULL REFERENCES groupchat_rights(name),
    action_time text NOT NULL,
    CONSTRAINT UC_groupchat_default_restrictions UNIQUE (chatgroup,right_name)
);

CREATE TABLE groupchat_retract(
    chatgroup text,
    xml text,
    version integer,
    CONSTRAINT uc_groupchat_versions UNIQUE (chatgroup,xml,version),
    FOREIGN KEY (chatgroup) REFERENCES groupchats(jid) ON DELETE CASCADE
    );

ALTER TABLE archive ADD CONSTRAINT unique_timestamp UNIQUE (timestamp);

CREATE TABLE origin_id (
    id text NOT NULL,
    stanza_id BIGINT
      UNIQUE
      REFERENCES archive (timestamp) ON DELETE CASCADE
);

CREATE INDEX i_origin_id ON origin_id USING btree (id);

CREATE TABLE previous_id (
    id BIGINT
      UNIQUE
      REFERENCES archive (timestamp) ON DELETE CASCADE,
    stanza_id BIGINT
      UNIQUE
      REFERENCES archive (timestamp) ON DELETE CASCADE
);

INSERT INTO previous_id (stanza_id, id)
SELECT * FROM (
  SELECT
    current.timestamp AS stanza_id,
    (
      SELECT previous.timestamp
      FROM archive AS previous
      WHERE current.timestamp > previous.timestamp
        AND current.username = previous.username
        AND current.bare_peer = previous.bare_peer
      ORDER BY previous.timestamp DESC
      LIMIT 1
    ) AS id
  FROM archive AS current
) AS pairs
WHERE pairs.id NOTNULL;

CREATE TABLE message_retract(
    username text,
    xml text,
    version bigint,
    CONSTRAINT uc_retract_message_versions UNIQUE (username,xml,version)
    );

CREATE TABLE foreign_message_stanza_id(
    foreign_username text,
    our_username text,
    foreign_stanza_id bigint UNIQUE,
    our_stanza_id bigint
    UNIQUE
    REFERENCES archive (timestamp) ON DELETE CASCADE
);

CREATE INDEX i_our_origin_id ON foreign_message_stanza_id USING btree (foreign_stanza_id);


CREATE TABLE xabber_token (
    token text NOT NULL,
    token_uid text NOT NULL,
    jid text NOT NULL,
    device text,
    client text,
    expire bigint NOT NULL,
    ip text DEFAULT ''::text,
    last_usage bigint NOT NULL DEFAULT 0
);

CREATE UNIQUE INDEX i_xabber_token_token ON xabber_token USING btree (token);
CREATE UNIQUE INDEX i_xabber_token_token_uid ON xabber_token USING btree (token_uid);

ALTER TABLE sm ADD COLUMN token_uid text;

CREATE TABLE conversation_metadata(
    username text,
    conversation text,
    type text NOT NULL DEFAULT 'chat',
    retract bigint NOT NULL DEFAULT 0,
    conversation_thread text NOT NULL DEFAULT '',
    read_until text NOT NULL DEFAULT '0',
    delivered_until text NOT NULL DEFAULT '0',
    displayed_until text NOT NULL DEFAULT '0',
    updated_at bigint NOT NULL,
    CONSTRAINT uc_conversation_metadata UNIQUE (username,conversation,conversation_thread)
    );


CREATE TABLE special_messages(
    username text NOT NULL,
    conversation text NOT NULL,
    timestamp BIGINT NOT NULL,
    type text NOT NULL DEFAULT 'chat',
    CONSTRAINT uc_special_message UNIQUE (username,timestamp)
    );