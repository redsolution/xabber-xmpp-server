ALTER TABLE conversation_metadata ADD COLUMN status text NOT NULL DEFAULT 'active';

CREATE TABLE special_messages(
    username text NOT NULL,
    conversation text NOT NULL,
    timestamp BIGINT NOT NULL,
    origin_id text,
    type text NOT NULL DEFAULT 'chat',
    CONSTRAINT uc_special_message UNIQUE (username,timestamp)
    );

ALTER TABLE special_messages ADD COLUMN origin_id text;
ALTER TABLE conversation_metadata ADD COLUMN metadata_updated_at bigint NOT NULL DEFAULT 0;
ALTER TABLE origin_id ADD COLUMN username text;