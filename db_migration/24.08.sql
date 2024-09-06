ALTER TABLE devices ADD COLUMN device_type text DEFAULT ''::text;
ALTER TABLE devices ADD COLUMN esecret text;
ALTER TABLE devices ADD COLUMN validator text;
UPDATE devices SET esecret = secret WHERE esecret IS NULL;
UPDATE devices SET validator = encode(md5(random()::text)::bytea,'base64') WHERE validator IS NULL;
ALTER TABLE devices ALTER esecret SET NOT NULL;
ALTER TABLE devices ALTER validator SET NOT NULL;
ALTER TABLE devices DROP COLUMN secret;
DELETE FROM devices WHERE expire = 0;