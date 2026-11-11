# Back up and restore

This runbook backs up a running CAS server and restores it. Use it to
guard against disk loss or operator error. It covers the filesystem
backend; for the S3 backend the object store is your durable tier and
only the metadata needs backing up.

## What to back up

A deployment has two parts under `data_dir`:

- `metadata/`: the rocksdb store (files, xorbs, chunk index, keys).
- `xorbs/`: the blob tree (filesystem backend only).

## Configure

Set a backup directory and how many incremental backups to keep in the
server map (the admin surface must be enabled):

```erlang
{server, #{
    %% ...
    admin => #{enabled => true},
    backup_dir => "/backups/barrel_xet",
    backup_keep => 7
}}
```

## Back up

Order matters: back up the metadata first, then copy the blobs, with
garbage collection idle. A backup at time T references only blobs
committed at or before T, and blobs are immutable, so a blob copy taken
after it is a superset. The reverse order can capture metadata that
references blobs the copy missed.

1. Take an incremental metadata backup:

   ```sh
   curl -X POST -H "Authorization: Bearer ops-token" \
       http://127.0.0.1:8080/admin/backup
   ```

   ```json
   {"mode": "incremental", "id": 12, "timestamp": 1794352377, "size": 8485, "files": 4}
   ```

   Backups live in `<backup_dir>/engine`. Each one shares the files it
   has in common with the previous ones, so only what changed since is
   copied. The oldest backups beyond `backup_keep` are removed. The
   endpoint returns `409` while garbage collection or another backup is
   running; wait and retry. Do not run collection during the blob copy
   below.

2. Copy the blob tree:

   ```sh
   rsync -a /var/lib/barrel_xet/xorbs/ /backups/xorbs/
   ```

List and check backups:

```sh
curl -H "Authorization: Bearer ops-token" http://127.0.0.1:8080/admin/backups
curl -X POST -H "Authorization: Bearer ops-token" \
    http://127.0.0.1:8080/admin/backups/12/verify
```

Verify checks that the backup's files are present with the sizes it
recorded; it does not re-read their checksums.

A full checkpoint (a complete, hard-linked copy in its own directory, as
in 0.2) is still available:

```sh
curl -X POST -H "Authorization: Bearer ops-token" \
    'http://127.0.0.1:8080/admin/backup?mode=checkpoint'
```

The response gives its path, `<backup_dir>/<UTC-timestamp>/metadata`.

## Restore

1. Restore the newest incremental backup into a side directory. The node
   keeps serving meanwhile; `eval` runs on it:

   ```sh
   bin/barrel_xet eval 'ok = xet_metadata_backup:restore_latest("/backups/barrel_xet", "/var/lib/barrel_xet/metadata.restored").'
   ```

   From a checkpoint instead, copy it:

   ```sh
   cp -a /backups/barrel_xet/<UTC-timestamp>/metadata /var/lib/barrel_xet/metadata.restored
   ```

2. Stop the node and swap the restored store in:

   ```sh
   bin/barrel_xet stop
   mv /var/lib/barrel_xet/metadata /var/lib/barrel_xet/metadata.old
   mv /var/lib/barrel_xet/metadata.restored /var/lib/barrel_xet/metadata
   ```

3. Put the blob tree in place:

   ```sh
   rsync -a /backups/xorbs/ /var/lib/barrel_xet/xorbs/
   ```

4. Start the node and verify with `/readyz` and a scrub
   (`POST /admin/scrub`). Remove `metadata.old` once you are satisfied.

If the blob copy was newer than the backup, some blobs may have no
metadata; a later garbage collection reclaims them once they pass the
grace window.

## Notes

- A backup is a consistent snapshot: writes after it are not included,
  so back up on a schedule that matches your recovery point.
- The backup directory should be on another disk or synced off the host:
  a backup on the same disk as `data_dir` does not survive losing it.
