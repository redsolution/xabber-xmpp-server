--New schema
CREATE TABLE blocked_users (
    username text NOT NULL,
    server_host text NOT NULL,
    message text  DEFAULT ''::text,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    PRIMARY KEY (server_host, username),
    FOREIGN KEY (server_host, username) REFERENCES users (server_host, username) ON DELETE CASCADE
);

--Old schema
--CREATE TABLE blocked_users (
--    username text NOT NULL,
--    message text  DEFAULT ''::text,
--    created_at TIMESTAMP NOT NULL DEFAULT now(),
--    PRIMARY KEY (username),
--    FOREIGN KEY (username) REFERENCES users (username) ON DELETE CASCADE
--);