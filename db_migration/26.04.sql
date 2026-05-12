CREATE INDEX CONCURRENTLY i_archive_sh_username_origin_id
      ON archive USING btree (server_host, username, origin_id);