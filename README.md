# barrel_xet

XET protocol (draft-denis-xet-05) for Erlang: content-addressable storage with
chunk-level deduplication. Ships a client library and a standalone CAS server.

Status: work in progress. Task checklist: [doc/features.md](doc/features.md).

## Build

You need OTP 27+ and rebar3.

```sh
rebar3 compile
```

## Test

```sh
make check    # xref + eunit + ct + dialyzer
```

Some test groups need extra fixtures or services and skip themselves when
absent:

```sh
make fixtures # downloads large golden files from the XET reference dataset
```

## Spec

The vendored spec text lives in `doc/spec/`. Reference:
https://datatracker.ietf.org/doc/draft-denis-xet/
