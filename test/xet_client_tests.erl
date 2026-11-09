%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(xet_client_tests).

-include_lib("eunit/include/eunit.hrl").

%% Spec 14.2: bearer tokens over TLS only, loopback and explicit opt-in
%% excepted.
transport_test_() ->
    New = fun(Endpoint, Extra) ->
        xet_client:new(maps:merge(#{endpoint => Endpoint, token => <<"t">>}, Extra))
    end,
    [
        ?_assertMatch(#{}, New(<<"https://xet.example.com">>, #{})),
        ?_assertMatch(#{}, New(<<"http://127.0.0.1:8080">>, #{})),
        ?_assertMatch(#{}, New(<<"http://localhost:8080">>, #{})),
        ?_assertMatch(#{}, New(<<"http://[::1]:8080">>, #{})),
        ?_assertError(
            {insecure_endpoint, <<"http://xet.example.com">>},
            New(<<"http://xet.example.com">>, #{})
        ),
        ?_assertMatch(#{}, New(<<"http://xet.example.com">>, #{allow_insecure_http => true})),
        ?_assertMatch(
            #{}, xet_client:new(#{endpoint => <<"http://xet.example.com">>, token => <<>>})
        )
    ].
