# Production hardening

This is the checklist to run before you expose a barrel_xet CAS server to
untrusted traffic. Work through each item once per deployment; most map to
one environment variable or config key covered in
[Deploy the CAS server](deploy-server.md). It assumes a single service per
node, which is the supported production topology for this release.

## Transport (TLS)

Serve HTTPS, not cleartext, on any network you do not fully control.

- Set `BARREL_XET_TLS_CERT` and `BARREL_XET_TLS_KEY` to PEM paths; the
  HTTPS listener (HTTP/1.1 + HTTP/2) comes up on `BARREL_XET_HTTPS_PORT`.
- Add an `http3 => #{port, cert, key}` map for HTTP/3 (same PEM paths).
- A missing or unparsable cert fails the boot with the offending path
  listed, so a bad rotation never starts a cleartext-only node by accident.
- Rotate https certs without a restart: replace the files, then
  `bin/barrel_xet eval 'ssl:clear_pem_cache().'`. HTTP/3 captures the cert
  at boot, so restart after replacing it.
- Encrypted private keys are not supported. Keep key files `0600`, owned by
  the service user.

## Tokens

- Store the tokens file at `0600`, owned by the service user. Each line is
  `token scope` where scope is `read`, `write`, or `admin`.
- Add or revoke a token by editing the file, then reload without dropping
  connections: `bin/barrel_xet eval 'xet_auth_file:reload().'` (or
  `systemctl reload barrel-xet` / `service barrel_xet reload`). A parse
  error keeps the previously loaded set.
- Give Prometheus a `read` token, upload clients a `write` token, and hold
  `admin` tokens for operators only. `admin` covers `write` covers `read`.
- Scope `/metrics` behind `read`: it leaks volume and path counts.

## Signed URL secret

- The signing secret for `/data` URLs is generated on first boot and
  persisted in the metadata store, so signed URLs survive a restart on the
  same data dir. Do nothing for a single node.
- Set `BARREL_XET_URL_SECRET` only if you manage the secret yourself. Keep
  it out of the process list: put it in the systemd `EnvironmentFile`
  (`0640`), not on the command line.
- S3 deployments never sign `/data` URLs, so the secret does not apply.

## Distribution and cookie

- The release binds Erlang distribution to loopback
  (`inet_dist_use_interface {127,0,0,1}`) on `ERL_DIST_PORT` (default
  9100). Keep it loopback; the only clients are `eval`-based reload and
  admin from the same host.
- `~/.erlang.cookie` under `HOME` gates who can attach to the node. Keep
  `HOME` on storage only the service user can read, and the cookie `0400`.
  The Docker image and service files put `HOME` in the data dir for this
  reason.
- Do not expose the distribution port to the network. It is not
  authenticated beyond the cookie.

## Limits and timeouts

- `request_timeout` (default 30000 ms) bounds handler time on GET/HEAD
  routes. It does not bound upload transfer time: streamed chunks are
  covered by a separate 30 s per-chunk inactivity limit.
- `ratelimit` and `concurrency` are off by default. Turn on `concurrency`
  to cap in-flight requests, and `data_ratelimit` to bound reuse of a
  single signed `/data` URL.
- These knobs bound per-URL and per-node load. They do not stop an IP flood
  or a distributed attack: peer IP is not available to the rate limiter in
  this release, so put IP-level protection at your load balancer.
- `security_headers` is on by default (HSTS self-suppresses on cleartext).

## Disk

- The server refuses uploads with `507 Insufficient Storage` when free
  space drops below `min_free_bytes` (default 1 GiB) plus room for the
  incoming xorb, and `/readyz` reports `disk` failed so a load balancer
  drains the node. Size `min_free_bytes` above your largest expected xorb
  burst.
- Run `POST /admin/gc` and scrub on a schedule you control; see
  [Admin endpoints](admin.md) and [Backup and restore](backup.md).

## Shutdown

- `bin/barrel_xet stop` (and `systemctl stop`, `docker stop`) drains
  in-flight requests before halting, up to `drain_timeout` (default
  30000 ms). New connections are refused as soon as draining starts.
- Set the init system's stop timeout above `drain_timeout` so it does not
  kill the node mid-drain. The shipped systemd unit uses
  `TimeoutStopSec=45`.

## Logging

- Set `BARREL_XET_LOG_LEVEL` to `notice` in production (the default). Every
  request logs one structured line with request and session ids.
- Uncomment the kernel logger file-handler block in `config/sys.config.src`
  to write rotating log files; see [Observability](observability.md) for
  the template and the metric inventory.

## Verify

```sh
curl -s https://your-host/readyz            # {"status":"ok"} when serving
curl -s https://your-host/metrics -H 'Authorization: Bearer READ_TOKEN'
curl -s https://your-host/data/... ; echo   # 403 without a valid signature
```
