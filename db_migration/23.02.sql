ALTER TABLE conversation_metadata ADD COLUMN read_until_ts bigint NOT NULL DEFAULT 0;
ALTER TABLE conversation_metadata ADD COLUMN delivered_until_ts bigint NOT NULL DEFAULT 0;
ALTER TABLE conversation_metadata ADD COLUMN displayed_until_ts bigint NOT NULL DEFAULT 0;
UPDATE conversation_metadata SET read_until_ts = read_until::bigint;
UPDATE conversation_metadata SET delivered_until_ts = delivered_until::bigint;
UPDATE conversation_metadata SET displayed_until_ts = displayed_until::bigint;
