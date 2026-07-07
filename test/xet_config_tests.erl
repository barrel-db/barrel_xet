%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(xet_config_tests).

-include_lib("eunit/include/eunit.hrl").

-define(AUTH, {xet_auth_static, #{tokens => #{<<"t">> => write}}}).

valid(Extra) ->
    maps:merge(#{data_dir => "/tmp/xet", auth => ?AUTH}, Extra).

errors(Config) ->
    {error, {invalid_config, Errors}} = xet_config:load(Config),
    Errors.

minimal_defaults_test() ->
    {ok, Config} = xet_config:load(valid(#{})),
    ?assertEqual(xet_server, maps:get(name, Config)),
    ?assertEqual(#{port => 0}, maps:get(http, Config)),
    ?assertEqual({fs, #{dir => "/tmp/xet/xorbs"}}, maps:get(blob, Config)),
    ?assertEqual(900, maps:get(url_ttl, Config)),
    ?assertEqual(false, maps:get(ratelimit, Config)),
    ?assertEqual(false, maps:get(concurrency, Config)),
    ?assertEqual(30000, maps:get(request_timeout, Config)),
    ?assertEqual(#{}, maps:get(security_headers, Config)),
    %% No default: absence lets the stores reuse the persisted secret.
    ?assertNot(maps:is_key(url_secret, Config)).

explicit_values_survive_test() ->
    {ok, Config} = xet_config:load(valid(#{url_ttl => 60, name => my_server})),
    ?assertEqual(60, maps:get(url_ttl, Config)),
    ?assertEqual(my_server, maps:get(name, Config)).

not_a_map_test() ->
    ?assertEqual(
        {error, {invalid_config, [<<"config must be a map">>]}},
        xet_config:load([])
    ).

missing_required_accumulates_test() ->
    Errors = errors(#{}),
    ?assert(lists:member(<<"data_dir is required">>, Errors)),
    ?assert(lists:member(<<"auth is required">>, Errors)).

bad_data_dir_test() ->
    ?assertEqual(
        [<<"data_dir must be a non-empty path">>], errors(#{data_dir => "", auth => ?AUTH})
    ).

auth_not_tuple_test() ->
    ?assertEqual(
        [<<"auth must be {Module, Opts}">>],
        errors(#{data_dir => "/tmp/xet", auth => bearer})
    ).

auth_module_without_verify_test() ->
    [Error] = errors(#{data_dir => "/tmp/xet", auth => {lists, #{}}}),
    ?assertEqual(<<"auth module lists does not export verify/3">>, Error).

empty_token_is_fatal_test() ->
    Auth = {xet_auth_static, #{tokens => #{<<>> => write}}},
    ?assertEqual(
        [<<"auth tokens must not be empty">>],
        errors(#{data_dir => "/tmp/xet", auth => Auth})
    ).

bad_scope_test() ->
    Auth = {xet_auth_static, #{tokens => #{<<"t">> => admin_all}}},
    [Error] = errors(#{data_dir => "/tmp/xet", auth => Auth}),
    ?assertEqual(<<"auth scope admin_all is not read | write | admin">>, Error).

admin_scope_is_valid_test() ->
    Auth = {xet_auth_static, #{tokens => #{<<"root">> => admin}}},
    {ok, _} = xet_config:load(#{data_dir => "/tmp/xet", auth => Auth}).

static_without_tokens_test() ->
    [Error] = errors(#{data_dir => "/tmp/xet", auth => {xet_auth_static, #{}}}),
    ?assertEqual(
        <<"xet_auth_static needs #{tokens => #{Token => read | write | admin}}">>, Error
    ).

auth_file_missing_is_fatal_test() ->
    Auth = {xet_auth_file, #{path => "/nonexistent/xet-tokens"}},
    [Error] = errors(#{data_dir => "/tmp/xet", auth => Auth}),
    ?assertNotEqual(nomatch, binary:match(Error, <<"enoent">>)).

auth_file_without_path_test() ->
    [Error] = errors(#{data_dir => "/tmp/xet", auth => {xet_auth_file, #{}}}),
    ?assertEqual(<<"xet_auth_file needs #{path => TokensFile}">>, Error).

bad_port_test() ->
    ?assertEqual(
        [<<"http port 70000 is not 0..65535">>],
        errors(valid(#{http => #{port => 70000}}))
    ),
    %% The bogus cert/key paths also error; the port error is listed too.
    Errors = errors(valid(#{https => #{port => -1, cert => "c.pem", key => "k.pem"}})),
    ?assert(lists:member(<<"https port -1 is not 0..65535">>, Errors)).

listener_not_a_map_test() ->
    ?assertEqual([<<"https listener must be a map">>], errors(valid(#{https => true}))).

http_false_disables_cleartext_test() ->
    {ok, Config} = xet_config:load(valid(#{http => false})),
    ?assertEqual(false, maps:get(http, Config)).

empty_tls_listener_dropped_test() ->
    {ok, Config} = xet_config:load(
        valid(#{https => #{port => 8443, cert => <<>>, key => <<"k.pem">>}})
    ),
    ?assertNot(maps:is_key(https, Config)),
    {ok, Config2} = xet_config:load(
        valid(#{http3 => #{port => 8443, cert => "c.pem", key => ""}})
    ),
    ?assertNot(maps:is_key(http3, Config2)).

empty_url_secret_dropped_test() ->
    %% An unset ${VAR} substitution behaves like an absent key.
    {ok, Config} = xet_config:load(valid(#{url_secret => <<>>})),
    ?assertNot(maps:is_key(url_secret, Config)).

bad_sizes_test() ->
    Errors = errors(valid(#{max_body => 0, url_ttl => -5, spool_memory_max => bad})),
    ?assertEqual(3, length(Errors)),
    ?assert(lists:member(<<"max_body must be a positive integer, got 0">>, Errors)).

spool_zero_is_valid_test() ->
    {ok, Config} = xet_config:load(valid(#{spool_memory_max => 0})),
    ?assertEqual(0, maps:get(spool_memory_max, Config)).

min_free_bytes_default_test() ->
    {ok, Config} = xet_config:load(valid(#{})),
    ?assertEqual(1073741824, maps:get(min_free_bytes, Config)),
    %% 0 disables the margin.
    {ok, C2} = xet_config:load(valid(#{min_free_bytes => 0})),
    ?assertEqual(0, maps:get(min_free_bytes, C2)).

bad_min_free_bytes_test() ->
    ?assertEqual(
        [<<"min_free_bytes must be a non-negative integer, got -1">>],
        errors(valid(#{min_free_bytes => -1}))
    ).

bad_ratelimit_test() ->
    ?assertEqual(
        [<<"ratelimit must be false or #{capacity => N, per_second => Rate}">>],
        errors(valid(#{ratelimit => #{capacity => 2}}))
    ).

good_ratelimit_test() ->
    {ok, _} = xet_config:load(valid(#{ratelimit => #{capacity => 2, per_second => 0.5}})).

bad_data_ratelimit_test() ->
    ?assertEqual(
        [<<"data_ratelimit must be false or #{capacity => N, per_second => Rate}">>],
        errors(valid(#{data_ratelimit => #{per_second => 1.0}}))
    ),
    {ok, Config} = xet_config:load(valid(#{})),
    ?assertEqual(false, maps:get(data_ratelimit, Config)).

bad_concurrency_test() ->
    ?assertEqual(
        [<<"concurrency must be false or a positive integer, got 0">>],
        errors(valid(#{concurrency => 0}))
    ).

bad_request_timeout_test() ->
    ?assertEqual(
        [<<"request_timeout must be false or milliseconds, got 0">>],
        errors(valid(#{request_timeout => 0}))
    ),
    {ok, _} = xet_config:load(valid(#{request_timeout => false})).

bad_security_headers_test() ->
    ?assertEqual(
        [<<"security_headers must be false or an options map, got on">>],
        errors(valid(#{security_headers => on}))
    ),
    {ok, _} = xet_config:load(valid(#{security_headers => false})).

access_log_defaults_on_test() ->
    {ok, Config} = xet_config:load(valid(#{})),
    ?assertEqual(true, maps:get(access_log, Config)).

bad_access_log_test() ->
    ?assertEqual(
        [<<"access_log must be a boolean, got yes">>],
        errors(valid(#{access_log => yes}))
    ).

admin_defaults_off_test() ->
    {ok, Config} = xet_config:load(valid(#{})),
    ?assertEqual(#{enabled => false}, maps:get(admin, Config)).

bad_admin_test() ->
    ?assertEqual(
        [<<"admin must be false or #{enabled => boolean()}">>],
        errors(valid(#{admin => on}))
    ),
    {ok, _} = xet_config:load(valid(#{admin => #{enabled => true}})),
    {ok, _} = xet_config:load(valid(#{admin => false})).

gc_and_scrub_defaults_test() ->
    {ok, Config} = xet_config:load(valid(#{})),
    ?assertEqual(#{grace_seconds => 86400, interval => false}, maps:get(gc, Config)),
    ?assertEqual(#{rate_bytes_per_sec => 33554432, interval => false}, maps:get(scrub, Config)).

bad_gc_test() ->
    ?assertEqual(
        [<<"gc grace_seconds must be a positive integer, got 0">>],
        errors(valid(#{gc => #{grace_seconds => 0}}))
    ),
    ?assertEqual(
        [<<"gc interval must be false or a positive integer, got -1">>],
        errors(valid(#{gc => #{interval => -1}}))
    ).

bad_scrub_test() ->
    ?assertEqual(
        [<<"scrub rate_bytes_per_sec must be a positive integer, got 0">>],
        errors(valid(#{scrub => #{rate_bytes_per_sec => 0}}))
    ),
    {ok, _} = xet_config:load(valid(#{scrub => #{interval => 3600}})).

bad_blob_test() ->
    ?assertEqual(
        [<<"blob must be {fs, #{dir => Path}} or {s3, Opts}">>],
        errors(valid(#{blob => {gcs, #{}}}))
    ).

bad_namespaces_test() ->
    ?assertEqual(
        [<<"namespaces must be a non-empty list of binaries">>],
        errors(valid(#{namespaces => []}))
    ),
    ?assertEqual(
        [<<"namespaces must be non-empty binaries">>],
        errors(valid(#{namespaces => [<<"ok">>, ""]}))
    ).

bad_observability_test() ->
    ?assertEqual(
        [<<"observability must be a boolean, got sometimes">>],
        errors(valid(#{observability => sometimes}))
    ).

unknown_keys_still_load_test() ->
    {ok, Config} = xet_config:load(valid(#{frobnicate => 1})),
    ?assertEqual(1, maps:get(frobnicate, Config)).

https_requires_cert_and_key_test() ->
    ?assertEqual(
        [<<"https listener needs cert and key (PEM file paths)">>],
        errors(valid(#{https => #{port => 8443, cert => "c.pem"}}))
    ).

tls_missing_files_test() ->
    Errors = errors(
        valid(#{https => #{port => 8443, cert => "/nope/c.pem", key => "/nope/k.pem"}})
    ),
    ?assertEqual(2, length(Errors)),
    ?assert(lists:all(fun(E) -> binary:match(E, <<"enoent">>) =/= nomatch end, Errors)).

tls_junk_pem_test() ->
    Path = filename:join(
        os:getenv("TMPDIR", "/tmp"),
        "xet_config_junk_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = file:write_file(Path, <<"not a pem at all">>),
    try
        Errors = errors(valid(#{http3 => #{port => 0, cert => Path, key => Path}})),
        ?assertEqual(2, length(Errors)),
        ?assert(lists:all(fun(E) -> binary:match(E, <<"not a PEM file">>) =/= nomatch end, Errors))
    after
        file:delete(Path)
    end.
