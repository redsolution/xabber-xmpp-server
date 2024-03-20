DROP TABLE message_retract;
CREATE TABLE message_retract(
    username text,
    server_host text NOT NULL,
    xml text,
    version bigint,
    conversation text not null,
    type text not null default 'urn:xabber:chat',
    created bigint not null default ((date_part('epoch'::text, now()) * (1000000)::double precision))::bigint,
    CONSTRAINT uc_retract_message_versions UNIQUE (username,server_host,version)
    );
ALTER TABLE conversation_metadata ALTER COLUMN type SET DEFAULT 'urn:xabber:chat';
UPDATE conversation_metadata SET retract = 0 where type !='https://xabber.com/protocol/groups';
UPDATE conversation_metadata SET type = 'urn:xabber:chat' where type ='https://xabber.com/protocol/synchronization#chat';
