CREATE TABLE user_permissions (
  username text NOT NULL,
  server_host text NOT NULL,
  commands text NOT NULL DEFAULT '',
  is_admin boolean NOT NULL DEFAULT false,
CONSTRAINT UC_user_permissions UNIQUE (username,server_host)
);