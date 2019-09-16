--
-- Author Alexander Ivanov <alexander.ivanov@redsolution.ru>
-- Copyright: (C) 2018, Redsolution Inc.
-- XEP-0PPP: Previous Message ID
--

CREATE TABLE previous_id (
    id BIGINT
      UNIQUE
      REFERENCES archive (timestamp) ON DELETE CASCADE,
    stanza_id BIGINT
      UNIQUE
      REFERENCES archive (timestamp) ON DELETE CASCADE
);

INSERT INTO previous_id (stanza_id, id)
SELECT * FROM (
  SELECT
    current.timestamp AS stanza_id,
    (
      SELECT previous.timestamp
      FROM archive AS previous
      WHERE current.timestamp > previous.timestamp
        AND current.username = previous.username
        AND current.bare_peer = previous.bare_peer
      ORDER BY previous.timestamp DESC
      LIMIT 1
    ) AS id
  FROM archive AS current
) AS pairs
WHERE pairs.id NOTNULL;
