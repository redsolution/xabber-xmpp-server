ALTER TABLE groupchats ADD COLUMN state text NOT NULL DEFAULT 'active'::text;
ALTER TABLE groupchats ADD COLUMN messages text;
ALTER TABLE groupchat_users ADD COLUMN use_user_avatar boolean NOT NULL default false;

UPDATE groupchats SET model='private' where model='member-only';
UPDATE groupchats SET state='inactive' where status='inactive';
UPDATE groupchats SET contacts= null;
UPDATE groupchats SET domains= null;
UPDATE groupchats SET messages='{groups_pinned,[{groups_pinned_message,<<"'||message::text||'">>,pinned}]}' WHERE message >0;
UPDATE groupchat_users SET use_user_avatar = true WHERE parse_avatar='yes';

ALTER TABLE groupchats DROP COLUMN message;
ALTER TABLE groupchat_block DROP COLUMN type;
ALTER TABLE groupchat_block DROP COLUMN anonim_id;
ALTER TABLE groupchat_users DROP COLUMN parse_vcard;
ALTER TABLE groupchat_users DROP COLUMN parse_avatar;
DROP TABLE IF EXISTS groupchat_users_vcard;
