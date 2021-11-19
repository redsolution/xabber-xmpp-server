ALTER TABLE xabber_token ADD COLUMN count bigint NOT NULL DEFAULT 0;
ALTER TABLE xabber_token ADD COLUMN description text DEFAULT ''::text;
CREATE TABLE devices (
    jid text NOT NULL,
    device_id text NOT NULL,
    secret text NOT NULL,
    count bigint NOT NULL DEFAULT 0,
    info text  DEFAULT ''::text,
    client text DEFAULT ''::text,
    description text DEFAULT ''::text,
    expire bigint NOT NULL,
    ip text DEFAULT ''::text,
    last_usage bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (jid, device_id)
);
