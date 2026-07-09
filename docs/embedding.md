# Embed barrel_xet in your application

This page shows you how to run barrel_xet inside your own OTP application
rather than as a standalone node: how to hold a client, and how to bring up
a CAS server under your own supervision tree. Read the
[getting-started guide](getting-started.md) first if the concepts are new.

## Add the dependency

barrel_xet is a rebar3 application. Add it to your `rebar.config`:

```erlang
{deps, [
    {barrel_xet, {git, "https://github.com/benoitc/barrel_xet.git", {tag, "0.1.0"}}}
]}.
```

It pulls in livery, livery_s3, rocksdb, and hackney, and builds a C NIF, so
your build environment needs a C toolchain and cmake.

## Use the client

A client is a plain value — build it once and reuse it. It's cheap and
holds no processes of its own beyond livery_client's connection pool, so
keep one per endpoint in your app's state:

```erlang
Client = xet_client:new(#{
    endpoint => <<"https://cas.internal:8443">>,
    token => <<"...">>,
    concurrency => 16
}).
```

If your tokens expire, give the client a refresher instead of a static
token. The function is called when the cached token is within 30 seconds of
expiry, and its result is cached:

```erlang
Refresh = fun() ->
    #{access_token := T, exp := Exp} = fetch_from_auth_service(),
    {ok, #{access_token => T, exp => Exp}}
end,
Client = xet_client:new(#{endpoint => Endpoint, token => {refresh, Refresh}}).
```

Uploads and downloads are ordinary blocking calls; run them in a worker or
a task if you don't want to block your gen_server:

```erlang
{ok, #{file_hash := Hash}} = xet_client_upload:upload_file(Client, Id, Path),
{ok, Bytes} = xet_client_download:download_data(Client, Hash).
```

Retry, circuit-breaking, and concurrency limiting all live in livery_client
layers, so transient failures and stale connections are handled for you.

## Run a server under your supervisor

`xet_server:start/1` starts an instance as a child of the barrel_xet
application supervisor, so it outlives the process that called it. That's
usually what you want — call it once during your app's startup:

```erlang
start_cas() ->
    {ok, _Pid} = xet_server:start(#{
        name => my_cas,
        data_dir => "/var/lib/my_app/xet",
        http => #{port => 8080},
        blob => {fs, #{dir => "/var/lib/my_app/xet/xorbs"}},
        auth => {my_auth_module, my_auth_config()}
    }).
```

Each instance is its own `rest_for_one` tree (storage handles first, then
the listeners). Stop it by name:

```erlang
ok = xet_server:stop(my_cas).
```

`stop/1` drains in-flight requests before the listener terminates (up to
`drain_timeout`, default 30000 ms). In an embedded node running several
instances the drain counter is node-wide, so `stop/1` on one instance can
wait on another instance's in-flight requests, bounded by `drain_timeout`.
Run one service per node in production to avoid this.

`start/1` validates its config and returns `{error, {invalid_config,
Reasons}}` (a list of binaries) instead of crashing when a required key is
missing or malformed. Match on it:

```erlang
case xet_server:start(Config) of
    {ok, _Pid} -> ok;
    {error, {invalid_config, Reasons}} -> log_and_bail(Reasons)
end.
```

To autostart a server when the barrel_xet application boots — handy in a
release — set the `server` application env instead of calling `start/1`;
`barrel_xet_app` starts it for you:

```erlang
%% sys.config
{barrel_xet, [{server, #{name => my_cas, data_dir => "...", ...}}]}
```

## Plug in your own auth

Auth is a behaviour. Implement `xet_auth` to check a bearer token against a
required scope (`read` or `write`) however you like — a database, a JWT
verifier, an allowlist:

```erlang
-module(my_auth).
-behaviour(xet_auth).
-export([verify/3]).

verify(Token, Scope, _Opts) ->
    case lookup_token(Token) of
        {ok, Scopes} ->
            case scope_allowed(Scope, Scopes) of
                true -> {ok, principal_for(Token)};
                false -> {error, forbidden}
            end;
        error ->
            {error, unauthorized}
    end.
```

Pass `{my_auth, Config}` as the server's `auth` option and every API
request is checked through it (GET/HEAD need `read`, everything else
`write`).

## Swap the storage backends

Both storage layers are behaviours, so you can replace them:

- `xet_blob_store` — where serialized xorbs live. Ships with `xet_store_fs`
  (local disk) and `xet_store_s3` (livery_s3). Configure via the server's
  `blob` option: `{fs, Opts}` or `{s3, Opts}`.
- `xet_metadata` — files, xorb layouts, the dedup index, the key ring.
  Ships with `xet_metadata_rocksdb`.

Implement the behaviour's callbacks to point at your own storage, then name
your module in the server config.
