ALTER TABLE message_retract ADD COLUMN type text not null default '';
ALTER TABLE message_retract DROP CONSTRAINT "uc_retract_message_versions";
ALTER TABLE message_retract ADD CONSTRAINT "uc_retract_message_versions" UNIQUE (username,type,version);