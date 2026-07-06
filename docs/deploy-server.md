# Deploy the CAS server

This guide runs a standalone barrel_xet CAS server as a release node. Use
it when you want a long-running server with filesystem or S3 storage,
started from configuration rather than an Erlang shell.

## What it is

`rebar3 as prod release` builds a self-contained node under
`_build/prod/rel/barrel_xet/` that autostarts the CAS server. Its
configuration lives in `config/sys.config.src`, whose `${VAR:-default}`
placeholders the start script fills from the environment on every boot.

## Build

```sh
make release
```

## Configure

Create the tokens file, one `token scope` line per token (scope is
`read`, `write` or `admin`, `#` starts a comment):

```sh
install -m 0600 /dev/null /etc/barrel_xet/tokens
echo "change-me-write write" >> /etc/barrel_xet/tokens
```

Then set environment variables as needed; every one has a default:

| Variable | Default |
|---|---|
| `BARREL_XET_DATA_DIR` | `/var/lib/barrel_xet` |
| `BARREL_XET_HTTP_PORT` | `8080` |
| `BARREL_XET_TOKENS_FILE` | `/etc/barrel_xet/tokens` |
| `BARREL_XET_HTTPS_PORT` | `8443` (listener off without cert and key) |
| `BARREL_XET_TLS_CERT` / `BARREL_XET_TLS_KEY` | empty: no TLS listener |
| `BARREL_XET_URL_SECRET` | empty: generated once, persisted in metadata |
| `BARREL_XET_LOG_LEVEL` | `notice` |
| `BARREL_XET_NODE` | `barrel_xet@127.0.0.1` |

### TLS

Point `BARREL_XET_TLS_CERT` and `BARREL_XET_TLS_KEY` at PEM files to
serve HTTPS (HTTP/1.1 + HTTP/2 via ALPN) on `BARREL_XET_HTTPS_PORT`.
Add an `http3 => #{port, cert, key}` map in the config for HTTP/3; it
takes the same PEM paths. A missing or unparsable file fails the boot
with the offending path listed. Encrypted keys are not supported.

To rotate certificates on https without a restart, replace the files
and clear the PEM cache; new handshakes serve the new certificate:

```sh
bin/barrel_xet eval 'ssl:clear_pem_cache().'
```

http3 captures the certificate at boot: restart after replacing it.

Notes:

- `data_dir` holds the rocksdb metadata (`metadata/`) and, for the
  filesystem backend, the xorb blobs (`xorbs/`).
- Signed data URLs survive restarts by default: the signing secret is
  generated on first boot and persisted in the metadata store. Set
  `BARREL_XET_URL_SECRET` only to manage it yourself.
- To add or revoke tokens without a restart, edit the tokens file and
  run `bin/barrel_xet eval 'xet_auth_file:reload().'`.
- For S3-backed storage, set `blob => {s3, #{bucket => ..., s3 => #{...}}}`
  in the config file (see `docs/deploy-s3.md`).

## Run

```sh
_build/prod/rel/barrel_xet/bin/barrel_xet daemon    # background
_build/prod/rel/barrel_xet/bin/barrel_xet foreground  # attached
_build/prod/rel/barrel_xet/bin/barrel_xet stop
```

`daemon` waits for the node over distribution, so the very first boot
needs a cookie file to exist (later boots reuse it):

```sh
head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > $HOME/.erlang.cookie
chmod 400 $HOME/.erlang.cookie
```

`foreground` (what systemd and Docker run) has no such wait and needs
no preparation.

To hand-manage the whole config instead of using environment variables,
point `RELX_CONFIG_PATH=/path/to/your.config` at a plain `.config` file
(no substitution happens there).

## Metrics

`GET /metrics` serves Prometheus text format; scrape it with a read
token (`Authorization: Bearer ...`). HTTP metrics record out of the
box. To push OTLP instead, set the standard `OTEL_*` environment
variables (for example `OTEL_METRICS_EXPORTER=otlp` and
`OTEL_EXPORTER_OTLP_ENDPOINT`); the instrument app picks them up on
boot with no configuration. Set `metrics => false` in the server map
to remove the endpoint.

## Verify

```sh
curl -s http://127.0.0.1:8080/healthz     # {"status":"ok"}
make smoke                                # full cold-start roundtrip
```
