CREATE TABLE channels (
  name text NOT NULL,
  localpart text NOT NULL,
  server_host text NOT NULL,
  jid text NOT NULL UNIQUE,
  index text NOT NULL,
  membership text NOT NULL,
  description text,
  owner text NOT NULL,
  avatar_id text DEFAULT '',
  message bigint DEFAULT 0,
  contacts text,
  domains text,
  status text NOT NULL DEFAULT 'active',
  PRIMARY KEY (server_host, localpart)
);

CREATE TABLE channel_users (
  username text NOT NULL,
  id text NOT NULL,
  avatar_id text,
  avatar_type text,
  avatar_url text,
  avatar_size integer not null default 0,
  nickname text default '',
  parse_vcard timestamp NOT NULL default now(),
  parse_avatar text NOT NULL default 'yes',
  badge text NOT NULL default '',
  channel text NOT NULL REFERENCES channels (jid) ON DELETE CASCADE,
  subscription text NOT NULL,
  last_seen timestamp NOT NULL default now(),
  user_updated_at timestamp NOT NULL default now(),
  CONSTRAINT UC_channel_users UNIQUE (username,channel),
  CONSTRAINT UC_channel_users_id UNIQUE (id)
);

CREATE TABLE channel_rights (
  name text NOT NULL UNIQUE,
  type text NOT NULL,
  description text NOT NULL
);
CREATE TABLE channel_policy (
  username text NOT NULL,
  channel text NOT NULL REFERENCES channels (jid) ON DELETE CASCADE,
  right_name text NOT NULL REFERENCES channel_rights(name),
  valid_until bigint NOT NULL DEFAULT 0,
  issued_by text NOT NULL,
  issued_at timestamp NOT NULL DEFAULT now(),
  CONSTRAINT UC_channel_policy UNIQUE (username,channel,right_name)
);

INSERT INTO channel_rights (name,description,type) values
  ('owner','Owner','permission')
;