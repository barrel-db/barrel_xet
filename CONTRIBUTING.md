# Contributing

This page is for people changing barrel_xet itself. For using it, start with
[docs/getting-started.md](docs/getting-started.md). For finding your way
around the source, read the Architecture section of [AGENTS.md](AGENTS.md),
and keep the vendored spec, [docs/spec/draft-denis-xet-05.txt](docs/spec/draft-denis-xet-05.txt),
open.

## Write for the person who reads it

Every issue, pull request and comment is read by a person. Make it easy for
them.

- Read what you send before you send it. You are responsible for every line,
  whether you wrote it or a tool did.
- Use plain English and short sentences. Say what happens, what you
  expected, and how to reproduce it. Explain any term a reader may not know.
- Don't inflate it. No buzzwords, no severity scores, CVSS or CWE labels, no
  "critical" for a bug, no long generated write-ups. If it takes a page to
  explain, cut it down until it doesn't.
- A bug report gives: the barrel_xet and OTP versions, client or server, the
  storage backend (filesystem or S3, and which S3), the config you set, the
  other implementation when there is one (xet-core/hf_xet, the Python
  reference client), a minimal reproduction, what you got and what you
  expected. A failing xorb or shard file, or the request and response, helps
  most.
- A pull request says what was wrong and why it matters, the fix in a few
  lines, and any breaking change. Link the issue. Don't walk through the diff
  file by file; the reviewer reads the code.
- A fix comes with a test that fails without it.

AI tools are fine to use. Before you open anything, you must have read the
change, run the tests, and be able to answer questions about it yourself.

Maintainers read every issue and pull request before acting on it. We close
without further review:

- text we cannot understand after one request to clarify;
- descriptions that don't match the code or the reproduction;
- reports that cannot be reproduced;
- submissions opened by an automated agent that no person has read.

## Security issues and specification bugs

barrel_xet implements draft-denis-xet and the xet-core extensions listed in
[AGENTS.md](AGENTS.md#specifications).

When the fix is to make barrel_xet do what one of these specifications says,
it is a bug, not a security issue. That includes reports described as denial
of service, resource exhaustion or a remote crash, when they come from:

- a xorb, shard, hash or reconstruction accepted, rejected or encoded
  differently from the specification;
- a wrong status code, header or response shape on an endpoint;
- a size or count limit the specification or an option defines and the code
  does not enforce;
- a hash or verification entry the specification says to check and the code
  does not.

Report these as a normal bug, in public. Cite the specification section. The
fix goes in a public pull request and in the CHANGELOG. We don't publish
advisories or request CVEs for them, and advisories filed for them are closed
with a link to the fix.

Only problems that are not a specification deviation go through
[SECURITY.md](SECURITY.md): code execution, a request served without the
authentication or scope the configuration asks for (tokens, admin endpoints,
signed data URLs), secrets reaching someone else, files or blobs outside the
data directory or bucket, or one tenant's data reaching another.

## Keeping the specifications current

The specifications barrel_xet follows, and the version of each, are listed in
[AGENTS.md](AGENTS.md#specifications), with newer versions not yet followed
under Pending updates. The list is checked before every release and when a
module it names changes.

Moving to a new draft revision or xet-core version is its own pull request:
first the list of what changed in the sections the code uses, then one commit
per change with its test, then the cross-implementation suites against both
versions. The steps are in
[Keeping the specifications current](AGENTS.md#keeping-the-specifications-current).
If you notice a newer version, open an issue naming it; that is enough to get
it on the list.

## Set up

You need Erlang/OTP 27 or later (developed on 29), rebar3, and a C toolchain
with cmake for the NIF and rocksdb. On Linux, rocksdb also needs the
compression dev libraries:

```bash
sudo apt-get install -y cmake build-essential liblz4-dev libsnappy-dev \
  libzstd-dev zlib1g-dev libbz2-dev
```

Then:

```bash
git clone https://github.com/barrel-db/barrel_xet.git
cd barrel_xet
rebar3 compile
make fixtures        # large golden files (63 MB + 15 MB), optional
```

Suites that need the large fixtures skip without them, so a missing fixture
looks like a passing test rather than a failure. Fetch them before you change
the chunker, hashes or formats.

## Before you commit

Run what CI runs:

```bash
rebar3 fmt          # format first, then check the rest
make check          # compile, eunit, ct, lint, dialyzer, xref
```

`make smoke` builds the release and boots it, as the release job does.

## Tests

- `test/*_tests.erl` are EUnit tests, run by `rebar3 eunit`.
- `test/prop_*.erl` are PropEr properties, run by `rebar3 as test proper`.
- `test/*_SUITE.erl` are Common Test suites, run one at a time with
  `rebar3 ct --suite=xet_api_SUITE`.
- `test/xet_test_vectors.erl` holds the spec's Appendix C vectors and the
  cross-implementation vectors.

Some groups need something outside the repo and skip without it:

| Needs | Suites | How |
|---|---|---|
| Large fixtures | `xet_interop_SUITE`, chunker and xorb reference tests | `make fixtures` |
| A live S3 | `xet_store_s3_SUITE` group `live` | `bash test/docker/garage-up.sh` or `test/docker/rustfs-up.sh`, then export the `XET_S3_*` variables it prints |
| The draft's Python reference client | `xet_crossimpl_SUITE` python cases | `pip install blake3 lz4 requests` (Python 3.14+) |
| xet-core | `xet_crossimpl_SUITE` hf_xet cases | `pip install hf_xet` |
| xet-core's shard reader | `xet_xetcore_SUITE` | cargo (builds `test/xetcore`) |

Run the relevant ones before you change a wire format, a hash, the HTTP API
or a storage backend. A change to the S3 backend runs the live group on both
Garage and RustFS: they differ (RustFS rejects a PUT without a length, and
Garage ignores response header overrides on ranged GETs).

A test must fail for one reason. A rejection test that also passes when the
call crashes, or a test that asserts a value it computed itself, is worse
than no test because it reads as coverage. Check a fix against the code
before it: the test must fail there.

## What CI enforces

| Job | What it proves |
|---|---|
| erlfmt, Elvis lint, XRef, Dialyzer | Formatting, Elvis rules (500-line modules, 30-line functions), cross references, types |
| Unit Tests (OTP 27, 28, 29; arm64) | `rebar3 eunit` and the PropEr properties on every supported OTP, and on arm64 |
| macOS, FreeBSD | The NIF and rocksdb build there and the unit tests pass; FreeBSD also builds the release tarball |
| Common Test (all suites) | Every suite, with the large reference files fetched |
| Interop | The draft's Python reference client and xet-core (hf_xet) both ways, global dedup through xet-core, shards read by xet-core's reader, the reference files; fails if any of them is skipped |
| Live S3 (garage, rustfs) | The S3 suite and a server roundtrip on both backends; fails if skipped |
| Release cold-start smoke | `make smoke`: the release builds, boots, serves an upload and download, and stops |
| Image (amd64, arm64) | The Docker image builds natively on both architectures, boots, answers `/healthz` and `/readyz`, and reports the source version |

The release workflow (on a `v*` tag) builds the tarball and the GHCR image
and smoke-tests both before publishing.

## Documentation

Write guides in the task-oriented style the existing ones use: say what the
thing is, when you need it, then show the steps with short notes between code
blocks. Snippets are Erlang or shell. Update the guide in the same change as
the code it describes.

## Pull requests

Branch from `main` using the prefix that fits: `fix/`, `feat/`, `perf/`,
`refactor/`, `docs/`, `test/` or `chore/`.

Write the commit subject in the imperative, describing what the code now does
rather than what it used to do. Keep the body to short bullets. Do not add
generated-by or co-authored-by trailers. Tick the matching box in
[docs/features.md](docs/features.md) in the commit that lands the task.

A change to wire formats, hashes or the HTTP API passes the three checks in
[AGENTS.md](AGENTS.md#first-principle-compliance-latest-spec-safety) before it
is opened: compliance with the spec section, the spec being the current one,
and safety against a hostile client.

Say what the change is for and how it works. Skip the test inventory: CI
reports that. If the change touches the public API, show it in a short code
block.

Sync a branch that has fallen behind by merging `main` into it, not by
rebasing.

## Releases

The version lives in `src/barrel_xet.app.src` and in the relx release in
`rebar.config`; bump both. A release is a commit that bumps the version and
adds the CHANGELOG entry, then an annotated tag `vX.Y.Z` on it, then a GitHub
release carrying that CHANGELOG section. The tag runs the release workflow.

Before tagging, check the specification list as described in
[Keeping the specifications current](#keeping-the-specifications-current), and
run the release checks in the
[release-checks](.agents/skills/release-checks/SKILL.md) skill.
