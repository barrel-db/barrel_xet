# Deploy the CAS server

This guide runs a standalone barrel_xet CAS server as a release node. Use
it when you want a long-running server with filesystem or S3 storage,
started from configuration rather than an Erlang shell.

## What it is

`rebar3 as prod release` builds a self-contained node under
`_build/prod/rel/barrel_xet/` that autostarts the CAS server from the
`server` map in `config/sys.config`.

## Build

```sh
make release
```

## Configure

Edit `config/sys.config`. The `server` map is passed to
`xet_server:start_instance/1`:

```erlang
{server, #{
    name => barrel_xet,
    data_dir => "/var/lib/barrel_xet",
    http => #{port => 8080},
    url_secret => <<"...32 random bytes...">>,   %% stable across restarts
    auth => {xet_auth_static, #{tokens => #{
        <<"write-token">> => write,
        <<"read-token">> => read
    }}}
}}
```

Notes:

- `data_dir` holds the rocksdb metadata (`metadata/`) and, for the
  filesystem backend, the xorb blobs (`xorbs/`).
- Set `url_secret` explicitly so signed data URLs stay valid across
  restarts; otherwise it is random per boot and clients recover via a
  reconstruction re-query.
- Add `https => #{port, cert, key}` and/or `http3 => #{port, cert, key}`
  to serve HTTP/2 and HTTP/3 alongside HTTP/1.
- For S3-backed storage, set `blob => {s3, #{bucket => ..., s3 => #{...}}}`
  (see `docs/deploy-s3.md`).

## Run

```sh
_build/prod/rel/barrel_xet/bin/barrel_xet daemon    # background
_build/prod/rel/barrel_xet/bin/barrel_xet foreground  # attached
_build/prod/rel/barrel_xet/bin/barrel_xet stop
```

Point a config elsewhere with `RELX_CONFIG_PATH=/path/to/your.config`
(the file must end in `.config`).

## Verify

```sh
curl -s http://127.0.0.1:8080/healthz     # {"status":"ok"}
make smoke                                # full cold-start roundtrip
```
