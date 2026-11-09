# Command-line usage

This guide uses the `xet` CLI to upload and download files from a shell.
Use it for quick, scripted transfers; for embedding in an Erlang app, see
[client.md](client.md).

## Build

```sh
rebar3 escriptize        # produces _build/default/bin/xet
```

Because the client depends on NIFs (BLAKE3, LZ4, rocksdb via the server),
prefer running the escript where the built libraries are on the path, or
use a release for a self-contained deployment.

## Configure

```sh
export XET_ENDPOINT=http://127.0.0.1:8080
export XET_TOKEN=write-token
```

`XET_ENDPOINT` defaults to `http://localhost:8080`; `XET_TOKEN` is
optional.

The CLI refuses to send a token over plain `http` to anything but a
loopback address (`localhost`, `127.0.0.1`, `::1`). Use an `https`
endpoint, or, on a trusted network only, opt out:

```sh
export XET_ALLOW_INSECURE_HTTP=1
```

## Commands

```sh
xet up <file>                 # upload; prints the file hash to stdout
xet download <hash> <out>     # download the file at <hash> to <out>
xet info <hash>               # "present" (exit 0) or "absent" (exit 1)
```

Example:

```sh
HASH=$(xet up ./model.safetensors)
xet info "$HASH"              # present
xet download "$HASH" ./copy.safetensors
```

Exit codes: 0 success, 1 error (or absent for `info`), 2 usage.
