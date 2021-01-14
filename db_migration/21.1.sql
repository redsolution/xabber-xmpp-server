CREATE TABLE user_acl (
  username text NOT NULL,
  server_host text NOT NULL,
  commands text NOT NULL DEFAULT "",
  is_admin boolean NOT NULL DEFAULT false,
CONSTRAINT UC_user_acl UNIQUE (username,server_host)
);