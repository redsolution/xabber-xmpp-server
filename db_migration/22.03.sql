--New schema
CREATE TABLE registration_keys (
    id SERIAL,
    key text NOT NULL,
    server_host text NOT NULL,
    expire bigint NOT NULL,
    description text  DEFAULT ''::text,
    removed boolean NOT NULL DEFAULT false,
    PRIMARY KEY (server_host, key)
);

--Old schema
--CREATE TABLE registration_keys (
--    id SERIAL,
--    key text NOT NULL,
--    expire bigint NOT NULL,
--    description text  DEFAULT ''::text,
--    removed boolean NOT NULL DEFAULT false,
--    PRIMARY KEY (key)
--);