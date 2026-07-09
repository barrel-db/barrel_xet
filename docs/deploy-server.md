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

To change the free-space reserve, set `min_free_bytes` in the config
map (default 1 GiB). When free space on the data dir drops below the
reserve plus room for the incoming upload, the server answers `507
Insufficient Storage` and `/readyz` reports `disk` as failed so a load
balancer drains the node. `507` is not one of the spec's enumerated
statuses; clients that retry `5xx` will back off and retry.

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

## Run as a service

Unpack the release under `/opt/barrel_xet` (owned by the service user) so
the paths below match. Both service files run `foreground`/`daemon` and let
the init system own supervision; `stop` drains in-flight requests before
halting.

### Docker

```sh
docker build -t barrel_xet .
docker run -d -p 8080:8080 -v barrel_xet_data:/var/lib/barrel_xet barrel_xet
```

`docker/compose.yaml` adds a persistent volume and a mounted tokens file.
Pass the same `BARREL_XET_*` environment variables as above.

### systemd (Linux)

```sh
useradd -r -d /var/lib/barrel_xet -m barrel-xet
install -Dm0644 packaging/systemd/barrel-xet.service /etc/systemd/system/barrel-xet.service
install -Dm0640 packaging/systemd/env.example /etc/barrel_xet/env
systemctl daemon-reload
systemctl enable --now barrel-xet
```

Edit `/etc/barrel_xet/env` for ports, data dir, tokens file, and TLS
paths. `systemctl reload barrel-xet` reloads the tokens file without
dropping connections; `TimeoutStopSec=45` covers the 30s drain window.

### FreeBSD (rc.d)

```sh
pw useradd barrel-xet -d /var/lib/barrel_xet -m -s /usr/sbin/nologin
install -m 0755 packaging/freebsd/barrel_xet /usr/local/etc/rc.d/barrel_xet
sysrc barrel_xet_enable=YES
service barrel_xet start
```

`service barrel_xet reload` reloads the tokens file; `service barrel_xet
status` pings the node. Override `barrel_xet_user`, `barrel_xet_root`,
and `barrel_xet_env` in `/etc/rc.conf` if your layout differs.

The prod release bundles ERTS and is per-platform, so there is no
prebuilt FreeBSD tarball yet: build it on the host with
`rebar3 as prod tar` (the NIF build already covers FreeBSD) and unpack
the result under `/opt/barrel_xet`.

## Metrics

`GET /metrics` serves Prometheus text format; scrape it with a read
token (`Authorization: Bearer ...`). HTTP metrics record out of the
box. To push OTLP instead, set the standard `OTEL_*` environment
variables (for example `OTEL_METRICS_EXPORTER=otlp` and
`OTEL_EXPORTER_OTLP_ENDPOINT`); the instrument app picks them up on
boot with no configuration. Set `metrics => false` in the server map
to remove the endpoint.

## Health and readiness

- `GET /healthz` is a liveness probe: it always answers `200` while the
  process is up. Point a supervisor or `HEALTHCHECK` at it to restart a
  hung node.
- `GET /readyz` is a readiness probe: it answers `200` when the metadata
  store, blob store, and key ring are all healthy, or `503` with a
  `"failed"` list otherwise. Point a load balancer or Kubernetes
  readiness probe at it so a degraded node is drained rather than
  restarted. Both endpoints skip authentication.

## Verify

```sh
curl -s http://127.0.0.1:8080/healthz     # {"status":"ok"}
curl -s http://127.0.0.1:8080/readyz      # {"status":"ok"} when serving
make smoke                                # full cold-start roundtrip
```
