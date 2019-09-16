--
-- Author Alexander Ivanov <alexander.ivanov@redsolution.ru>
-- Copyright: (C) 2018, Redsolution Inc.
-- XEP-0XXX: Unique Message ID
--

ALTER TABLE archive ADD CONSTRAINT unique_timestamp UNIQUE (timestamp);

CREATE TABLE origin_id (
    id text NOT NULL,
    stanza_id BIGINT
      UNIQUE
      REFERENCES archive (timestamp) ON DELETE CASCADE
);

CREATE INDEX i_origin_id ON origin_id USING btree (id);
