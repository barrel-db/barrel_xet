# Agents

Instructions for AI coding agents working on barrel_xet. Read this file
before you change anything; it applies to every agent and every change.

## Project Overview

Erlang implementation of the XET content-addressable storage protocol
(draft-denis-xet-05): client library plus a standalone CAS server. Requires
Erlang/OTP 27+ (developed on 29), rebar3, and a C toolchain for the NIF.
The vendored spec lives in `docs/spec/`; the task plan of record is
`docs/features.md` (one checkbox per reviewed task).

## First principle: compliance, latest spec, safety

barrel_xet faces untrusted clients, and its client faces untrusted servers.
Every change that touches how chunks, hashes, xorbs, shards or
reconstructions are read, parsed, verified or written, how an HTTP endpoint
answers (status, headers, body shape, ranges, caching), or how storage,
authentication or signed URLs behave, must pass three checks before it is
called done, committed or opened as a pull request:

1. **Compliance**: the behaviour matches the governing spec section (or the
   xet-core code, for an extension), and a test shows the accept and the
   reject path. The test fails on main without the change.
2. **Latest specification**: you checked that the spec you cite is the current
   one (no newer draft revision, xet-core version or RFC that changes the
   rule), and you read the section itself instead of quoting from memory.
3. **Safety**: the change does not open a known abuse class (resource
   exhaustion, integrity bypass, authentication bypass, path escape, dedup
   leak) and every per-request resource it touches stays bounded.

Use the [protocol-change-review](.agents/skills/protocol-change-review/SKILL.md)
skill to run them. When in doubt whether a change is protocol code, it is.

## Specification issues are bugs, not security issues

A report is a specification issue when the fix is to make barrel_xet do what
a spec it implements says (see [Specifications](#specifications)):

- a chunk boundary, hash, xorb, shard, footer or lookup table that differs
  from the draft or from xet-core;
- input accepted or rejected differently from the spec (chunk header rules,
  footer idents and versions, shard flags and reserved fields, hash strings);
- a wrong status code, header or response shape on an endpoint;
- a missing or wrong bound the spec or an option defines (chunk and xorb
  limits, body caps, range and batch limits);
- a hash or verification entry the spec says to check and the code does not.

This holds even when the report calls it denial of service, resource
exhaustion or a remote crash. Treat it as a bug:

- fix it in a public pull request, with a public issue if one is needed;
- list it in the CHANGELOG in plain English, citing the spec section;
- do not open a GitHub Security Advisory, request a CVE, embargo the fix,
  give it a severity, or describe how to attack it;
- when it arrived as an advisory, close the advisory as not a vulnerability
  and link the pull request that fixes it.

Only a problem that is not a spec deviation goes through
[SECURITY.md](SECURITY.md): code execution; a request served without the
authentication or scope the configuration asks for (tokens, admin endpoints,
signed data URL signatures and expiry); secrets reaching someone else
(tokens, the URL secret, S3 credentials, in logs, metrics or errors); files
or blobs outside the data directory or bucket; one tenant's data reaching
another once namespace access control is configured. Authentication stays a
security issue even where a spec describes the check. If unsure, ask the
maintainer before treating anything as a security issue.

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
`docs/features.md`. See [CONTRIBUTING.md](CONTRIBUTING.md) for the rest of
the workflow.

## Pull Requests

Work on one issue goes in one pull request. Give each change a reviewer has to
look at its own commit, with its tests. Docs and CHANGELOG entries go in the
same pull request.

- Every bug fix and feature has a test. Show it failing on main.
- Never relax a limit or a check to make a client pass; exclude the
  legitimate case precisely.
- Descriptions state what was wrong, the fix in a few lines, and breaking
  changes. Reference issues with `Fixes #N`. No test plan, no file-by-file
  walkthrough.
- No `Co-Authored-By`, "Generated with" or similar trailers, in commits or
  pull requests.
- CHANGELOG: plain English, what was wrong or what is new and what it means
  for the user, the spec section when there is one. No implementation
  details, no attack narratives. Release notes reuse the CHANGELOG section.
- Follow "Write for the person who reads it" in
  [CONTRIBUTING.md](CONTRIBUTING.md#write-for-the-person-who-reads-it): plain
  English, no inflated or pseudo-technical wording, and a person has read the
  change before it is opened.

## Specifications

The specs barrel_xet implements, at the version the code follows. Where a
newer one exists it is listed under [Pending updates](#pending-updates).
Last checked: 2026-11-10.

### XET

| Spec | Scope in barrel_xet | Code |
|---|---|---|
| draft-denis-xet-05 §5 | Gearhash content-defined chunking | `xet_chunker`, `xet_chunker_ref`, `c_src/xet_gearhash.c` |
| draft-denis-xet-05 §6 | chunk, xorb, file, verification and keyed hashes; hash strings | `xet_hash`, `xet_merkle`, `c_src/xet_blake3.c` |
| draft-denis-xet-05 §7 | xorb format, chunk headers, LZ4 and BG4, CasObjectInfo footer, size limits | `xet_xorb`, `xet_xorb_footer`, `xet_bg4`, `c_src/xet_lz4.c` |
| draft-denis-xet-05 §8, §12 | reconstruction terms, range queries, download | `xet_reconstruction`, `xet_h_reconstructions`, `xet_client_download` |
| draft-denis-xet-05 §9 | shard format, lookup tables, keyed chunk hashes | `xet_shard`, `xet_shard_footer` |
| draft-denis-xet-05 §10, §11 | dedup, fragmentation prevention, upload | `xet_dedup`, `xet_defrag`, `xet_upload_plan`, `xet_client_upload`, `xet_h_chunks` |
| draft-denis-xet-05 §13 | caching, signed URLs, HTTP caching headers | `xet_h_data`, `xet_url_signer`, `xet_chunk_cache`, `xet_shard_cache`, `xet_store_s3` |
| draft-denis-xet-05 §14 | content integrity, auth, dedup privacy, DoS limits | `xet_h_xorbs`, `xet_h_shards`, `xet_auth*`, `xet_config` |
| draft-denis-xet-05 Appendix A | HTTP API paths, statuses and JSON shapes | `xet_routes`, `xet_h_*` |
| draft-denis-xet-05 Appendix B, C | gear table, test vectors | `c_src/xet_gear_table.h`, `test/xet_test_vectors.erl` |

### xet-core extensions

Where the draft is silent or differs, the reference is xet-core 1.8.x
(https://github.com/huggingface/xet-core), checked against its code:

| Extension | Code | Checked by |
|---|---|---|
| V2 reconstruction (`/v2/reconstructions`, multi-range fetch entries) | `xet_reconstruction:to_v2/2`, `xet_client_download` | `xet_crossimpl_SUITE` hf_xet cases |
| Shard lookup-table indices in 48-byte entry units | `xet_shard_footer:encode_lookups/2` | `xet_xetcore_SUITE` |
| Metadata-ext SHA-256 stored byte-swapped | `xet_shard` | `xet_interop_SUITE` reference shards |
| hf path dialect (`/v1/...`, bare `/shards`) | `xet_routes`, `xet_client` | hf_xet cases |

### HTTP

| Spec | Scope | Code |
|---|---|---|
| RFC 9110 HTTP semantics | status codes, Range and 206/416, multi-range | `xet_http_range`, `xet_h_data`, `xet_h_reconstructions` |
| RFC 9111 HTTP caching | Cache-Control, Expires, ETag on signed URLs | `xet_h_data`, `xet_store_s3` |

### Keeping the specifications current

A spec changes under the code when the draft gets a new revision, xet-core
releases a version that changes a format or endpoint, or an RFC is obsoleted.
Check the list:

- before every release;
- when you change a module listed in it, for the specs that module follows;
- when hf_xet or another client moves to a newer xet-core, since interop
  breaks first.

Check the draft with
`curl -s 'https://datatracker.ietf.org/api/v1/doc/document/draft-denis-xet/?format=json'`
(`rev`), xet-core with `gh api repos/huggingface/xet-core/releases/latest`
(and `api_changes/` in that repo), and an RFC with
`curl -sL https://www.rfc-editor.org/rfc/rfcNNNN.json` (`obsoleted_by`,
`updated_by`). Then set "Last checked" above.

When a newer version exists, it is its own piece of work, not a side change:

1. Add it under [Pending updates](#pending-updates) with what is known to
   differ.
2. Diff the sections the code relies on, old version against new, and list
   every change: formats, constants, hash keys, endpoints and statuses, MUST
   and SHOULD changes, removed features.
3. Decide per change: follow it now, or keep the old behaviour and say why.
4. Make the change in one pull request, one commit per item, each with a
   test, run through the [protocol-change-review](.agents/skills/protocol-change-review/SKILL.md)
   checks, and run the cross-implementation suites.
5. Vendor the new draft text in `docs/spec/`, update the citations in the
   code it touches, the rows above and the "Last checked" date, and remove it
   from Pending updates. Add a CHANGELOG entry when behaviour or a format
   changes.

### Pending updates

None known, checked 2026-11-10 (draft-denis-xet-05 is the latest revision;
xet-core 1.8.x; RFC 9110 and 9111 current).

## Skills

Task guides for agents live in `.agents/skills/<name>/SKILL.md`; read the one
that matches the task before starting. `.claude/skills` links to the same
directories, so there is one copy.

- [protocol-change-review](.agents/skills/protocol-change-review/SKILL.md):
  the three checks above (compliance, latest spec, safety) for a change, a
  commit or a pull request.
- [spec-compliance](.agents/skills/spec-compliance/SKILL.md): check a change
  or pull request against draft-denis-xet, xet-core and the HTTP RFCs.
- [release-checks](.agents/skills/release-checks/SKILL.md): the checks to run
  before tagging a release, including those CI cannot run.

## Build & Development Commands

```bash
rebar3 compile                              # Build (includes the NIF)
rebar3 eunit --module=xet_nif_tests         # Run one test module
rebar3 as test proper                       # PropEr property tests
rebar3 ct --suite=<name>_SUITE              # Run one CT suite
rebar3 fmt --check                          # Check formatting (erlfmt)
make fixtures                               # Fetch large golden files (63 MB + 15 MB)
make smoke                                  # Build the release and boot it
```

Test groups that need the large fixtures, a live S3 (Garage or RustFS),
python3 with the reference client deps or hf_xet, or cargo skip themselves
when those are absent. The table in [CONTRIBUTING.md](CONTRIBUTING.md#tests)
says how to enable each.

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
- `test/python/` - the draft's Python reference client and the hf_xet driver
- `test/xetcore/` - a cargo harness reading shards through xet-core
- `test/docker/` - Garage and RustFS for the live S3 group

## Code Rules

- Keep files small. Elvis enforces max_module_length 500 and
  max_function_length 30 with no ignore lists: split modules instead of
  adding exceptions. The same applies to C files (one feature per file) and
  docs.
- Erlang style is whatever `rebar3 fmt` (erlfmt) produces; elvis rules live
  in `rebar.config`. Atom regex: `^[a-z](_?[a-zA-Z0-9]+)*(_SUITE)?$`.
- Wire formats and hashes must match the spec byte for byte; every format
  change needs a vector or golden-fixture test.
- Never trust a stored or received length, offset or count: check it
  against the spec limit and the bytes actually present before allocating or
  slicing.
