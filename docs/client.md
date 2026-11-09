# Upload and download from Erlang

This guide uses the barrel_xet client to store and fetch files against a
CAS server. Use it when your application chunks, deduplicates, and
transfers large files through XET rather than shelling out to the CLI.

## Create a client

```erlang
Client = xet_client:new(#{
    endpoint => <<"http://127.0.0.1:8080">>,
    token => <<"write-token">>
}).
```

Options: `dialect` (`draft` default, or `hf`), `retry` (merged over the
xet-core defaults), `concurrency`, `circuit_breaker`, `shard_cache`,
`chunk_cache`, and a `{refresh, Fun}` token provider.

Tokens go over TLS only: with a token, an `http` endpoint that is not
loopback (`localhost`, `127.0.0.1`, `::1`) makes `new/1` raise
`{insecure_endpoint, Endpoint}`. Pass `allow_insecure_http => true` to
opt out on a trusted network.

## Upload

```erlang
{ok, #{file_hash := Hash, stats := Stats}} =
    xet_client_upload:upload_data(Client, my_file_id, Bytes).

%% or from disk
{ok, #{file_hash := Hash}} =
    xet_client_upload:upload_file(Client, my_file_id, "/path/to/file").
```

`stats` reports `new_bytes`, `deduped_bytes`, `new_chunks`, etc. Chunks
already present on the server are not re-uploaded.

Upload several files in one deduplication session:

```erlang
{ok, Results} = xet_client_upload:upload_files(Client, [{a, DataA}, {b, DataB}]).
```

## Download

```erlang
{ok, Bytes} = xet_client_download:download_data(Client, Hash).

%% a byte range (inclusive)
{ok, Slice} = xet_client_download:download_range(Client, Hash, {0, 1023}).

%% straight to a file
ok = xet_client_download:download_file(Client, Hash, "/path/to/out").
```

A full download recomputes and verifies the file hash; per-term lengths
are always checked. Expired download URLs are recovered automatically by
re-querying reconstruction.

## Offline deduplication

Pass a shard cache to dedup against earlier uploads without network
queries, and a chunk cache to skip repeat downloads:

```erlang
ShardCache = xet_shard_cache:open("/var/cache/xet/shards"),
Client = xet_client:new(#{endpoint => Endpoint, token => Token,
                          chunk_cache => xet_chunk_cache:open("/var/cache/xet/chunks")}),
{ok, _} = xet_client_upload:upload_files(Client, Files, #{shard_cache => ShardCache}).
```
