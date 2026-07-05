# Getting started

This page gets you from nothing to a running XET store: you'll start a
server, upload a file, and download it back, and along the way you'll pick
up the handful of concepts that make XET worth using. If you just want the
command reference, jump to the [CLI guide](cli.md) or the
[client guide](client.md); if you want the ideas first, read on.

## What XET gives you

XET is content-addressable storage built for large files that change a
little at a time: model checkpoints, datasets, container layers. Instead of
storing each version whole, it splits files into variable-sized **chunks**,
identifies everything by the cryptographic hash of its content, and only
ever stores or transfers a chunk once. Upload a 10 GB checkpoint, change a
layer, upload again, and the second upload sends only the bytes that
actually changed.

A few terms you'll meet:

- **Chunk** — a variable-sized slice of a file (8 KiB to 128 KiB), cut on
  content boundaries so an insertion early in a file doesn't shift every
  boundary after it. Each chunk is named by its BLAKE3 hash.
- **Xorb** — a container that packs many compressed chunks together for
  storage and transfer (up to 64 MiB). This is what actually lands on disk
  or in S3.
- **Shard** — the metadata that says "file X is chunks 0..3 of xorb A then
  chunks 5..9 of xorb B". Reconstructing a file means reading its shard and
  fetching just those chunk ranges.
- **File hash** — a file's content address, derived from its chunk
  composition. Two files with the same bytes get the same file hash, and
  that's the handle you download by.

You never manage chunks or xorbs by hand. You upload bytes and get a file
hash back; you download by file hash and get your bytes. The client does
the chunking, deduplication, and reassembly.

## Start a server

The quickest way is a release node that reads its config and serves on
boot:

```sh
make release
_build/prod/rel/barrel_xet/bin/barrel_xet daemon
curl -s http://127.0.0.1:8080/healthz      # {"status":"ok"}
```

That uses `config/sys.config.src`: a filesystem backend under
`/var/lib/barrel_xet` and a tokens file at `/etc/barrel_xet/tokens`,
both overridable through `BARREL_XET_*` environment variables (see the
[deploy guide](deploy-server.md)).

Prefer to run it from an Erlang shell while you experiment? Start the app
and bring up a server yourself:

```erlang
{ok, _} = application:ensure_all_started(barrel_xet),
{ok, _} = xet_server:start(#{
    name => demo,
    data_dir => "/tmp/xet-demo",
    http => #{port => 8080},
    auth => {xet_auth_static, #{tokens => #{<<"dev-token">> => write}}}
}).
```

## Upload and download

From the shell, make a client and round-trip some data:

```erlang
Client = xet_client:new(#{
    endpoint => <<"http://127.0.0.1:8080">>,
    token => <<"dev-token">>
}),

{ok, #{file_hash := Hash, stats := Stats}} =
    xet_client_upload:upload_data(Client, my_first_file, <<"hello xet">>),

{ok, <<"hello xet">>} = xet_client_download:download_data(Client, Hash).
```

`Hash` is the file's content address; hold onto it to fetch the file later.
`Stats` tells you what the upload actually did — `new_bytes`,
`deduped_bytes`, `new_chunks`. On a fresh file everything is new; upload the
same bytes again and you'll see `new_bytes => 0` because every chunk was
already there.

Or do the same thing from a shell prompt with the CLI:

```sh
export XET_ENDPOINT=http://127.0.0.1:8080 XET_TOKEN=dev-token
HASH=$(xet up ./checkpoint.safetensors)
xet download "$HASH" ./restored.safetensors
```

## Where deduplication happens

Deduplication kicks in at three levels, and you mostly get them for free:

- **Within a session** — repeated chunks in the files you're uploading
  right now are stored once.
- **Against the server** — before uploading, the client asks the server
  which chunks it already has (a keyed, privacy-preserving query) and skips
  those.
- **Against a local cache** — if you pass a shard cache, the client
  remembers what it uploaded before and dedups a re-upload with no network
  round-trips at all.

To turn on the offline cache, open one and hand it to the upload:

```erlang
Cache = xet_shard_cache:open("/var/cache/xet/shards"),
{ok, _} = xet_client_upload:upload_files(Client, [{f, Data}], #{shard_cache => Cache}).
```

## Where to go next

- [Upload and download from Erlang](client.md) — the full client API,
  including byte ranges and the chunk cache.
- [Embed barrel_xet in your app](embedding.md) — run the client or server
  inside your own OTP application.
- [Deploy the server](deploy-server.md) and [with S3](deploy-s3.md) — real
  configuration, TLS, HTTP/2 and HTTP/3, object storage.
