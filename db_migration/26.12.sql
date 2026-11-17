DROP TABLE message_retract;

DELETE FROM groupchat_retract;
ALTER TABLE groupchat_retract ALTER COLUMN version TYPE bigint;
ALTER TABLE groupchat_retract ADD COLUMN event_type text NOT NULL DEFAULT 'retract-message';

CREATE TABLE message_rewrite (
    username text,
    server_host text NOT NULL,
    xml text,
    version bigint,
    conversation text NOT NULL,
    type text NOT NULL DEFAULT 'urn:xabber:chat',
    event_type text NOT NULL DEFAULT 'retract-message',
    created bigint NOT NULL DEFAULT ((date_part('epoch'::text, now()) * (1000000)::double precision))::bigint,
    CONSTRAINT uc_rewrite_message_versions UNIQUE (username, server_host, version)
);
