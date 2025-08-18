DROP TABLE IF EXISTS groupchat_log;
ALTER TABLE  groupchat_users DROP CONSTRAINT uc_groupchat_users_id;
ALTER TABLE  groupchat_users DROP CONSTRAINT uc_groupchat_users;
ALTER TABLE groupchat_users ADD CONSTRAINT "uc_groupchat_users_username_chatgroup" UNIQUE (username,chatgroup);
ALTER TABLE groupchat_users ADD CONSTRAINT "uc_groupchat_users_chatgroup_id" UNIQUE (chatgroup,id);
