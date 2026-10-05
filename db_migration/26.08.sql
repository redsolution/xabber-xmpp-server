CREATE TABLE http_iq_tokens (
    username text NOT NULL,
    server_host text NOT NULL,
    device_id text NOT NULL,
    jwk text NOT NULL,
    token_hash text NOT NULL,
    expires_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    PRIMARY KEY (username, server_host, device_id)
);