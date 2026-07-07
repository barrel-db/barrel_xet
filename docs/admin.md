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
