ALTER TABLE groupchat_users ADD COLUMN auto_nickname text NOT NULL DEFAULT '';
UPDATE groupchat_users SET auto_nickname = groupchat_users.id where 'incognito' = (select anonymous from groupchats where jid=groupchat_users.chatgroup);
UPDATE groupchat_users SET auto_nickname = coalesce((
  select
    CASE
      WHEN TRIM(groupchat_users_vcard.nickname) != '' and groupchat_users_vcard.nickname is not null THEN groupchat_users_vcard.nickname
      WHEN TRIM(groupchat_users_vcard.givenfamily) != '' and groupchat_users_vcard.givenfamily is not null THEN groupchat_users_vcard.givenfamily
      WHEN TRIM(groupchat_users_vcard.fn) != '' and groupchat_users_vcard.fn is not null THEN groupchat_users_vcard.fn
      ELSE groupchat_users.username
    END
  from groupchat_users_vcard where groupchat_users_vcard.jid=groupchat_users.username), username)
WHERE 'incognito' != (SELECT anonymous from groupchats where jid=groupchat_users.chatgroup);

CREATE INDEX i_groupchat_users_group_subs ON groupchat_users USING btree (chatgroup,subscription);
