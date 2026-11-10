%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(xet_metrics_tests).

-include_lib("eunit/include/eunit.hrl").

%% Best-effort contract: every op returns ok and never raises,
%% regardless of whether the instrument registry is running.
degrade_to_noop_test() ->
    ?assertEqual(ok, xet_metrics:count(<<"xet.test.counter">>, 1)),
    ?assertEqual(ok, xet_metrics:count(<<"xet.test.counter">>, 5, #{tag => <<"x">>})),
    ?assertEqual(ok, xet_metrics:observe(<<"xet.test.hist">>, 0.5, #{})),
    ?assertEqual(ok, xet_metrics:gauge(<<"xet.test.gauge">>, 42)).

records_into_registry_test() ->
    {ok, _} = application:ensure_all_started(instrument),
    ok = xet_metrics:count(<<"xet.test.recorded">>, 3),
    Body = iolist_to_binary(instrument_prometheus:format()),
    ?assertNotEqual(nomatch, binary:match(Body, <<"xet_test_recorded_total">>)).
