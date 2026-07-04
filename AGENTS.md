# Agents

Instructions for AI coding agents working on this project.

## Project Overview

Erlang implementation of the XET content-addressable storage protocol
(draft-denis-xet-05): client library plus a standalone CAS server. Requires
Erlang/OTP 27+ (developed on 29), rebar3, and a C toolchain for the NIF.
The vendored spec lives in `docs/spec/`; the task plan of record is
`docs/features.md` (one checkbox per reviewed task).

## Required Checks

Every change must be formatted and pass all checks before committing:

```bash
rebar3 fmt                  # Auto-format (always run first)
rebar3 compile              # Must compile cleanly (builds c_src via pre_hooks)
rebar3 eunit                # Unit tests must pass
rebar3 ct                   # Common Test suites must pass
rebar3 lint                 # Elvis linter must pass
rebar3 dialyzer             # Type checking must pass
rebar3 xref                 # Cross-reference analysis must pass
```

`make check` runs all of the above. Commits use a plain imperative subject,
no generated/co-authored-by lines, and tick the matching box in
`docs/features.md`.

## Build & Development Commands

```bash
rebar3 compile                              # Build (includes the NIF)
rebar3 eunit --module=xet_nif_tests         # Run one test module
rebar3 as test proper                       # PropEr property tests
rebar3 ct --suite=<name>_SUITE              # Run one CT suite
rebar3 fmt --check                          # Check formatting (erlfmt)
make fixtures                               # Fetch large golden files (63 MB + 15 MB)
```

Test groups that need the large fixtures, Garage/S3, or python3 skip
themselves when those are absent.

## Architecture

Single flat OTP app `barrel_xet`, modules prefixed `xet_`. Layers land phase
by phase (see `docs/features.md`):

- Core (pure, no IO): `xet_hash`, `xet_merkle`, `xet_chunker`, `xet_bg4`,
  `xet_xorb`, `xet_shard`, `xet_dedup`, `xet_upload_plan`, `xet_reconstruction`
- NIF: `xet_nif` on `c_src/` (BLAKE3, LZ4 Frame, Gearhash scanner)
- Storage: `xet_metadata` (rocksdb), `xet_blob_store` (FS, livery_s3)
- Server: `xet_server` + `xet_h_*` handlers on livery
- Client: `xet_client` on livery_client

### C code (c_src/)

One feature per small C file (`xet_blake3.c`, ...); `xet_nif.c` only
registers NIFs; shared declarations in `xet_nif.h`. Every operation has a
normal and a dirty-CPU registration; `xet_nif.erl` picks by input size.
Vendored upstream code (`c_src/blake3/`, ...) is pinned by tag in its
VERSION file and never edited.

### Test Organization

- `test/*_tests.erl` - EUnit
- `test/prop_*.erl` - PropEr properties
- `test/*_SUITE.erl` - Common Test
- `test/fixtures/` - golden reference files (see its README); large ones via
  `make fixtures` into `test/fixtures/large/` (gitignored)
- `test/xet_test_vectors.erl` - spec Appendix C + cross-implementation vectors

## Code Rules

- Keep files small. Elvis enforces max_module_length 500 and
  max_function_length 30 with no ignore lists: split modules instead of
  adding exceptions. The same applies to C files (one feature per file) and
  docs.
- Erlang style is whatever `rebar3 fmt` (erlfmt) produces; elvis rules live
  in `rebar.config`. Atom regex: `^[a-z](_?[a-zA-Z0-9]+)*(_SUITE)?$`.
- Wire formats and hashes must match the spec byte for byte; every format
  change needs a vector or golden-fixture test.
