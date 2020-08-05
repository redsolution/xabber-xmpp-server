
ALTER TABLE special_messages ADD COLUMN origin_id text;

ALTER TABLE archive ADD COLUMN image boolean NOT NULL DEFAULT false;
ALTER TABLE archive ADD COLUMN document boolean NOT NULL DEFAULT false;
ALTER TABLE archive ADD COLUMN audio boolean NOT NULL DEFAULT false;
ALTER TABLE archive ADD COLUMN video boolean NOT NULL DEFAULT false;
ALTER TABLE archive ADD COLUMN geo boolean NOT NULL DEFAULT false;
ALTER TABLE archive ADD COLUMN sticker boolean NOT NULL DEFAULT false;
ALTER TABLE archive ADD COLUMN voice boolean NOT NULL DEFAULT false;
ALTER TABLE archive ADD COLUMN encrypted boolean NOT NULL DEFAULT false;

ALTER TABLE conversation_metadata ADD COLUMN pinned boolean NOT NULL DEFAULT false;
ALTER TABLE conversation_metadata ADD COLUMN pinned_at bigint NOT NULL DEFAULT 0;
ALTER TABLE conversation_metadata ADD COLUMN archived boolean NOT NULL DEFAULT false;
ALTER TABLE conversation_metadata ADD COLUMN archived_at bigint NOT NULL DEFAULT 0;
ALTER TABLE conversation_metadata ADD COLUMN encrypted boolean NOT NULL DEFAULT false;

ALTER TABLE groupchat_users_vcard ADD COLUMN image_type text;

ALTER TABLE conversation_metadata DROP CONSTRAINT uc_conversation_metadata;
ALTER TABLE conversation_metadata ADD CONSTRAINT uc_conversation_metadata UNIQUE (username, conversation, conversation_thread, encrypted);