CREATE TABLE groupchat_permissions(
    groupchat text NOT NULL,
    member text NOT NULL,
    permission text NOT NULL,
    level text NOT NULL,
    status boolean NOT NULL DEFAULT true,
    valid_until bigint NOT NULL DEFAULT 0,
    issued_by text NOT NULL,
    issued_at bigint NOT NULL DEFAULT date_part('epoch'::text, (now())::timestamp(0) with time zone),
    CONSTRAINT uc_groupchat_permissions_group_member_perm UNIQUE (groupchat, member, permission)
    );
CREATE TABLE groupchat_default_permissions(
    groupchat text NOT NULL,
    permission text NOT NULL,
    status boolean NOT NULL DEFAULT true,
    CONSTRAINT uc_groupchat_default_permissions_group_perm UNIQUE (groupchat, permission)
    );
CREATE TABLE groupchat_newbies_permissions(
    groupchat text NOT NULL,
    permission text NOT NULL,
    status boolean NOT NULL DEFAULT true,
    seconds bigint NOT NULL DEFAULT 0,
    CONSTRAINT uc_groupchat_newbies_permissions_group_perm UNIQUE (groupchat, permission)
    );

WITH  tmptable AS (SELECT username, chatgroup, 'owner' AS permission, 'owner' AS level, 
    true AS status, 0 AS valid_until from groupchat_policy WHERE right_name='owner' AND chatgroup in
    (SELECT jid FROM groupchats WHERE (SELECT count(*) from groupchat_users WHERE chatgroup=jid) > 0))
    INSERT INTO groupchat_permissions (groupchat,member,permission,level,status,valid_until,issued_by)
    SELECT chatgroup,username,permission,level,status,valid_until,username from tmptable;

DROP TABLE groupchat_policy;
DROP TABLE groupchat_default_restrictions;
DROP TABLE groupchat_rights;
