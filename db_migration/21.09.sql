DROP TABLE origin_id;
DROP TABLE previous_id;

ALTER TABLE conversation_metadata DROP COLUMN archived;
ALTER TABLE conversation_metadata DROP COLUMN archived_at;
ALTER TABLE conversation_metadata DROP COLUMN pinned;
ALTER TABLE conversation_metadata DROP COLUMN pinned_at;

ALTER TABLE conversation_metadata ALTER COLUMN type SET DEFAULT 'https://xabber.com/protocol/synchronization#chat';
ALTER TABLE conversation_metadata ADD COLUMN pinned bigint DEFAULT 0;
ALTER TABLE conversation_metadata ADD COLUMN mute bigint DEFAULT 0;
ALTER TABLE conversation_metadata ADD COLUMN group_info text DEFAULT ''::text;

UPDATE conversation_metadata SET type='https://xabber.com/protocol/synchronization#chat' WHERE type='chat' AND NOT encrypted;
UPDATE conversation_metadata SET type='urn:xmpp:omemo:1' WHERE encrypted;
UPDATE conversation_metadata SET type='https://xabber.com/protocol/groups' WHERE type='groupchat';
UPDATE conversation_metadata SET type='https://xabber.com/protocol/channels' WHERE type='channel';
UPDATE conversation_metadata SET group_info='public' WHERE type='https://xabber.com/protocol/groups' AND NOT incognito;
UPDATE conversation_metadata SET group_info='incognito' WHERE type='https://xabber.com/protocol/groups' AND incognito;
UPDATE conversation_metadata SET group_info=concat_ws(',', 'incognito', subquery.parent_chat)
    FROM (SELECT parent_chat,jid from groupchats) AS subquery  WHERE conversation=subquery.jid
    AND  type='https://xabber.com/protocol/groups' AND p2p;

ALTER TABLE conversation_metadata DROP COLUMN incognito;
ALTER TABLE conversation_metadata DROP COLUMN p2p;
ALTER TABLE conversation_metadata drop CONSTRAINT uc_conversation_metadata;
ALTER TABLE conversation_metadata add CONSTRAINT uc_conversation_metadata UNIQUE (username, server_host, conversation, type, conversation_thread);

--Old schema
--ALTER TABLE conversation_metadata add CONSTRAINT uc_conversation_metadata UNIQUE (username, conversation, type, conversation_thread);