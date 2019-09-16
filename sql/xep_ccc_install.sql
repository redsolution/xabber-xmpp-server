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
    CONSTRAINT uc_conversation_metadata UNIQUE (username,conversation,conversation_thread),
    FOREIGN KEY (username) REFERENCES users(username) ON DELETE CASCADE
    );

CREATE TABLE special_messages(
    username text NOT NULL,
    conversation text NOT NULL,
    timestamp BIGINT NOT NULL,
    type text NOT NULL DEFAULT 'chat',
    CONSTRAINT uc_special_message UNIQUE (username,timestamp)
    );