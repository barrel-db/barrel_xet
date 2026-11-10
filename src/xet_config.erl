%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Server configuration: loading and defaults. load/1 turns a bad
%% config into listed, actionable errors instead of a boot-time crash.
%% Empty TLS cert/key, url_secret or external_url values (unset ${VAR} substitutions
%% in a templated sys.config) are dropped so the blocks can always be
%% present; empty auth tokens are fatal instead, so a missing token
%% variable cannot silently authenticate nobody.
-module(xet_config).

-export([load/1]).

-define(DEFAULT_MAX_BODY, 83886080).

-define(KNOWN_KEYS, [
    access_log,
    admin,
    auth,
    backup_dir,
    backup_keep,
    blob,
    concurrency,
    data_dir,
    data_ratelimit,
    drain_timeout,
    external_url,
    gc,
    host,
    http,
    http3,
    https,
    key_rotation_interval,
    max_body,
    max_shard_bytes,
    max_xorb_bytes,
    metadata_opts,
    metrics,
    min_free_bytes,
    name,
    namespaces,
    observability,
    ratelimit,
    request_timeout,
    scrub,
    security_headers,
    spool_memory_max,
    url_secret,
    url_ttl
]).

-spec load(term()) -> {ok, map()} | {error, {invalid_config, [binary()]}}.
load(Config0) when is_map(Config0) ->
    warn_unknown(Config0),
    Config1 = drop_empty(Config0),
    {Config, TlsErrors} = prepare_tls(Config1),
    case TlsErrors ++ xet_config_check:validate(Config) of
        [] -> {ok, defaults(Config)};
        Errors -> {error, {invalid_config, Errors}}
    end;
load(_Other) ->
    {error, {invalid_config, [<<"config must be a map">>]}}.

%% Later tasks add knobs; a typo should surface loudly without failing
%% configs written against a newer version.
warn_unknown(Config) ->
    case maps:keys(Config) -- ?KNOWN_KEYS of
        [] -> ok;
        Unknown -> logger:warning("xet_server config: ignoring unknown keys ~p", [Unknown])
    end.

drop_empty(Config) ->
    lists:foldl(fun drop_empty/2, Config, [https, http3, url_secret, external_url]).

drop_empty(Key, Config) when Key =:= url_secret; Key =:= external_url ->
    case maps:get(Key, Config, undefined) of
        Empty when Empty =:= <<>>; Empty =:= "" -> maps:remove(Key, Config);
        _ -> Config
    end;
drop_empty(Proto, Config) ->
    case maps:get(Proto, Config, undefined) of
        Listener when is_map(Listener) ->
            Empty =
                empty_value(maps:get(cert, Listener, missing)) orelse
                    empty_value(maps:get(key, Listener, missing)),
            case Empty of
                true -> maps:remove(Proto, Config);
                false -> Config
            end;
        _ ->
            Config
    end.

empty_value(<<>>) -> true;
empty_value("") -> true;
empty_value(_) -> false.

%% h1/h2 (https) take cert/key as PEM file paths, which livery turns
%% into certfile/keyfile ssl options, so replacing the files and running
%% ssl:clear_pem_cache() serves the new certificate on new handshakes.
%% The QUIC listener (http3) instead wants the DER certificate and the
%% decoded key record, captured at boot: both are loaded from the same
%% PEM paths here, so operator config is uniform and a bad path or file
%% fails the boot naming the file instead of dying at the first
%% handshake. http3 certificate changes need a restart (or livery's
%% sni_callback for per-handshake selection).
prepare_tls(Config) ->
    lists:foldl(
        fun(Proto, {Cfg, Errors}) ->
            {Cfg1, New} = prepare_listener_tls(Proto, Cfg),
            {Cfg1, Errors ++ New}
        end,
        {Config, []},
        [https, http3]
    ).

prepare_listener_tls(Proto, Config) ->
    case maps:get(Proto, Config, undefined) of
        Listener when is_map(Listener) ->
            prepared(Proto, Listener, Config, tls_material(Proto, Listener));
        _ ->
            {Config, []}
    end.

prepared(_Proto, _Listener, Config, {error, Errors}) ->
    {Config, Errors};
prepared(https, _Listener, Config, {ok, _Certs, _Key}) ->
    %% Paths validated; livery gets them verbatim.
    {Config, []};
prepared(http3, Listener, Config, {ok, [Cert | Chain], Key}) ->
    Loaded = Listener#{cert := Cert, key := Key, cert_chain => Chain},
    {Config#{http3 := Loaded}, []}.

tls_material(Proto, Listener) ->
    case {maps:get(cert, Listener, undefined), maps:get(key, Listener, undefined)} of
        {Cert, Key} when Cert =/= undefined, Key =/= undefined ->
            read_tls(Proto, Cert, Key);
        _ ->
            {error, [format("~ts listener needs cert and key (PEM file paths)", [Proto])]}
    end.

read_tls(Proto, CertPath, KeyPath) ->
    case {pem_certs(Proto, CertPath), pem_key(Proto, KeyPath)} of
        {{ok, Certs}, {ok, Key}} -> {ok, Certs, Key};
        {CertRes, KeyRes} -> {error, errors_of(CertRes) ++ errors_of(KeyRes)}
    end.

errors_of({ok, _}) -> [];
errors_of({error, Errors}) -> Errors.

pem_certs(Proto, Path) ->
    case read_pem(Proto, <<"cert">>, Path) of
        {ok, Entries} ->
            case [Der || {'Certificate', Der, not_encrypted} <- Entries] of
                [] -> {error, [format("~ts cert ~ts: no certificate entry", [Proto, Path])]};
                Certs -> {ok, Certs}
            end;
        {error, _} = Error ->
            Error
    end.

pem_key(Proto, Path) ->
    case read_pem(Proto, <<"key">>, Path) of
        {ok, Entries} -> pick_key(Proto, Path, Entries);
        {error, _} = Error -> Error
    end.

pick_key(Proto, Path, Entries) ->
    Tags = ['RSAPrivateKey', 'ECPrivateKey', 'PrivateKeyInfo'],
    case [Entry || Entry <- Entries, lists:member(element(1, Entry), Tags)] of
        [{_Tag, _Der, not_encrypted} = Entry | _] ->
            {ok, public_key:pem_entry_decode(Entry)};
        [_Encrypted | _] ->
            {error, [format("~ts key ~ts: encrypted keys are not supported", [Proto, Path])]};
        [] ->
            {error, [format("~ts key ~ts: no private key entry", [Proto, Path])]}
    end.

read_pem(Proto, Kind, Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            case public_key:pem_decode(Bin) of
                [] -> {error, [format("~ts ~ts ~ts: not a PEM file", [Proto, Kind, Path])]};
                Entries -> {ok, Entries}
            end;
        {error, Reason} ->
            {error, [format("~ts ~ts ~ts: ~tp", [Proto, Kind, Path, Reason])]}
    end.

format(Fmt, Args) ->
    iolist_to_binary(io_lib:format(Fmt, Args)).

defaults(Config) ->
    DataDir = maps:get(data_dir, Config),
    Defaults = #{
        name => xet_server,
        http => #{port => 0},
        blob => {fs, #{dir => filename:join(DataDir, "xorbs")}},
        namespaces => [<<"default">>, <<"default-merkledb">>],
        max_body => ?DEFAULT_MAX_BODY,
        backup_keep => 7,
        %% Serialized xorb cap: 64 MiB of chunk payload plus headers and
        %% footer headroom.
        max_xorb_bytes => 71303168,
        max_shard_bytes => 67108864,
        spool_memory_max => 16777216,
        %% Reject uploads (507) and fail readiness when free space on the
        %% data dir drops below this many bytes (default 1 GiB).
        min_free_bytes => 1073741824,
        url_ttl => 900,
        %% Graceful shutdown: wait up to this long (ms) for in-flight
        %% requests to finish before stopping the listener.
        drain_timeout => 30000,
        %% url_secret has no default here: when absent,
        %% xet_server_stores reuses the secret persisted in metadata (or
        %% generates and persists one), so signed URLs survive restarts.
        key_rotation_interval => 86400,
        ratelimit => false,
        %% Off by default: per-signed-URL buckets on /data (see
        %% xet_routes) are amplification bounds, not IP flood
        %% protection, which belongs to the LB or proxy in front.
        data_ratelimit => false,
        concurrency => false,
        %% Deadline on GET/HEAD handlers only: upload routes stream
        %% their request bodies (incompatible with the timeout worker)
        %% and carry their own per-chunk inactivity bound; /data
        %% responses stream after the handler returns, so the deadline
        %% covers handler time, not transfer time.
        request_timeout => 30000,
        %% livery_security_headers defaults; HSTS emits only over TLS.
        security_headers => #{},
        %% The instrument registry is cheap and always on: HTTP metrics
        %% record locally, /metrics serves them under the read scope,
        %% and exporters stay opt-in (OTEL_* env vars).
        observability => true,
        metrics => true,
        %% One structured logger line per request.
        access_log => true,
        %% Non-spec admin endpoints (/admin/*) are off unless enabled.
        admin => #{enabled => false},
        %% Garbage collection: unreferenced xorbs older than the grace
        %% window are collectable. Manual-only by default (interval
        %% false); the first runs should be operator-watched.
        gc => #{grace_seconds => 86400, interval => false},
        %% Verify-at-rest: read every xorb and re-check its hash, capped
        %% at rate_bytes_per_sec. Manual-only by default.
        scrub => #{rate_bytes_per_sec => 33554432, interval => false}
    },
    maps:merge(Defaults, Config).
