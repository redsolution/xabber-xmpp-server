CREATE TABLE xen_prefs (
    username text NOT NULL,
    server_host text NOT NULL,
    jid text NOT NULL,
    rule text NOT NULL,
    PRIMARY KEY (server_host, username, jid),
    FOREIGN KEY (server_host, username) REFERENCES users (server_host, username) ON DELETE CASCADE
);

CREATE TABLE xen_policy (
    username text NOT NULL,
    server_host text NOT NULL,
    policy text NOT NULL,
    PRIMARY KEY (server_host, username),
    FOREIGN KEY (server_host, username) REFERENCES users (server_host, username) ON DELETE CASCADE
);

--Old schema
--CREATE TABLE xen_prefs (
--    username text NOT NULL,
--    jid text NOT NULL,
--    rule text NOT NULL,
--    PRIMARY KEY (username, jid),
--    FOREIGN KEY (username) REFERENCES users (username) ON DELETE CASCADE
--);
--
--CREATE TABLE xen_policy (
--    username text NOT NULL,
--    policy text NOT NULL,
--    PRIMARY KEY (username),
--    FOREIGN KEY (username) REFERENCES users (username) ON DELETE CASCADE
--);
