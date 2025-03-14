CREATE TABLE panel_user_settings(
    username text,
    server_host text NOT NULL,
    name text NOT NULL,
    value text NOT NULL,
    expires bigint NOT NULL DEFAULT 0,
    CONSTRAINT uc_user_settings_rules UNIQUE (username, server_host, name)
    );
