
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