
DELETE from groupchat_policy WHERE right_name='read-messages';
DELETE from groupchat_default_restrictions WHERE right_name='read-messages';
DELETE from groupchat_rights WHERE name='read-messages';

ALTER TABLE groupchat_default_restrictions DROP CONSTRAINT groupchat_default_restrictions_right_name_fkey;
ALTER TABLE groupchat_default_restrictions ADD CONSTRAINT groupchat_default_restrictions_right_name_fkey
 FOREIGN KEY (right_name) REFERENCES groupchat_rights(name) ON DELETE CASCADE;

ALTER TABLE groupchat_policy DROP CONSTRAINT groupchat_policy_right_name_fkey;
ALTER TABLE groupchat_policy ADD CONSTRAINT groupchat_policy_right_name_fkey
 FOREIGN KEY (right_name) REFERENCES groupchat_rights(name) ON DELETE CASCADE;