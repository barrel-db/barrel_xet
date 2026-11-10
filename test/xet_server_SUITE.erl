%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(xet_server_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
%% Exported so it can serve as a logger handler in access_log_session_id.
-export([log/2]).
-export([
    healthz/1,
    empty_responses_keep_connection/1,
    unauthorized_without_token/1,
    forbidden_with_read_scope_on_write/1,
    authorized_unknown_route_is_404/1,
    request_id_header/1,
    ratelimit/1,
    restart_survives_caller/1,
    h2_tls_listener/1,
    https_signed_urls/1,
    invalid_config/1,
    auth_file_reload/1,
    tls_misconfig/1,
    h3_listener/1,
    h2_cert_rotation/1,
    security_headers/1,
    metrics_endpoint/1,
    access_log_session_id/1,
    storage_error_logged/1,
    readyz/1,
    admin_stats/1,
    spool_startup_sweep/1,
    reconstruction_missing_xorb/1,
    admin_backup/1,
    admin_backups_incremental/1,
    graceful_drain/1
]).

all() ->
    [
        healthz,
        empty_responses_keep_connection,
        unauthorized_without_token,
        forbidden_with_read_scope_on_write,
        authorized_unknown_route_is_404,
        request_id_header,
        ratelimit,
        restart_survives_caller,
        h2_tls_listener,
        https_signed_urls,
        invalid_config,
        auth_file_reload,
        tls_misconfig,
        h3_listener,
        h2_cert_rotation,
        security_headers,
        metrics_endpoint,
        access_log_session_id,
        storage_error_logged,
        readyz,
        admin_stats,
        spool_startup_sweep,
        reconstruction_missing_xorb,
        admin_backup,
        admin_backups_incremental,
        graceful_drain
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started([barrel_xet, hackney]),
    DataDir = filename:join(proplists:get_value(priv_dir, Config), "srv"),
    {ok, _Pid} = xet_server:start(#{
        name => xet_test_server,
        data_dir => DataDir,
        auth =>
            {xet_auth_static, #{
                tokens => #{<<"write-token">> => write, <<"read-token">> => read}
            }}
    }),
    [{base, base_url(xet_test_server)} | Config].

end_per_suite(_Config) ->
    ok = xet_server:stop(xet_test_server),
    ok.

base_url(Name) ->
    "http://127.0.0.1:" ++ integer_to_list(xet_server:port(Name)).

base(Config) -> proplists:get_value(base, Config).

get_(Url, Headers) ->
    {ok, Status, RespHeaders, Body} = hackney:request(get, Url, Headers, <<>>, [with_body]),
    {Status, RespHeaders, Body}.

healthz(Config) ->
    {Status, _, Body} = get_(base(Config) ++ "/healthz", []),
    ?assertEqual(200, Status),
    ?assertEqual(#{<<"status">> => <<"ok">>}, json:decode(Body)).

%% An empty response (here a HEAD 404) leaves nothing on the connection:
%% the next response on the same keep-alive connection parses. A chunked
%% terminator after a bodyless response would be read as the start of it.
empty_responses_keep_connection(_Config) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", xet_server:port(xet_test_server), [
        binary, {active, false}, {packet, http_bin}
    ]),
    Missing = binary:copy(<<"ab">>, 32),
    ok = gen_tcp:send(Sock, [
        <<"HEAD /api/v1/xorbs/default/">>,
        Missing,
        <<" HTTP/1.1\r\nHost: x\r\n">>,
        <<"Authorization: Bearer read-token\r\n\r\n">>,
        <<"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n">>
    ]),
    {Status1, Headers1} = read_head(Sock),
    ?assertEqual(404, Status1),
    ?assertEqual(<<"0">>, proplists:get_value('Content-Length', Headers1)),
    ?assertEqual(undefined, proplists:get_value('Transfer-Encoding', Headers1)),
    %% No body for HEAD: the next bytes are the healthz status line.
    {Status2, _} = read_head(Sock),
    ?assertEqual(200, Status2),
    ok = gen_tcp:close(Sock).

read_head(Sock) ->
    {ok, {http_response, _, Status, _}} = gen_tcp:recv(Sock, 0, 5000),
    {Status, read_headers(Sock, [])}.

read_headers(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, {http_header, _, Name, _, Value}} -> read_headers(Sock, [{Name, Value} | Acc]);
        {ok, http_eoh} -> Acc
    end.

unauthorized_without_token(Config) ->
    {Status, _, _} = get_(base(Config) ++ "/api/v1/reconstructions/abc", []),
    ?assertEqual(401, Status),
    {Status2, _, _} = get_(base(Config) ++ "/api/v1/reconstructions/abc", [
        {<<"authorization">>, <<"Bearer wrong">>}
    ]),
    ?assertEqual(401, Status2).

forbidden_with_read_scope_on_write(Config) ->
    {ok, Status, _, _} = hackney:request(
        post,
        base(Config) ++ "/api/v1/shards",
        [{<<"authorization">>, <<"Bearer read-token">>}],
        <<"x">>,
        [with_body]
    ),
    ?assertEqual(403, Status).

authorized_unknown_route_is_404(Config) ->
    {Status, _, _} = get_(base(Config) ++ "/api/v1/nothing/here", [
        {<<"authorization">>, <<"Bearer read-token">>}
    ]),
    ?assertEqual(404, Status).

request_id_header(Config) ->
    {200, Headers, _} = get_(base(Config) ++ "/healthz", []),
    ?assertNotEqual(undefined, proplists:get_value(<<"x-request-id">>, Headers)).

ratelimit(Config) ->
    DataDir = filename:join(proplists:get_value(priv_dir, Config), "ratelimited"),
    {ok, _} = xet_server:start(#{
        name => xet_rl_server,
        data_dir => DataDir,
        ratelimit => #{capacity => 2, per_second => 0.001},
        auth => {xet_auth_static, #{tokens => #{<<"t">> => write}}}
    }),
    try
        Base = base_url(xet_rl_server),
        %% The limiter keys on the bearer token; keyless requests pass.
        Headers = [{<<"authorization">>, <<"Bearer t">>}],
        Statuses = [element(1, get_(Base ++ "/healthz", Headers)) || _ <- lists:seq(1, 5)],
        ?assertEqual(200, hd(Statuses)),
        ?assert(lists:member(429, Statuses)),
        {NoKey, _, _} = get_(Base ++ "/healthz", []),
        ?assertEqual(200, NoKey)
    after
        ok = xet_server:stop(xet_rl_server)
    end.

%% A reconstruction answered on the https listener hands out https data
%% URLs, the cleartext one http (spec 14.2: no token-bearing http hops).
https_signed_urls(Config) ->
    case os:find_executable("openssl") of
        false -> {skip, "openssl not available for self-signed cert"};
        _ -> https_signed_urls_run(filename:join(proplists:get_value(priv_dir, Config), "urls"))
    end.

https_signed_urls_run(Dir) ->
    {Cert, Key} = gen_cert(Dir, "localhost"),
    {ok, _} = xet_server:start(#{
        name => xet_urls_server,
        data_dir => filename:join(Dir, "data"),
        https => #{port => 0, cert => Cert, key => Key},
        auth => {xet_auth_static, #{tokens => #{<<"t">> => write}}}
    }),
    try
        Client = xet_client:new(#{
            endpoint => list_to_binary(base_url(xet_urls_server)), token => <<"t">>
        }),
        {ok, #{file_hash := Hash}} = xet_client_upload:upload_data(
            Client, f, <<"signed url scheme">>
        ),
        Path = "/api/v1/reconstructions/" ++ binary_to_list(xet_hash:to_string(Hash)),
        TlsBase =
            "https://127.0.0.1:" ++
                integer_to_list(maps:get(h2, xet_server:ports(xet_urls_server))),
        ?assertMatch(
            <<"https://", _/binary>>,
            first_fetch_url(TlsBase ++ Path, [insecure])
        ),
        ?assertMatch(
            <<"http://", _/binary>>, first_fetch_url(base_url(xet_urls_server) ++ Path, [])
        )
    after
        ok = xet_server:stop(xet_urls_server)
    end.

first_fetch_url(Url, Opts) ->
    {ok, 200, _, Body} = hackney:request(
        get, Url, [{<<"authorization">>, <<"Bearer t">>}], <<>>, [with_body | Opts]
    ),
    [[#{<<"url">> := FetchUrl} | _] | _] = maps:values(
        maps:get(<<"fetch_info">>, json:decode(Body))
    ),
    FetchUrl.

%% One instance can serve H1 and H2 (TLS/ALPN) together from a shared
%% router; H3 rides the same path via livery once certs are configured.
h2_tls_listener(Config) ->
    case os:find_executable("openssl") of
        false ->
            {skip, "openssl not available for self-signed cert"};
        _ ->
            Dir = filename:join(proplists:get_value(priv_dir, Config), "tls"),
            ok = filelib:ensure_path(Dir),
            Cert = filename:join(Dir, "cert.pem"),
            Key = filename:join(Dir, "key.pem"),
            _ = os:cmd(
                "openssl req -x509 -newkey rsa:2048 -nodes -keyout " ++ Key ++
                    " -out " ++ Cert ++ " -days 2 -subj /CN=localhost 2>/dev/null"
            ),
            {ok, _} = xet_server:start(#{
                name => xet_tls_server,
                data_dir => filename:join(Dir, "data"),
                https => #{port => 0, cert => Cert, key => Key},
                auth => {xet_auth_static, #{tokens => #{}}}
            }),
            try
                Ports = xet_server:ports(xet_tls_server),
                ?assert(is_map_key(h2, Ports)),
                {ok, Sock} = ssl:connect(
                    "127.0.0.1",
                    maps:get(h2, Ports),
                    [
                        {alpn_advertised_protocols, [<<"h2">>]},
                        {verify, verify_none},
                        binary
                    ],
                    5000
                ),
                ?assertEqual({ok, <<"h2">>}, ssl:negotiated_protocol(Sock)),
                ok = ssl:close(Sock),
                %% The default cleartext listener still serves alongside.
                {Status, _, _} = get_(base_url(xet_tls_server) ++ "/healthz", []),
                ?assertEqual(200, Status)
            after
                ok = xet_server:stop(xet_tls_server)
            end
    end.

%% A bad config is a listed error, not a boot crash: every problem is
%% reported at once so an operator fixes the file in one pass.
invalid_config(Config) ->
    {error, {invalid_config, Errors}} = xet_server:start(#{name => xet_bad_config}),
    ?assert(lists:member(<<"data_dir is required">>, Errors)),
    ?assert(lists:member(<<"auth is required">>, Errors)),
    DataDir = filename:join(proplists:get_value(priv_dir, Config), "badcfg"),
    {error, {invalid_config, Errors2}} = xet_server:start(#{
        name => xet_bad_config,
        data_dir => DataDir,
        auth => {xet_auth_static, #{tokens => #{<<>> => write}}}
    }),
    ?assertEqual([<<"auth tokens must not be empty">>], Errors2).

%% TLS misconfiguration is a listed boot error naming the offending
%% file, not a listener that dies at the first handshake.
tls_misconfig(Config) ->
    Dir = filename:join(proplists:get_value(priv_dir, Config), "tlsbad"),
    Auth = {xet_auth_static, #{tokens => #{}}},
    {error, {invalid_config, E1}} = xet_server:start(#{
        name => xet_tls_bad,
        data_dir => Dir,
        auth => Auth,
        https => #{port => 0, cert => "/nope/c.pem", key => "/nope/k.pem"}
    }),
    ?assert(lists:any(fun(E) -> binary:match(E, <<"/nope/c.pem">>) =/= nomatch end, E1)),
    ?assert(lists:any(fun(E) -> binary:match(E, <<"/nope/k.pem">>) =/= nomatch end, E1)),
    {error, {invalid_config, E2}} = xet_server:start(#{
        name => xet_tls_bad,
        data_dir => Dir,
        auth => Auth,
        https => #{port => 0, cert => "somewhere.pem"}
    }),
    ?assert(lists:member(<<"https listener needs cert and key (PEM file paths)">>, E2)).

%% The QUIC listener boots from the same PEM file paths as https: the
%% config loader turns them into the DER cert and decoded key record.
h3_listener(Config) ->
    case os:find_executable("openssl") of
        false ->
            {skip, "openssl not available for self-signed cert"};
        _ ->
            Dir = filename:join(proplists:get_value(priv_dir, Config), "h3"),
            {Cert, Key} = gen_cert(Dir, "h3"),
            {ok, _} = xet_server:start(#{
                name => xet_h3_server,
                data_dir => filename:join(Dir, "data"),
                http3 => #{port => 0, cert => Cert, key => Key},
                auth => {xet_auth_static, #{tokens => #{}}}
            }),
            try
                Ports = xet_server:ports(xet_h3_server),
                ?assert(is_map_key(h3, Ports)),
                %% The default cleartext listener still serves alongside.
                {Status, _, _} = get_(base_url(xet_h3_server) ++ "/healthz", []),
                ?assertEqual(200, Status)
            after
                ok = xet_server:stop(xet_h3_server)
            end
    end.

%% h1/h2 read certfile/keyfile through the OTP PEM cache: replacing the
%% files and clearing the cache serves the new certificate on new
%% handshakes without a restart. (http3 captures the DER at boot and
%% needs one.)
h2_cert_rotation(Config) ->
    case os:find_executable("openssl") of
        false ->
            {skip, "openssl not available for self-signed cert"};
        _ ->
            Dir = filename:join(proplists:get_value(priv_dir, Config), "rotate"),
            {CertA, KeyA} = gen_cert(Dir, "aa"),
            {CertB, KeyB} = gen_cert(Dir, "bb"),
            Cert = filename:join(Dir, "cert.pem"),
            Key = filename:join(Dir, "key.pem"),
            {ok, _} = file:copy(CertA, Cert),
            {ok, _} = file:copy(KeyA, Key),
            {ok, _} = xet_server:start(#{
                name => xet_rotate_server,
                data_dir => filename:join(Dir, "data"),
                https => #{port => 0, cert => Cert, key => Key},
                auth => {xet_auth_static, #{tokens => #{}}}
            }),
            try
                Port = maps:get(h2, xet_server:ports(xet_rotate_server)),
                Der1 = peer_der(Port),
                {ok, _} = file:copy(CertB, Cert),
                {ok, _} = file:copy(KeyB, Key),
                ok = ssl:clear_pem_cache(),
                Der2 = peer_der(Port),
                ?assertNotEqual(Der1, Der2)
            after
                ok = xet_server:stop(xet_rotate_server)
            end
    end.

%% Every request emits one structured access-log report carrying its
%% request id, and the client's X-Xet-Session-Id rides the log event's
%% process metadata (proving the middleware and access log run in the
%% same process).
log(Event, #{config := #{pid := Pid}}) ->
    Pid ! {access_event, Event},
    ok.

access_log_session_id(Config) ->
    ok = logger:add_handler(xet_capture, ?MODULE, #{
        level => notice,
        config => #{pid => self()},
        formatter => {logger_formatter, #{}}
    }),
    try
        SessionId = <<"sess-abc-123">>,
        {200, _, _} = get_(base(Config) ++ "/healthz", [
            {<<"x-xet-session-id">>, SessionId}
        ]),
        {Report, Meta} = recv_access_event(5000),
        ?assertEqual("livery_access", maps:get(msg, Report)),
        ?assertNotEqual(undefined, maps:get(request_id, Report, undefined)),
        ?assertEqual(<<"/healthz">>, maps:get(path, Report)),
        ?assertEqual(SessionId, maps:get(session_id, Meta, undefined))
    after
        logger:remove_handler(xet_capture)
    end.

recv_access_event(Timeout) ->
    receive
        {access_event, #{msg := {report, #{msg := "livery_access"} = Report}, meta := Meta}} ->
            {Report, Meta};
        {access_event, _Other} ->
            recv_access_event(Timeout)
    after Timeout ->
        error(no_access_event)
    end.

%% A file whose term references a xorb the metadata does not have (a
%% data inconsistency) answers 500 and logs, without crashing the
%% request process. Registering the file directly skips the shard
%% handler's existence check, producing the inconsistency.
reconstruction_missing_xorb(Config) ->
    Metadata = maps:get(metadata, xet_server:env(xet_test_server)),
    FileHash = <<77:256>>,
    Term = #{cas_hash => <<99:256>>, unpacked_len => 100, chunk_start => 0, chunk_end => 1},
    ok = xet_metadata:register_files(
        Metadata,
        [#{file_hash => FileHash, total_len => 100, terms => [Term]}],
        []
    ),
    ok = logger:add_handler(xet_capture, ?MODULE, #{
        level => error,
        config => #{pid => self()},
        formatter => {logger_formatter, #{single_line => true}}
    }),
    try
        Path = "/api/v1/reconstructions/" ++ binary_to_list(xet_hash:to_string(FileHash)),
        {Status, _, Body} = get_(base(Config) ++ Path, [
            {<<"authorization">>, <<"Bearer read-token">>}
        ]),
        ?assertEqual(500, Status),
        ?assertEqual(#{<<"error">> => <<"inconsistent_metadata">>}, json:decode(Body)),
        ok = recv_log_matching(<<"missing xorb">>, 5000),
        %% The server survives: a normal request still works.
        {200, _, _} = get_(base(Config) ++ "/healthz", [])
    after
        logger:remove_handler(xet_capture)
    end.

%% Boot reclaims orphaned upload.*.tmp spool files left by a crash,
%% while leaving unrelated files alone.
spool_startup_sweep(Config) ->
    Dir = filename:join(proplists:get_value(priv_dir, Config), "spoolsweep"),
    Spool = filename:join(Dir, "spool"),
    ok = filelib:ensure_path(Spool),
    Stale = filename:join(Spool, "upload.999.tmp"),
    Keep = filename:join(Spool, "keep.txt"),
    ok = file:write_file(Stale, <<"orphan">>),
    ok = file:write_file(Keep, <<"keep">>),
    {ok, _} = xet_server:start(#{
        name => xet_spoolsweep_server,
        data_dir => Dir,
        auth => {xet_auth_static, #{tokens => #{}}}
    }),
    try
        ?assertNot(filelib:is_regular(Stale)),
        ?assert(filelib:is_regular(Keep))
    after
        ok = xet_server:stop(xet_spoolsweep_server)
    end.

%% Stopping the server mid-upload drains: a request in flight when
%% xet_server:stop/1 is called still completes with 200, and the port is
%% refused once stop returns.
graceful_drain(Config) ->
    Dir = filename:join(proplists:get_value(priv_dir, Config), "drain"),
    {ok, _} = xet_server:start(#{
        name => xet_drain_server,
        data_dir => Dir,
        drain_timeout => 15000,
        auth => {xet_auth_static, #{tokens => #{<<"w">> => write}}}
    }),
    Port = xet_server:port(xet_drain_server),
    {ok, Enc} = xet_xorb:encode(
        [xet_test_vectors:splitmix64_data(5000, 1)], #{nonce => <<0, 0, 0, 0>>}
    ),
    Bin = maps:get(bin, Enc),
    Url =
        "http://127.0.0.1:" ++ integer_to_list(Port) ++
            "/api/v1/xorbs/default/" ++ binary_to_list(xet_hash:to_string(maps:get(hash, Enc))),
    Parent = self(),
    _ = spawn(fun() ->
        {ok, Ref} = hackney:request(
            post, Url, [{<<"authorization">>, <<"Bearer w">>}], stream, [{pool, false}]
        ),
        trickle(Ref, Bin, 4),
        ok = hackney:finish_send_body(Ref),
        {ok, Status, _, Ref2} = hackney:start_response(Ref),
        {ok, _} = hackney:body(Ref2),
        Parent ! {upload, Status}
    end),
    %% Let the upload begin, then stop mid-body.
    timer:sleep(300),
    ok = xet_server:stop(xet_drain_server),
    receive
        {upload, S} -> ?assertEqual(200, S)
    after 15000 -> error(no_upload)
    end,
    %% Listener is down: the port refuses new connections.
    DownUrl = "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/healthz",
    ?assertMatch({error, _}, hackney:request(get, DownUrl, [], <<>>, [{pool, false}])).

trickle(Ref, Bin, N) when N =< 1 ->
    ok = hackney:send_body(Ref, Bin);
trickle(Ref, Bin, N) ->
    ChunkSize = max(1, byte_size(Bin) div N),
    <<Chunk:ChunkSize/binary, Rest/binary>> = Bin,
    ok = hackney:send_body(Ref, Chunk),
    timer:sleep(150),
    trickle(Ref, Rest, N - 1).

%% POST /admin/backup checkpoints the metadata store; 400 without a
%% backup_dir, 200 with one (and the checkpoint opens as a fresh DB).
admin_backup(Config) ->
    Dir = filename:join(proplists:get_value(priv_dir, Config), "backupsrv"),
    BackupDir = filename:join(Dir, "backups"),
    Auth = {xet_auth_static, #{tokens => #{<<"root">> => admin}}},
    {ok, _} = xet_server:start(#{
        name => xet_nobackup_server,
        data_dir => Dir,
        admin => #{enabled => true},
        auth => Auth
    }),
    NoBackupBase = base_url(xet_nobackup_server),
    ?assertEqual(400, backup_status(NoBackupBase)),
    ok = xet_server:stop(xet_nobackup_server),
    {ok, _} = xet_server:start(#{
        name => xet_backup_server,
        data_dir => filename:join(Dir, "with"),
        admin => #{enabled => true},
        backup_dir => BackupDir,
        auth => Auth
    }),
    try
        {ok, 200, _, Body} = hackney:request(
            post,
            base_url(xet_backup_server) ++ "/admin/backup?mode=checkpoint",
            [{<<"authorization">>, <<"Bearer root">>}],
            <<>>,
            [with_body, {pool, false}]
        ),
        Path = binary_to_list(maps:get(<<"path">>, json:decode(Body))),
        {ok, Copy} = xet_metadata:open(xet_metadata_rocksdb, #{dir => Path}),
        ok = xet_metadata:close(Copy)
    after
        ok = xet_server:stop(xet_backup_server)
    end.

%% Incremental backups: each POST adds one, the list is newest first, a
%% backup verifies, and unknown or malformed ids and non-admin tokens are
%% refused.
admin_backups_incremental(Config) ->
    Dir = filename:join(proplists:get_value(priv_dir, Config), "incrsrv"),
    {ok, _} = xet_server:start(#{
        name => xet_incr_server,
        data_dir => Dir,
        admin => #{enabled => true},
        backup_dir => filename:join(Dir, "backups"),
        auth => {xet_auth_static, #{tokens => #{<<"root">> => admin, <<"w">> => write}}}
    }),
    Base = base_url(xet_incr_server),
    try
        {200, First} = admin_req(Base, post, "/admin/backup", <<"root">>),
        ?assertMatch(#{<<"mode">> := <<"incremental">>, <<"id">> := _}, First),
        #{metadata := Meta} = xet_server:env(xet_incr_server),
        ok = xet_metadata:put_url_secret(Meta, crypto:strong_rand_bytes(32)),
        {200, #{<<"id">> := Second}} = admin_req(Base, post, "/admin/backup", <<"root">>),
        ?assert(Second > maps:get(<<"id">>, First)),
        {200, #{<<"backups">> := Backups}} = admin_req(Base, get, "/admin/backups", <<"root">>),
        ?assertEqual([Second, maps:get(<<"id">>, First)], [maps:get(<<"id">>, B) || B <- Backups]),
        Verify = "/admin/backups/" ++ integer_to_list(Second) ++ "/verify",
        ?assertMatch({200, #{<<"verified">> := true}}, admin_req(Base, post, Verify, <<"root">>)),
        ?assertMatch({404, _}, admin_req(Base, post, "/admin/backups/999/verify", <<"root">>)),
        ?assertMatch({400, _}, admin_req(Base, post, "/admin/backups/x/verify", <<"root">>)),
        ?assertMatch({403, _}, admin_req(Base, post, "/admin/backup", <<"w">>))
    after
        ok = xet_server:stop(xet_incr_server)
    end.

admin_req(Base, Method, Path, Token) ->
    {ok, Status, _, Body} = hackney:request(
        Method, Base ++ Path, [{<<"authorization">>, <<"Bearer ", Token/binary>>}], <<>>, [
            with_body
        ]
    ),
    {Status, json:decode(Body)}.

backup_status(Base) ->
    {ok, Status, _, _} = hackney:request(
        post, Base ++ "/admin/backup", [{<<"authorization">>, <<"Bearer root">>}], <<>>, [
            with_body, {pool, false}
        ]
    ),
    Status.

%% /admin/stats needs the admin scope and is mounted only when enabled:
%% read/write tokens are 403, no token 401, and a server without the
%% admin surface answers 404.
admin_stats(Config) ->
    Dir = filename:join(proplists:get_value(priv_dir, Config), "admin"),
    {ok, _} = xet_server:start(#{
        name => xet_admin_server,
        data_dir => Dir,
        admin => #{enabled => true},
        auth =>
            {xet_auth_static, #{
                tokens => #{<<"root">> => admin, <<"w">> => write, <<"r">> => read}
            }}
    }),
    Dir2 = filename:join(proplists:get_value(priv_dir, Config), "noadmin"),
    {ok, _} = xet_server:start(#{
        name => xet_noadmin_server,
        data_dir => Dir2,
        auth => {xet_auth_static, #{tokens => #{<<"root">> => admin}}}
    }),
    try
        Base = base_url(xet_admin_server),
        ?assertEqual(401, status(get_(Base ++ "/admin/stats", []))),
        ?assertEqual(403, status(get_(Base ++ "/admin/stats", bearer(<<"r">>)))),
        ?assertEqual(403, status(get_(Base ++ "/admin/stats", bearer(<<"w">>)))),
        {200, _, Body} = get_(Base ++ "/admin/stats", bearer(<<"root">>)),
        Meta = maps:get(<<"metadata">>, json:decode(Body)),
        ?assert(is_integer(maps:get(<<"xorbs">>, Meta))),
        %% Disabled elsewhere: the route does not exist even for admin.
        NoAdmin = base_url(xet_noadmin_server),
        ?assertEqual(404, status(get_(NoAdmin ++ "/admin/stats", bearer(<<"root">>))))
    after
        ok = xet_server:stop(xet_admin_server),
        ok = xet_server:stop(xet_noadmin_server)
    end.

status({S, _, _}) -> S.

bearer(Token) -> [{<<"authorization">>, <<"Bearer ", Token/binary>>}].

%% /readyz probes the stores: healthy after boot, 503 listing "blob"
%% when the blob root vanishes, and healthy again once it returns.
%% (/healthz stays a static liveness ping and is unaffected.)
readyz(Config) ->
    Dir = filename:join(proplists:get_value(priv_dir, Config), "readyz"),
    Xorbs = filename:join(Dir, "xorbs"),
    ok = filelib:ensure_path(Xorbs),
    {ok, _} = xet_server:start(#{
        name => xet_readyz_server,
        data_dir => Dir,
        auth => {xet_auth_static, #{tokens => #{}}}
    }),
    try
        Base = base_url(xet_readyz_server),
        %% Auth-exempt: no token needed (k8s probes cannot send one).
        {200, _, B1} = get_(Base ++ "/readyz", []),
        ?assertEqual(<<"ok">>, maps:get(<<"status">>, json:decode(B1))),
        Gone = Xorbs ++ ".gone",
        ok = file:rename(Xorbs, Gone),
        {503, _, B2} = get_(Base ++ "/readyz", []),
        Decoded = json:decode(B2),
        ?assertEqual(<<"unavailable">>, maps:get(<<"status">>, Decoded)),
        ?assert(lists:member(<<"blob">>, maps:get(<<"failed">>, Decoded))),
        %% Liveness is unaffected by a degraded store.
        {200, _, _} = get_(Base ++ "/healthz", []),
        ok = file:rename(Gone, Xorbs),
        {200, _, _} = get_(Base ++ "/readyz", [])
    after
        ok = xet_server:stop(xet_readyz_server)
    end.

%% A blob store write that fails answers 500 and logs the reason
%% (previously a silent storage_error). A read-only xorbs root makes the
%% put fail without touching the metadata store.
storage_error_logged(Config) ->
    Dir = filename:join(proplists:get_value(priv_dir, Config), "roblob"),
    Xorbs = filename:join(Dir, "xorbs"),
    ok = filelib:ensure_path(Xorbs),
    {ok, _} = xet_server:start(#{
        name => xet_roblob_server,
        data_dir => Dir,
        auth => {xet_auth_static, #{tokens => #{<<"w">> => write}}}
    }),
    ok = logger:add_handler(xet_capture, ?MODULE, #{
        level => error,
        config => #{pid => self()},
        formatter => {logger_formatter, #{single_line => true}}
    }),
    try
        ok = file:change_mode(Xorbs, 8#500),
        {ok, Enc} = xet_xorb:encode(
            [xet_test_vectors:splitmix64_data(2000, 5)], #{nonce => <<0, 0, 0, 0>>}
        ),
        Path =
            "/api/v1/xorbs/default/" ++ binary_to_list(xet_hash:to_string(maps:get(hash, Enc))),
        {ok, 500, _, Body} = hackney:request(
            post,
            base_url(xet_roblob_server) ++ Path,
            [{<<"authorization">>, <<"Bearer w">>}],
            maps:get(bin, Enc),
            [with_body, {pool, false}]
        ),
        ?assertEqual(#{<<"error">> => <<"storage_error">>}, json:decode(Body)),
        ok = recv_log_matching(<<"xorb commit failed">>, 5000)
    after
        _ = file:change_mode(Xorbs, 8#700),
        logger:remove_handler(xet_capture),
        ok = xet_server:stop(xet_roblob_server)
    end.

recv_log_matching(Substr, Timeout) ->
    receive
        {access_event, Event} ->
            Text = unicode:characters_to_binary(
                logger_formatter:format(Event, #{single_line => true, template => [msg]})
            ),
            case binary:match(Text, Substr) of
                nomatch -> recv_log_matching(Substr, Timeout);
                _ -> ok
            end
    after Timeout ->
        error({no_log_matching, Substr})
    end.

%% Baseline hardening headers decorate every response by default; HSTS
%% stays off on cleartext (meaningless there, livery skips it).
security_headers(Config) ->
    {200, Headers, _} = get_(base(Config) ++ "/healthz", []),
    ?assertEqual(<<"nosniff">>, proplists:get_value(<<"x-content-type-options">>, Headers)),
    ?assertEqual(<<"DENY">>, proplists:get_value(<<"x-frame-options">>, Headers)),
    ?assertEqual(<<"no-referrer">>, proplists:get_value(<<"referrer-policy">>, Headers)),
    ?assertEqual(undefined, proplists:get_value(<<"strict-transport-security">>, Headers)).

%% /metrics serves the instrument registry in Prometheus text format,
%% under the read scope (metrics leak paths and volumes). This also
%% pins the exposition name mangling of the HTTP duration histogram.
metrics_endpoint(Config) ->
    {S1, _, _} = get_(base(Config) ++ "/metrics", []),
    ?assertEqual(401, S1),
    %% A prior request guarantees the histogram exists before scraping.
    {200, _, _} = get_(base(Config) ++ "/healthz", []),
    Auth = [{<<"authorization">>, <<"Bearer read-token">>}],
    {200, Headers, Body} = get_(base(Config) ++ "/metrics", Auth),
    ?assertNotEqual(
        nomatch, binary:match(proplists:get_value(<<"content-type">>, Headers), <<"text/plain">>)
    ),
    %% instrument keeps OTel semantic-convention names verbatim (dots
    %% intact; Prometheus 3.x scrapes UTF-8 names).
    ?assertNotEqual(nomatch, binary:match(Body, <<"http_server_request_duration">>)),
    %% metrics => false removes the route entirely.
    Dir = filename:join(proplists:get_value(priv_dir, Config), "nometrics"),
    {ok, _} = xet_server:start(#{
        name => xet_nometrics_server,
        data_dir => Dir,
        metrics => false,
        auth => {xet_auth_static, #{tokens => #{<<"t">> => read}}}
    }),
    try
        {S2, _, _} = get_(
            base_url(xet_nometrics_server) ++ "/metrics",
            [{<<"authorization">>, <<"Bearer t">>}]
        ),
        ?assertEqual(404, S2)
    after
        ok = xet_server:stop(xet_nometrics_server)
    end.

gen_cert(Dir, Base) ->
    ok = filelib:ensure_path(Dir),
    Cert = filename:join(Dir, Base ++ "_cert.pem"),
    Key = filename:join(Dir, Base ++ "_key.pem"),
    _ = os:cmd(
        "openssl req -x509 -newkey rsa:2048 -nodes -keyout " ++ Key ++
            " -out " ++ Cert ++ " -days 2 -subj /CN=" ++ Base ++ " 2>/dev/null"
    ),
    {Cert, Key}.

peer_der(Port) ->
    {ok, Sock} = ssl:connect("127.0.0.1", Port, [{verify, verify_none}, binary], 5000),
    {ok, Der} = ssl:peercert(Sock),
    ok = ssl:close(Sock),
    Der.

%% Tokens live in a file: appending one and reloading grants access
%% without a restart, rewriting without it revokes the same way.
auth_file_reload(Config) ->
    Dir = filename:join(proplists:get_value(priv_dir, Config), "authfile"),
    ok = filelib:ensure_path(Dir),
    TokensFile = filename:join(Dir, "tokens"),
    ok = file:write_file(TokensFile, <<"boot-token write\n">>),
    {ok, _} = xet_server:start(#{
        name => xet_authfile_server,
        data_dir => filename:join(Dir, "data"),
        auth => {xet_auth_file, #{path => TokensFile}}
    }),
    try
        Base = base_url(xet_authfile_server),
        %% An authenticated read of an unknown file is 404; without a
        %% valid token the same request is 401.
        Probe = Base ++ "/api/v1/files/" ++ binary_to_list(binary:copy(<<"ab">>, 32)),
        ?assertEqual(404, probe(Probe, <<"boot-token">>)),
        ?assertEqual(401, probe(Probe, <<"second-token">>)),
        %% Grant: append + reload.
        ok = file:write_file(TokensFile, <<"boot-token write\nsecond-token read\n">>),
        ok = xet_auth_file:reload(),
        ?assertEqual(404, probe(Probe, <<"second-token">>)),
        %% Revoke: rewrite without the boot token + reload.
        ok = file:write_file(TokensFile, <<"second-token read\n">>),
        ok = xet_auth_file:reload(),
        ?assertEqual(401, probe(Probe, <<"boot-token">>)),
        ?assertEqual(404, probe(Probe, <<"second-token">>))
    after
        ok = xet_server:stop(xet_authfile_server)
    end.

probe(Url, Token) ->
    {ok, Status, _} = hackney:request(
        head, Url, [{<<"authorization">>, <<"Bearer ", Token/binary>>}], <<>>, [{pool, false}]
    ),
    Status.

%% The instance runs under the application supervisor, so the process
%% that called start/1 dying must not take the server down.
restart_survives_caller(Config) ->
    DataDir = filename:join(proplists:get_value(priv_dir, Config), "orphan"),
    Parent = self(),
    Pid = spawn(fun() ->
        {ok, _} = xet_server:start(#{
            name => xet_orphan_server,
            data_dir => DataDir,
            auth => {xet_auth_static, #{tokens => #{}}}
        }),
        Parent ! started
    end),
    receive
        started -> ok
    after 10000 -> error(timeout)
    end,
    false = is_process_alive(Pid),
    {Status, _, _} = get_(base_url(xet_orphan_server) ++ "/healthz", []),
    ?assertEqual(200, Status),
    ok = xet_server:stop(xet_orphan_server).
