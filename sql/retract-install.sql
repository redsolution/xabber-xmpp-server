CREATE TABLE message_retract(
    username text,
    xml text,
    version bigint,
    CONSTRAINT uc_retract_message_versions UNIQUE (username,xml,version),
    FOREIGN KEY (username) REFERENCES users(username) ON DELETE CASCADE
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