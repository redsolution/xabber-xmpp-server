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
