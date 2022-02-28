--New schema
CREATE TABLE panel_permissions (
    username text NOT NULL,
    server_host text NOT NULL,
    is_admin boolean NOT NULL DEFAULT false,
    permissions text  DEFAULT ''::text,
    PRIMARY KEY (server_host, username)
);

CREATE TABLE panel_tokens (
    username text NOT NULL,
    server_host text NOT NULL,
    token text NOT NULL,
    expire bigint NOT NULL,
    PRIMARY KEY (server_host, username, token)
);

--Old schema

--CREATE TABLE panel_permissions (
--    username text NOT NULL,
--    is_admin boolean NOT NULL DEFAULT false,
--    permissions text  DEFAULT ''::text,
--    PRIMARY KEY (username)
--);
--
--CREATE TABLE panel_tokens (
--    username text NOT NULL,
--    token text NOT NULL,
--    expire bigint NOT NULL,
--    PRIMARY KEY (username, token)
--);
