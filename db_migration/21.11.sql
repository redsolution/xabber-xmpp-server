ALTER TABLE xabber_token ADD COLUMN count bigint NOT NULL DEFAULT 0;
ALTER TABLE xabber_token ADD COLUMN description text DEFAULT ''::text;
