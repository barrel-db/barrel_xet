---
name: release-checks
description: Run the checks a barrel_xet release needs before it is tagged, including the ones CI skips (live S3 on Garage and RustFS, the Python reference client, hf_xet, xet-core's shard reader, large fixtures, the image on both architectures), then cut the release. Use before tagging any version, and when asked whether a release is ready.
---

# Release checks

CI runs `make check` and the release smoke, but several suites skip there or
need something CI does not have. Run all of them before a tag, and report
each one with its result and any skip. Nothing is pushed, tagged or
published without the maintainer's explicit yes.

## 1. Specification list

Check the versions in [AGENTS.md](../../../AGENTS.md#specifications) as
described in "Keeping the specifications current": the draft revision, the
latest xet-core release and its `api_changes/`, RFC 9110 and 9111. Update
"Last checked". A newer version found goes under Pending updates, not into
the release.

## 2. Local checks

```bash
make fixtures                 # once; the reference tests skip without them
make check
make smoke
```

## 3. Independent implementations

Use a throwaway venv so user site-packages stay untouched:

```bash
uv venv "$SCRATCH/pyenv"
uv pip install --python "$SCRATCH/pyenv" blake3 lz4 requests hf_xet
PATH="$SCRATCH/pyenv/bin:$PATH" rebar3 ct --suite=xet_crossimpl_SUITE
rebar3 ct --suite=xet_xetcore_SUITE      # needs cargo
```

All cases must run (no skips): the Python reference client both ways, hf_xet
both ways plus global dedup, and the xet-core shard reader.

## 4. Live S3

Run the live group on both backends; they differ in ways the fake does not:

```bash
bash test/docker/garage-up.sh     # then export the XET_S3_* it prints
rebar3 ct --suite=xet_store_s3_SUITE
bash test/docker/garage-down.sh

bash test/docker/rustfs-up.sh     # then export the XET_S3_* it prints
rebar3 ct --suite=xet_store_s3_SUITE
bash test/docker/rustfs-down.sh
```

Export each backend's variables in a subshell, so the second run does not
inherit the first.

## 5. Images

Build and smoke the image natively, and for the other architecture under
emulation. Under emulation the stock `erlang:29` JIT needs
`ERL_AFLAGS="+JMsingle true"`; build from a scratch copy of the Dockerfile
with that set, and never commit it (native CI builds don't need it):

```bash
docker build -t barrel_xet:smoke .
docker run -d --name bx -p 18080:8080 barrel_xet:smoke
curl -fsS http://127.0.0.1:18080/healthz && curl -fsS http://127.0.0.1:18080/readyz
docker exec bx /opt/barrel_xet/bin/barrel_xet eval 'application:get_key(barrel_xet, vsn).'
docker rm -f bx
```

The version printed must be the one being released.

## 6. Cut the release

Only after the maintainer says yes:

1. The release commit bumps `src/barrel_xet.app.src` and the relx version in
   `rebar.config`, adds the CHANGELOG section (plain English, what changed
   for the user, no implementation details), and ticks the task in
   `docs/features.md`. Keep it the last commit: if fixes land after it, move
   it back on top before tagging.
2. Push `main`, then tag and publish:

```bash
git tag -a vX.Y.Z -m "barrel_xet X.Y.Z" <release-sha>
git push origin vX.Y.Z
gh release create vX.Y.Z --verify-tag --title "barrel_xet X.Y.Z" --notes-file <changelog-section.md>
```

3. Watch the release workflow (`gh run watch`): it attaches the tarball and
   pushes the GHCR image. Report the run result and the artifact names.

## Report

```
spec list: checked <date>, pending: none | <items>
make check / smoke: pass | fail
crossimpl: python <n/n>, hf_xet <n/n>; xetcore <n/n>
live S3: garage <n/n>, rustfs <n/n>
images: native <arch> ok, emulated <arch> ok, vsn <X.Y.Z>
```
