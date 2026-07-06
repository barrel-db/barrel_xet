%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(xet_server_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    healthz/1,
    unauthorized_without_token/1,
    forbidden_with_read_scope_on_write/1,
    authorized_unknown_route_is_404/1,
    request_id_header/1,
    ratelimit/1,
    restart_survives_caller/1,
    h2_tls_listener/1,
    invalid_config/1,
    auth_file_reload/1,
    tls_misconfig/1,
    h3_listener/1,
    h2_cert_rotation/1,
    security_headers/1
]).

all() ->
    [
        healthz,
        unauthorized_without_token,
        forbidden_with_read_scope_on_write,
        authorized_unknown_route_is_404,
        request_id_header,
        ratelimit,
        restart_survives_caller,
        h2_tls_listener,
        invalid_config,
        auth_file_reload,
        tls_misconfig,
        h3_listener,
        h2_cert_rotation,
        security_headers
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

%% Baseline hardening headers decorate every response by default; HSTS
%% stays off on cleartext (meaningless there, livery skips it).
security_headers(Config) ->
    {200, Headers, _} = get_(base(Config) ++ "/healthz", []),
    ?assertEqual(<<"nosniff">>, proplists:get_value(<<"x-content-type-options">>, Headers)),
    ?assertEqual(<<"DENY">>, proplists:get_value(<<"x-frame-options">>, Headers)),
    ?assertEqual(<<"no-referrer">>, proplists:get_value(<<"referrer-policy">>, Headers)),
    ?assertEqual(undefined, proplists:get_value(<<"strict-transport-security">>, Headers)).

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
