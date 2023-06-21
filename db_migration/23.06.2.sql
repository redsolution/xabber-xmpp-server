ALTER TABLE devices ADD COLUMN omemo_id text DEFAULT '';
ALTER TABLE devices RENAME COLUMN description to public_label;
