# barrel_xet

XET protocol ([draft-denis-xet-05](https://datatracker.ietf.org/doc/draft-denis-xet/))
for Erlang: content-addressable storage with chunk-level deduplication.
Ships a client library, a standalone CAS server, and a CLI.

- Content-defined chunking (Gearhash), BLAKE3 keyed hashing, LZ4 Frame
  compression, in a vendored C NIF.
- xorb and shard binary formats, verified byte-for-byte against the
  Hugging Face reference fixtures and the draft's Python reference client.
- Server on [livery](https://github.com/benoitc/livery) (HTTP/1.1, HTTP/2,
  HTTP/3), rocksdb metadata, filesystem or S3 blob storage.
- Client with global + local deduplication, parallel transfers, retry and
  circuit-breaking via livery_client layers.

Requires OTP 27+ (developed on 29), rebar3, and a C toolchain (cmake). On
Linux, rocksdb's build also needs the compression dev libraries:

```sh
sudo apt-get install -y cmake build-essential \
    liblz4-dev libsnappy-dev libzstd-dev zlib1g-dev libbz2-dev
```

## Build and test

```sh
rebar3 compile
make check            # fmt + xref + lint + eunit + proper + ct + dialyzer
make fixtures         # optional: fetch large golden files for interop tests
```

## Run a server

```sh
make release
_build/prod/rel/barrel_xet/bin/barrel_xet daemon
curl -s http://127.0.0.1:8080/healthz
```

## Guides

- [Getting started](docs/getting-started.md) — concepts, a running server,
  your first upload and download
- [Embed barrel_xet in your app](docs/embedding.md) — client and server
  inside your own OTP application
- [Upload and download from Erlang](docs/client.md)
- [Command-line usage](docs/cli.md)
- [Deploy the server (filesystem)](docs/deploy-server.md)
- [Deploy the server (S3 / Garage)](docs/deploy-s3.md)
- [Task checklist](docs/features.md)

## Spec

The vendored draft text is in `docs/spec/`.

## License

Apache-2.0.
