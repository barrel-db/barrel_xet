%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(xet_routes_tests).

-include_lib("eunit/include/eunit.hrl").

router(Config) ->
    xet_routes:compile(maps:merge(#{request_timeout => 12345}, Config)).

meta(Method, Path, Router) ->
    {ok, _Handler, _Bindings, Meta} = livery_router:match(Method, Path, Router),
    Meta.

deadline_of(Meta) ->
    #{middleware := [{livery_timeout, #{after_ms := Ms}}]} = Meta,
    Ms.

get_and_head_routes_carry_deadline_test() ->
    R = router(#{}),
    Hash = binary:copy(<<"ab">>, 32),
    ?assertEqual(12345, deadline_of(meta(<<"GET">>, <<"/healthz">>, R))),
    ?assertEqual(
        12345,
        deadline_of(meta(<<"GET">>, <<"/api/v1/reconstructions/", Hash/binary>>, R))
    ),
    ?assertEqual(12345, deadline_of(meta(<<"HEAD">>, <<"/v1/files/", Hash/binary>>, R))),
    ?assertEqual(
        12345,
        deadline_of(meta(<<"GET">>, <<"/v1/xorbs/default/", Hash/binary, "/data">>, R))
    ).

upload_routes_have_no_deadline_test() ->
    %% Streaming request bodies are incompatible with the timeout
    %% worker; upload routes must carry no per-route middleware.
    R = router(#{}),
    Hash = binary:copy(<<"ab">>, 32),
    ?assertEqual(undefined, meta(<<"POST">>, <<"/shards">>, R)),
    ?assertEqual(undefined, meta(<<"POST">>, <<"/api/v1/shards">>, R)),
    ?assertEqual(
        undefined, meta(<<"POST">>, <<"/api/v1/xorbs/default/", Hash/binary>>, R)
    ).

disabled_timeout_test() ->
    R = router(#{request_timeout => false}),
    ?assertEqual(undefined, meta(<<"GET">>, <<"/healthz">>, R)).
