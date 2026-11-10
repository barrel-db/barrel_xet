# Changelog

## Unreleased

### Fixed

- A request sent right after a HEAD, 204 or 304 response on the same
  HTTP/1.1 connection could fail to parse, because those empty responses
  carried a stray chunked terminator. Clients that reuse connections saw
  the next request fail; the client's retries hid it. Empty responses now
  carry no body at all.

## 0.2.0

The server is now ready to run on its own in production: validated
configuration, TLS, observability, storage maintenance, and packaging.
This release also closes the gaps found by a conformance review against
draft-denis-xet-05.

### Breaking changes

- The client no longer sends a token over plain `http` to a remote host.
  Use `https`, or opt out on a trusted network (`allow_insecure_http` in
  Erlang, `XET_ALLOW_INSECURE_HTTP=1` for the CLI). Local addresses are
  still allowed.
- Registering a file that already exists no longer replaces it. The first
  registration is kept.

### Security fixes

- The server now checks that a shard's file hash matches its content.
  Before, any client with a write token could replace what an existing
  file pointed to.
- The server now rejects xorbs over the spec's limits of 8192 chunks or
  64 MiB uncompressed. Before, a small upload of highly compressible data
  could make it use gigabytes of memory.
- The bearer token exemption now covers only the signed data endpoint,
  not every path ending in `/data`.

### Interoperability fixes

- Deduplication shards now index their entries the way xet-core does, so
  xet-core clients find the right chunk in shards that list several
  xorbs.
- The client now downloads every part of a reconstruction when a server
  splits one xorb across several fetch entries. Before, it skipped those
  parts and crashed.
- The client now retries transient errors when it fetches xorb data. One
  failed fetch no longer fails the whole download.
- Signed data URLs from the HTTPS listener now start with `https`. Behind
  a TLS proxy, set `BARREL_XET_EXTERNAL_URL`.
- With S3 storage, data URLs now carry cache headers, so a CDN never
  serves the bytes past the URL's lifetime.

### New

- Validated configuration: a bad config prints a list of errors instead
  of crashing.
- The release can be configured entirely from environment variables:
  ports, data directory, tokens file, TLS, and the URL secret.
- First-class TLS (HTTPS and HTTP/3 from PEM files), with certificate
  rotation without a restart.
- A tokens file with read, write, and admin scopes, reloadable without a
  restart.
- Signed data URLs keep working across restarts.
- Request deadlines, security headers, and a rate limit on the data
  endpoint.
- Prometheus metrics, a structured access log, and a `/readyz` readiness
  probe.
- An admin API: stats, file delete, garbage collection, verify-at-rest
  scrub, and metadata backups.
- Garbage collection of unreferenced xorbs, safe under concurrent uploads.
- The server answers `507` and fails readiness when the disk is nearly
  full, and cleans up interrupted uploads on startup.
- In-flight requests finish on shutdown.
- A Docker image on GHCR, a release tarball, and systemd and FreeBSD
  service files.
- Guides for production hardening, observability, backups, and the
  planned high-availability design.

## 0.1.0

First release: a client library, a standalone CAS server, and a CLI for
the XET protocol, verified against the Hugging Face reference files and
the draft's Python reference client.
