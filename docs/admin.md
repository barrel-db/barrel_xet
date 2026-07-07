# Admin endpoints

This guide covers the server's administrative endpoints. Use them to
inspect and operate a running node. These are barrel_xet extensions, not
part of the XET protocol (draft-denis-xet-05): they live under `/admin`,
require the `admin` auth scope, and are served only when you enable them.

## When to use

Enable the admin surface when you need operational visibility or control
beyond `/healthz` and `/readyz`, and you can restrict who holds an
`admin` token.

## Enable

Set `admin => #{enabled => true}` in the server map (off by default), and
issue at least one token with the `admin` scope in the tokens file:

```
ops-token admin
```

With the surface disabled, the routes are absent (`404`).

## GET /admin/stats

Returns store counts as JSON.

```sh
curl -s -H "Authorization: Bearer ops-token" \
    http://127.0.0.1:8080/admin/stats
```

```json
{"metadata": {"files": 1024, "xorbs": 512, "bytes_on_disk": 68719476736, "chunks": 4096}}
```

Notes:

- `files`, `xorbs`, and `bytes_on_disk` are exact maintained counters;
  `chunks` is a rocksdb key estimate.
- A read or write token is rejected with `403`; only `admin` is
  accepted. No token is `401`.
- The response grows over later releases (garbage collection and scrub
  status); existing keys stay stable.

## DELETE /admin/files/{hash}

Removes a file record. Its xorbs that no other file references become
collectable by garbage collection; shared xorbs are untouched.

```sh
curl -X DELETE -H "Authorization: Bearer ops-token" \
    http://127.0.0.1:8080/admin/files/<file-hash>
```

Returns `204` on delete, `404` if the file is not present (so a repeated
delete is `404`). This is the only way to make stored data eligible for
collection; the XET protocol has no file-delete operation.

## Garbage collection

Collection sweeps xorbs that no file references and that are older than
the grace window (`gc => #{grace_seconds => 86400}`, default 1 day). It
is manual by default; set `gc => #{interval => Seconds}` to run it on a
timer. A run is single-flight.

Start a run:

```sh
curl -X POST -H "Authorization: Bearer ops-token" \
    "http://127.0.0.1:8080/admin/gc?dry_run=true"
```

`dry_run=true` reports what a real run would collect without deleting
anything. Check status and the last run:

```sh
curl -H "Authorization: Bearer ops-token" http://127.0.0.1:8080/admin/gc
```

```json
{"running": false,
 "last": {"dry_run": false, "candidates": 12, "deleted_xorbs": 12, "deleted_bytes": 4096}}
```

A concurrent upload is never at risk: a registration that references a
xorb during a sweep either wins (the xorb is kept) or finds it already
gone and fails cleanly, so no file is left pointing at a deleted xorb.

Do not run the first collection within one grace window of upgrading
from a release that did not stamp xorb creation times: those records
default to age zero and would be eligible immediately if unreferenced.

Collection also reclaims orphaned blobs on the filesystem backend: blob
files with no metadata and an mtime older than the grace window (left by
a put that crashed before registration, or a crash between the metadata
and blob deletes). The S3 backend does not sweep orphans in this
release; its object listing is a follow-up.
