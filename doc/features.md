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
- [ ] T2.3 Dedup helpers: eligibility, keyed hashes, dedupe-shard build/match

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

- [ ] T7.1 Reference fixture interop suite
- [ ] T7.2 Cross-implementation e2e (Python reference client) + restart durability
- [ ] T7.3 Load smoke + observability
- [ ] T7.4 Server release packaging (relx)
- [ ] T7.5 Docs + v0.1.0 tag + CI wiring

## Deferred beyond 0.1

- Garbage collection of unreferenced xorbs, multi-node replication/HA
- Batch reconstructions, file-chunk-hashes endpoint (X-Range-Dirty)
- multipart/byteranges data responses
- Adaptive concurrency, HF Hub token exchange, barrel_docdb metadata backend
