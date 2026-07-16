ALTER TABLE xabber_push_session ADD COLUMN mode text NOT NULL DEFAULT 'full';
ALTER TABLE xabber_push_session ALTER COLUMN mode DROP DEFAULT;
