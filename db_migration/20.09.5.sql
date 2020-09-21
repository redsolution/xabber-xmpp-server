update groupchat_users set badge = '' where badge is null;
ALTER TABLE groupchat_users ALTER COLUMN badge set NOT NULL;
ALTER TABLE groupchat_users ALTER COLUMN badge set default '';