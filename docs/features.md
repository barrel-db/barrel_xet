# barrel_xet task checklist

One box per task. A task is ticked in the same commit that lands it, after
review. Full plan of record: draft-denis-xet-05 implementation, client +
standalone CAS server.

## Phase 0: Bootstrap

- [x] T0.1 Repo skeleton: rebar3 project, Makefile check target, app stubs
- [x] T0.2 Vendored spec, golden fixtures, fetch script, test vector constants

## Phase 1: Primitives

- [x] T1.1 C NIF scaffold + BLAKE3 keyed hashing
- [x] T1.2 LZ4 Frame compress/decompress with output cap
- [x] T1.3 Hash string format + BG4 transform + BG4 predictor
- [x] T1.4 Merkle tree + chunk/xorb/file/verification/keyed hashes
- [x] T1.5 Gearhash chunker: NIF scanner + pure reference + equivalence

## Phase 2: Formats

- [x] T2.1 Xorb codec: encode with auto compression, strict decode, extraction
- [x] T2.2 Shard codec: upload + stored forms, lookup tables, footer
- [x] T2.3 Dedup helpers: eligibility, keyed hashes, dedupe-shard build/match

## Phase 3: Engine (pure)

- [x] T3.1 Upload planner: dedup, defrag prevention, xorb packing, terms
- [x] T3.2 Reconstruction planner: byte range to terms, V1/V2 shapes

## Phase 4: Server storage

- [x] T4.1 xet_metadata behaviour + rocksdb backend (column families)
- [x] T4.2 xet_blob_store behaviour + filesystem backend
- [x] T4.3 S3 backend on livery_s3 + Garage CT suite

## Phase 5: Server API

- [x] T5.1 Service skeleton: routes, auth, middleware, healthz
- [x] T5.2 Xorb upload (spool, validate, commit) + HEAD
- [x] T5.3 Shard upload + registration
- [x] T5.4 Reconstruction endpoints v1 + v2 + HEAD files
- [x] T5.5 FS data endpoint + caching header conformance
- [x] T5.6 Chunks endpoint + HMAC key rotation

## Phase 6: Client

- [x] T6.1 Client core: auth refresh, retry wrapper, raw calls
- [x] T6.2 Upload pipeline
- [x] T6.3 Download pipeline
- [x] T6.4 Shard cache
- [x] T6.5 Chunk cache
- [x] T6.6 CLI escript

## Phase 7: Conformance + hardening

- [x] T7.1 Reference fixture interop suite
- [x] T7.2 Cross-implementation e2e (Python reference client) + restart durability
- [x] T7.3 Load smoke + observability
- [x] T7.4 Server release packaging (relx)
- [x] T7.5 Docs + v0.1.0 tag + CI wiring

## Phase 8: Config + security (0.2.0)

- [x] T8.1 xet_config: validated configuration with listed errors
- [x] T8.2 Persist url_secret in metadata (survives restarts)
- [x] T8.3 Env-driven release config: sys.config.src + vm.args.src
- [x] T8.4 TLS first-class: boot validation, http3 PEM loading, rotation
- [x] T8.5 xet_auth_file: file tokens, reload, admin scope
- [x] T8.6 Request timeouts + security headers
- [x] T8.7 /data rate limiter keyed by signature

## Phase 9: Observability (0.2.0)

- [x] T9.1 /metrics endpoint + observability on by default
- [x] T9.2 xet_metrics + ingest counters
- [x] T9.3 Store op histograms + chunk query counters
- [x] T9.4 Access log + session id + trace correlation
- [x] T9.5 Error logging on failure paths
- [x] T9.6 /readyz readiness checks
- [ ] T9.7 Admin scaffold + GET /admin/stats
- [ ] T9.8 Observability docs + logger config block

## Phase 10: Storage lifecycle (0.2.0)

- [ ] T10.1 Spool startup sweep
- [ ] T10.2 Disk-full handling (507 + readiness)
- [ ] T10.3 Reconstruction graceful missing-xorb
- [ ] T10.4 S3 put retry: prove + document
- [ ] T10.5 xorb created_at (schema evolution)
- [ ] T10.6 Maintained counters (bytes, xorbs, files)
- [ ] T10.7 Metadata fold + delete callbacks
- [ ] T10.8 GC guard (registration/sweep exclusion)
- [ ] T10.9 DELETE /admin/files/{hash}
- [ ] T10.10 xet_gc: mark-and-sweep of unreferenced xorbs
- [ ] T10.11 FS orphan-blob sweep
- [ ] T10.12 Scrub: verify-at-rest
- [ ] T10.13 Backup: rocksdb checkpoint + runbook
- [ ] T10.14 rocksdb tuning passthrough

## Phase 11: Lifecycle + packaging (0.2.0)

- [ ] T11.1 Graceful drain on shutdown
- [ ] T11.2 Dockerfile + compose
- [ ] T11.3 Release workflow: tarball + GHCR image on tag
- [ ] T11.4 Service integration: systemd + FreeBSD rc.d
- [ ] T11.5 docs/production.md + deploy guide updates

## Phase 12: Validation + release (0.2.0)

- [ ] T12.1 Load/soak re-run + acceptance sweep
- [ ] T12.2 HA design document (0.3.0 blueprint)
- [ ] T12.3 v0.2.0 tag + release

## Deferred beyond 0.2

- Multi-node replication/HA implementation (0.3.0; design in T12.2)
- S3 orphan-blob sweep, incremental backups (rocksdb backup engine)
- JWT/OIDC auth, IP-keyed rate limiting (needs peer IP in livery)
- Batch reconstructions, file-chunk-hashes endpoint (X-Range-Dirty)
- multipart/byteranges data responses
- Adaptive concurrency, HF Hub token exchange, barrel_docdb metadata backend
- Multi-arch Docker images, FreeBSD CI builds and pkg(8) packages
- CLI admin subcommands
