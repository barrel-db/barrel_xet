# Back up and restore

This runbook backs up a running CAS server and restores it. Use it to
guard against disk loss or operator error. It covers the filesystem
backend; for the S3 backend the object store is your durable tier and
only the metadata needs backing up.

## What to back up

A deployment has two parts under `data_dir`:

- `metadata/` — the rocksdb store (files, xorbs, chunk index, keys).
- `xorbs/` — the blob tree (filesystem backend only).

## Back up

Order matters: checkpoint the metadata first, then copy the blobs, with
garbage collection idle. A checkpoint at time T references only blobs
committed at or before T, and blobs are immutable, so a blob copy taken
after the checkpoint is a superset. The reverse order can capture a
checkpoint that references blobs the copy missed.

1. Configure a backup directory (`backup_dir` in the server map) and
   trigger a metadata checkpoint:

   ```sh
   curl -X POST -H "Authorization: Bearer ops-token" \
       http://127.0.0.1:8080/admin/backup
   ```

   The response gives the checkpoint path
   (`<backup_dir>/<UTC-timestamp>/metadata`). The endpoint returns `409`
   if garbage collection is running; wait for it to finish. Do not run
   collection during the blob copy below.

2. Copy the blob tree:

   ```sh
   rsync -a /var/lib/barrel_xet/xorbs/ /backups/xorbs/
   ```

The checkpoint uses hard links where it can, so it is fast and cheap on
the same filesystem.

## Restore

1. Stop the node.
2. Put the checkpoint in place as the metadata store:

   ```sh
   rm -rf /var/lib/barrel_xet/metadata
   cp -a /backups/<UTC-timestamp>/metadata /var/lib/barrel_xet/metadata
   ```

3. Put the blob tree in place:

   ```sh
   rsync -a /backups/xorbs/ /var/lib/barrel_xet/xorbs/
   ```

4. Start the node and verify with `/readyz` and a scrub
   (`POST /admin/scrub`).

If the blob copy was newer than the checkpoint, some blobs may have no
metadata; a later garbage collection reclaims them once they pass the
grace window.

## Notes

- The checkpoint is a consistent snapshot: writes after it are not
  included, so back up on a schedule that matches your recovery point.
- rocksdb also ships an incremental backup engine; wiring it is a
  follow-up. For now each checkpoint is a full (hard-linked) snapshot.
