%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(xet_hash_tests).

-include_lib("eunit/include/eunit.hrl").

%% Spec C.2: the 0..31 byte hash and its string form, both directions.
c2_conversion_test() ->
    Bytes = xet_test_vectors:hash_string_bytes(),
    Expected = xet_test_vectors:hash_string_expected(),
    ?assertEqual(Expected, xet_hash:to_string(Bytes)),
    ?assertEqual(Bytes, xet_hash:from_string(Expected)).

%% Spec C.1: raw chunk hash and its string form agree with the vectors.
c1_string_form_test() ->
    ?assertEqual(
        xet_test_vectors:chunk_hash_string(),
        xet_hash:to_string(xet_test_vectors:chunk_hash_raw())
    ),
    ?assertEqual(
        xet_test_vectors:chunk_hash_raw(),
        xet_hash:from_string(xet_test_vectors:chunk_hash_string())
    ).

is_hash_string_test() ->
    Valid = xet_test_vectors:chunk_hash_string(),
    ?assert(xet_hash:is_hash_string(Valid)),
    Upper = string:uppercase(Valid),
    ?assertNot(xet_hash:is_hash_string(Upper)),
    ?assertNot(xet_hash:is_hash_string(binary:part(Valid, 0, 63))),
    ?assertNot(xet_hash:is_hash_string(<<Valid/binary, "0">>)),
    Bad = <<"g", (binary:part(Valid, 1, 63))/binary>>,
    ?assertNot(xet_hash:is_hash_string(Bad)),
    ?assertNot(xet_hash:is_hash_string(not_a_binary)).

from_string_strict_test() ->
    Valid = xet_test_vectors:chunk_hash_string(),
    ?assertError(badarg, xet_hash:from_string(string:uppercase(Valid))),
    ?assertError(badarg, xet_hash:from_string(<<"zz">>)).
