---
name: spec-compliance
description: Check a change, commit or pull request in barrel_xet against the specs it claims to follow (draft-denis-xet-05, the xet-core extensions, RFC 9110 and 9111). Use when reviewing a PR, before merging a format or API fix, or when asked whether code complies with the spec.
---

# Spec compliance check

Use this to decide whether a change does what the spec says, no more and no
less. It applies to one commit at a time; a PR with several commits gets one
verdict per commit.

## 1. Get the spec text

Never quote the spec from memory. The draft is vendored; grep it:

```bash
grep -n "MUST NOT exceed" docs/spec/draft-denis-xet-05.txt
```

When a newer draft revision exists (check `rev` on
`https://datatracker.ietf.org/api/v1/doc/document/draft-denis-xet/?format=json`),
fetch it from datatracker and read the section there too.

For an xet-core extension, read the code, pinned to a release:

```bash
gh api repos/huggingface/xet-core/releases/latest --jq .tag_name
gh api "repos/huggingface/xet-core/contents/xet_core_structures/src/metadata_shard/shard_format.rs?ref=<tag>" \
  --jq .content | base64 -d > "$SCRATCH/shard_format.rs"
```

`api_changes/` in that repo describes each endpoint change. For HTTP, fetch
the RFC text: `curl -sfL https://www.rfc-editor.org/rfc/rfc9110.txt`.

## 2. Check the claim

For each commit:

1. Find every spec sentence the commit message or PR body quotes. Confirm it
   is verbatim and in the section cited. For xet-core, confirm the file and
   line say what is claimed.
2. Read the whole section around it, not only the sentence: exceptions,
   "unless", and the matching rule for the other side (encoder and decoder,
   client and server, upload and stored forms) are usually a paragraph away.
3. Note the requirement level: MUST / MUST NOT is a fix; SHOULD needs a reason
   not to; MAY is a choice, so the change must say why it is worth it.
4. Check the status code or reject reason and the action match the text, and
   that byte layouts match exactly: field order, widths, endianness, the
   8-byte hash swap in hash strings, reserved fields that must be zero.
5. Check the code does what the text says on every path that reaches it:
   footered and bare xorbs, upload and stored shards, V1 and V2
   reconstruction, full and range downloads, filesystem and S3 backends.
6. Check it does not go further than the spec: a new reject where the draft
   says SHOULD or MAY breaks interop with clients allowed to do it. Check
   against xet-core and the Python reference client, which are the clients
   in the field.

## 3. Check the test

- The test fails on main without the fix and passes with it. Run it both
  ways.
- It asserts the outcome the spec names (the reject reason, the status, the
  bytes or hash), and cannot also pass on a crash or a missing result.
- A format change has a vector or golden-fixture test, and is read back by
  an independent implementation where one exists: the Python reference
  client and hf_xet in `xet_crossimpl_SUITE`, xet-core's shard reader in
  `xet_xetcore_SUITE`.

## 4. Report

One line per commit:

```
<sha> <subject>
  spec: draft-denis-xet-05 §9.6.1 | xet-core 1.8.1 shard_format.rs:387, quote verified | quote not found | paraphrased
  verdict: compliant | partial (<what is missing>) | wrong (<why>) | not a spec item (<what it is>)
  test: fails before, passes after | does not discriminate | missing
```

Then list anything that needs the maintainer's decision (a SHOULD left out,
a deliberate deviation, a draft and xet-core disagreement).
