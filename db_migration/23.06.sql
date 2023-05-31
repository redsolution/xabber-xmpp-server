ALTER TABLE archive ADD COLUMN newtags text[];
UPDATE archive SET newtags='{"invite"}' WHERE tags='<invite>';
UPDATE archive SET newtags='{"voip"}' WHERE tags='<voip>';
ALTER TABLE archive DROP COLUMN tags;
ALTER TABLE archive RENAME COLUMN newtags TO tags;
UPDATE archive SET tags = array_append(tags, 'image') WHERE image;
UPDATE archive SET tags = array_append(tags, 'video') WHERE video;
UPDATE archive SET tags = array_append(tags, 'geo') WHERE geo;
UPDATE archive SET tags = array_append(tags, 'audio') WHERE audio;
UPDATE archive SET tags = array_append(tags, 'sticker') WHERE sticker;
UPDATE archive SET tags = array_append(tags, 'voice') WHERE voice;
UPDATE archive SET tags = array_append(tags, 'document') WHERE document;

ALTER TABLE archive ADD COLUMN payload_type text DEFAULT 'cleartext';
UPDATE archive SET payload_type='urn:xmpp:omemo:2' WHERE encrypted;
