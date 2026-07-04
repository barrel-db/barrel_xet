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
    h2_tls_listener/1
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
        h2_tls_listener
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
