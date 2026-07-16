DROP INDEX IF EXISTS i_xabber_push_session_sun;
DROP INDEX IF EXISTS i_xabber_push_session_sn;
DROP INDEX IF EXISTS i_xabber_push_session_sud;

DELETE FROM xabber_push_session
WHERE device_id IS NULL
   OR cipher IS NULL
   OR key IS NULL;

DELETE FROM xabber_push_session
WHERE ctid IN (
  SELECT ctid
  FROM (
    SELECT ctid,
           row_number() OVER (
             PARTITION BY server_host, username, service, node
             ORDER BY timestamp DESC
           ) AS rn
    FROM xabber_push_session
  ) AS duplicates
  WHERE rn > 1
);

DELETE FROM xabber_push_session
WHERE ctid IN (
  SELECT ctid
  FROM (
    SELECT ctid,
           row_number() OVER (
             PARTITION BY server_host, username, device_id
             ORDER BY timestamp DESC
           ) AS rn
    FROM xabber_push_session
  ) AS duplicates
  WHERE rn > 1
);

ALTER TABLE xabber_push_session ALTER COLUMN device_id SET NOT NULL;
ALTER TABLE xabber_push_session ALTER COLUMN cipher SET NOT NULL;
ALTER TABLE xabber_push_session ALTER COLUMN key SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS i_xabber_push_session_susn ON xabber_push_session USING btree (server_host, username, service, node);
CREATE UNIQUE INDEX IF NOT EXISTS i_xabber_push_session_sud ON xabber_push_session USING btree (server_host, username, device_id);
