---
name: protocol-change-review
description: Run the three required checks (compliance, latest specification, safety) on a barrel_xet change, commit or pull request that touches chunking, hashes, xorbs, shards, dedup, reconstruction, the HTTP API (statuses, headers, ranges, caching), signed URLs, authentication or a storage backend. Use before committing, before opening or merging a PR, when reviewing a contributor PR, and when asked whether code follows the spec.
---

# Protocol change review

barrel_xet talks to untrusted clients, and its client to untrusted servers.
A change is done when it matches the spec, the spec is the current one, and
a hostile peer cannot use it. Run the three checks below on each commit; a PR
with several commits gets one verdict per commit. The spec list is in
[AGENTS.md](../../../AGENTS.md#specifications).

## 1. Compliance

Follow the [spec-compliance](../spec-compliance/SKILL.md) skill: read the
spec text, check every quoted sentence and the section around it, the
requirement level, the status code or error and the action, and every path
that reaches the code (upload and download, client and server, filesystem
and S3 backends, V1 and V2 reconstruction, footered and bare xorbs, upload
and stored shards).

Then check the test:

- It fails on main and passes with the change. Use a worktree at the merge
  base, not `git stash`:

```bash
git worktree add ../barrel_xet_base origin/main
cp test/xet_x_tests.erl ../barrel_xet_base/test/
cd ../barrel_xet_base && rebar3 eunit --module=xet_x_tests
```

- It asserts the outcome the spec names (the reject reason, the status, the
  bytes) and cannot also pass on a crash or a missing result.

Suites to run (setup in [CONTRIBUTING.md](../../../CONTRIBUTING.md#tests)):
`make check`; with `make fixtures`, the interop and reference tests; for a
format, hash or API change, `xet_crossimpl_SUITE` with the Python reference
client and hf_xet, and `xet_xetcore_SUITE` for shards; for a storage change,
the `xet_store_s3_SUITE` live group on both Garage and RustFS.

## 2. Latest specification

1. Name the governing document. For the draft, confirm the revision is
   current: `curl -s 'https://datatracker.ietf.org/api/v1/doc/document/draft-denis-xet/?format=json'`
   (`rev`). For an xet-core extension, name the xet-core version and the
   file and line you read (`gh api repos/huggingface/xet-core/releases/latest`).
   For an RFC, check `https://www.rfc-editor.org/rfc/rfcNNNN.json`
   (`obsoleted_by`, `updated_by`).
2. Read the section in that revision, not the vendored copy alone when a
   newer revision exists: constants, hash keys, status codes and response
   fields are what drifts.
3. For xet-core, also read `api_changes/` in its repo for the endpoint you
   touch.
4. Write the version and the date checked in the PR description.
5. If the latest text disagrees with the code, fix it in the change or say in
   the PR that it is out of scope, and add it under "Pending updates" in
   AGENTS.md. Moving to a new version follows "Keeping the specifications
   current" there.

## 3. Safety

Walk the classes that apply and state which you checked.

- **Resource exhaustion**: request bodies (`max_xorb_bytes`,
  `max_shard_bytes`, spooling), decompression (8192 chunks and 64 MiB
  unpacked per xorb, checked from the headers before decompressing), counts
  in footers and shards checked against the bytes present, batch sizes,
  ranges per request, caches with a size cap. A client must not grow any of
  them without a bound set by the spec or an option.
- **Integrity**: the server recomputes chunk and xorb hashes on xorb upload,
  the file hash and verification entries on shard registration, and never
  rewrites an existing file entry; the client checks term lengths and the
  file hash on full downloads.
- **Authentication**: scopes per route (read, write, admin), the bearer
  exemption only on the signed data route, HMAC signatures and expiry on
  data URLs, constant-time token comparison, tokens only over TLS.
- **Paths and keys**: namespaces validated and hashes parsed before they
  reach a filesystem path or S3 key; nothing outside the data dir or bucket.
- **Dedup privacy**: chunk queries answered with keyed hashes (14.3), and
  only within the principal's namespaces once access control is on.
- **Caching**: no response cacheable past the life of the URL that served it;
  reconstruction responses `private, no-store`.
- **Secrets**: no token, URL secret or S3 credential in logs, metrics or
  error bodies.

Never weaken a limit to let a legitimate client pass; exclude that case
precisely. A regression test for an attack drives it through the HTTP API or
the decoder and asserts the bound or the rejection.

A finding from this check is a bug when its fix is to follow the spec, even
if it is an exhaustion or crash vector: public PR, CHANGELOG with the spec
section, no advisory, no CVE, no attack description. Authentication, path
escapes and secret handling stay security issues. See "Specification issues
are bugs, not security issues" in AGENTS.md.

## Report

One block per commit, in the PR description or the hand-off:

```
<sha> <subject>
  spec: draft-denis-xet-05 §7.3.2 MUST, quote verified | not found | paraphrased
  latest: draft-denis-xet-05 current (checked 2026-11-10)
  verdict: compliant | partial (<missing>) | wrong (<why>) | not a spec item
  test: fails before, passes after | does not discriminate | missing
  interop: cross-implementation suites run, result
  safety: <classes checked>, <bounds>, no new unbounded state
```

Then list what needs the maintainer's decision: a SHOULD left out, a
deliberate deviation, a spec update that is out of scope.
