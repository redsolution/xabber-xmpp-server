ALTER TABLE conversation_metadata ADD COLUMN incognito boolean NOT NULL DEFAULT false;
ALTER TABLE conversation_metadata ADD COLUMN p2p boolean NOT NULL DEFAULT false;