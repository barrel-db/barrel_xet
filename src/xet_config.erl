%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Server configuration: validation and defaults. load/1 turns a bad
%% config into listed, actionable errors instead of a boot-time crash.
%% Empty TLS cert/key or url_secret values (unset ${VAR} substitutions
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
    blob,
    concurrency,
    data_dir,
    data_ratelimit,
    external_url,
    host,
    http,
    http3,
    https,
    key_rotation_interval,
    max_body,
    max_shard_bytes,
    max_xorb_bytes,
    metrics,
    min_free_bytes,
    name,
    namespaces,
    observability,
    ratelimit,
    request_timeout,
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
    case TlsErrors ++ validate(Config) of
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
    lists:foldl(fun drop_empty/2, Config, [https, http3, url_secret]).

drop_empty(url_secret, Config) ->
    case maps:get(url_secret, Config, undefined) of
        Empty when Empty =:= <<>>; Empty =:= "" -> maps:remove(url_secret, Config);
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

validate(Config) ->
    lists:flatmap(fun(Check) -> Check(Config) end, [
        fun check_data_dir/1,
        fun check_auth/1,
        fun check_listeners/1,
        fun check_sizes/1,
        fun check_ratelimit/1,
        fun check_concurrency/1,
        fun check_request_timeout/1,
        fun check_security_headers/1,
        fun check_blob/1,
        fun check_admin/1,
        fun check_misc/1
    ]).

check_data_dir(#{data_dir := Dir}) when is_list(Dir), Dir =/= [] -> [];
check_data_dir(#{data_dir := Dir}) when is_binary(Dir), Dir =/= <<>> -> [];
check_data_dir(#{data_dir := _}) -> [<<"data_dir must be a non-empty path">>];
check_data_dir(_Config) -> [<<"data_dir is required">>].

check_auth(#{auth := {Mod, Opts}}) when is_atom(Mod) ->
    case verify_exported(Mod) of
        true -> check_auth_opts(Mod, Opts);
        false -> [format("auth module ~ts does not export verify/3", [Mod])]
    end;
check_auth(#{auth := _}) ->
    [<<"auth must be {Module, Opts}">>];
check_auth(_Config) ->
    [<<"auth is required">>].

verify_exported(Mod) ->
    case code:ensure_loaded(Mod) of
        {module, Mod} -> erlang:function_exported(Mod, verify, 3);
        _ -> false
    end.

check_auth_opts(xet_auth_static, #{tokens := Tokens}) when is_map(Tokens) ->
    lists:flatmap(fun check_token/1, maps:to_list(Tokens));
check_auth_opts(xet_auth_static, _Opts) ->
    [<<"xet_auth_static needs #{tokens => #{Token => read | write | admin}}">>];
%% Fail closed at boot: an unreadable or unparsable tokens file is a
%% config error, not a server that rejects everyone at runtime. Loading
%% here also publishes the token set, so the first request never pays
%% for it.
check_auth_opts(xet_auth_file, #{path := Path}) when is_list(Path); is_binary(Path) ->
    case xet_auth_file:load(Path) of
        {ok, 0} ->
            logger:warning("xet_server config: tokens file ~ts has no tokens", [Path]),
            [];
        {ok, _Count} ->
            [];
        {error, Reasons} ->
            Reasons
    end;
check_auth_opts(xet_auth_file, _Opts) ->
    [<<"xet_auth_file needs #{path => TokensFile}">>];
check_auth_opts(_Mod, _Opts) ->
    [].

check_token({Token, Scope}) ->
    token_error(Token) ++ scope_error(Scope).

token_error(<<>>) -> [<<"auth tokens must not be empty">>];
token_error(Token) when is_binary(Token) -> [];
token_error(Token) -> [format("auth token ~tp must be a binary", [Token])].

scope_error(read) -> [];
scope_error(write) -> [];
scope_error(admin) -> [];
scope_error(Scope) -> [format("auth scope ~tp is not read | write | admin", [Scope])].

check_listeners(Config) ->
    lists:flatmap(
        fun(Proto) -> check_listener(Proto, maps:get(Proto, Config, undefined)) end,
        [http, https, http3]
    ).

check_listener(_Proto, undefined) -> [];
check_listener(http, false) -> [];
check_listener(Proto, Listener) when is_map(Listener) -> check_port(Proto, Listener);
check_listener(Proto, _Other) -> [format("~ts listener must be a map", [Proto])].

check_port(Proto, Listener) ->
    case maps:get(port, Listener, 0) of
        Port when is_integer(Port), Port >= 0, Port =< 65535 -> [];
        Port -> [format("~ts port ~tp is not 0..65535", [Proto, Port])]
    end.

check_sizes(Config) ->
    Positive = [max_body, max_xorb_bytes, max_shard_bytes, url_ttl, key_rotation_interval],
    NonNeg = [spool_memory_max, min_free_bytes],
    lists:flatmap(fun(Key) -> check_pos(Key, maps:get(Key, Config, undefined)) end, Positive) ++
        lists:flatmap(fun(Key) -> check_non_neg(Key, maps:get(Key, Config, undefined)) end, NonNeg).

check_pos(_Key, undefined) -> [];
check_pos(_Key, N) when is_integer(N), N > 0 -> [];
check_pos(Key, V) -> [format("~ts must be a positive integer, got ~tp", [Key, V])].

check_non_neg(_Key, undefined) -> [];
check_non_neg(_Key, N) when is_integer(N), N >= 0 -> [];
check_non_neg(Key, V) -> [format("~ts must be a non-negative integer, got ~tp", [Key, V])].

check_ratelimit(Config) ->
    check_bucket(ratelimit, maps:get(ratelimit, Config, undefined)) ++
        check_bucket(data_ratelimit, maps:get(data_ratelimit, Config, undefined)).

check_bucket(_Key, undefined) ->
    [];
check_bucket(_Key, false) ->
    [];
check_bucket(_Key, #{capacity := C, per_second := R}) when
    is_integer(C), C > 0, is_number(R), R > 0
->
    [];
check_bucket(Key, _V) ->
    [format("~ts must be false or #{capacity => N, per_second => Rate}", [Key])].

check_concurrency(#{concurrency := false}) ->
    [];
check_concurrency(#{concurrency := Max}) when is_integer(Max), Max > 0 -> [];
check_concurrency(#{concurrency := V}) ->
    [format("concurrency must be false or a positive integer, got ~tp", [V])];
check_concurrency(_Config) ->
    [].

check_request_timeout(#{request_timeout := false}) ->
    [];
check_request_timeout(#{request_timeout := Ms}) when is_integer(Ms), Ms > 0 ->
    [];
check_request_timeout(#{request_timeout := V}) ->
    [format("request_timeout must be false or milliseconds, got ~tp", [V])];
check_request_timeout(_Config) ->
    [].

check_security_headers(#{security_headers := false}) ->
    [];
check_security_headers(#{security_headers := Opts}) when is_map(Opts) ->
    [];
check_security_headers(#{security_headers := V}) ->
    [format("security_headers must be false or an options map, got ~tp", [V])];
check_security_headers(_Config) ->
    [].

check_blob(#{blob := {fs, #{dir := Dir}}}) when is_list(Dir); is_binary(Dir) -> [];
check_blob(#{blob := {s3, Opts}}) when is_map(Opts) -> [];
check_blob(#{blob := _}) -> [<<"blob must be {fs, #{dir => Path}} or {s3, Opts}">>];
check_blob(_Config) -> [].

check_admin(#{admin := false}) -> [];
check_admin(#{admin := #{enabled := E}}) when is_boolean(E) -> [];
check_admin(#{admin := #{} = M}) when map_size(M) =:= 0 -> [];
check_admin(#{admin := _}) -> [<<"admin must be false or #{enabled => boolean()}">>];
check_admin(_Config) -> [].

check_misc(Config) ->
    check_name(maps:get(name, Config, undefined)) ++
        check_secret(maps:get(url_secret, Config, undefined)) ++
        check_namespaces(maps:get(namespaces, Config, undefined)) ++
        check_flag(observability, maps:get(observability, Config, undefined)) ++
        check_flag(metrics, maps:get(metrics, Config, undefined)) ++
        check_flag(access_log, maps:get(access_log, Config, undefined)).

check_name(undefined) -> [];
check_name(Name) when is_atom(Name) -> [];
check_name(V) -> [format("name must be an atom, got ~tp", [V])].

check_secret(undefined) -> [];
check_secret(Secret) when is_binary(Secret) -> [];
check_secret(_V) -> [<<"url_secret must be a binary">>].

check_namespaces(undefined) ->
    [];
check_namespaces(Namespaces) when is_list(Namespaces), Namespaces =/= [] ->
    case lists:all(fun(Ns) -> is_binary(Ns) andalso Ns =/= <<>> end, Namespaces) of
        true -> [];
        false -> [<<"namespaces must be non-empty binaries">>]
    end;
check_namespaces(_V) ->
    [<<"namespaces must be a non-empty list of binaries">>].

check_flag(_Key, undefined) -> [];
check_flag(_Key, Flag) when is_boolean(Flag) -> [];
check_flag(Key, V) -> [format("~ts must be a boolean, got ~tp", [Key, V])].

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
        %% Serialized xorb cap: 64 MiB of chunk payload plus headers and
        %% footer headroom.
        max_xorb_bytes => 71303168,
        max_shard_bytes => 67108864,
        spool_memory_max => 16777216,
        %% Reject uploads (507) and fail readiness when free space on the
        %% data dir drops below this many bytes (default 1 GiB).
        min_free_bytes => 1073741824,
        url_ttl => 900,
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
        admin => #{enabled => false}
    },
    maps:merge(Defaults, Config).
