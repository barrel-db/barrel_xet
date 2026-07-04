%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(xet_nif_tests).

-include_lib("eunit/include/eunit.hrl").

%% Official BLAKE3 test vectors (vendored from the BLAKE3 repo). Input is a
%% repeating 0..250 byte sequence of the given length; the keyed_hash field
%% is extended output, we compare the leading 32 bytes.
official_keyed_vectors_test_() ->
    {ok, Json} = file:read_file(
        xet_test_vectors:fixture_path("blake3_test_vectors.json")
    ),
    #{<<"key">> := Key, <<"cases">> := Cases} = json:decode(Json),
    32 = byte_size(Key),
    [
        {lists:flatten(io_lib:format("input_len ~p", [Len])), fun() ->
            Expected = binary:part(xet_test_vectors:hex_to_bin(KeyedHex), 0, 32),
            ?assertEqual(Expected, xet_nif:blake3_keyed(Key, pattern(Len)))
        end}
     || #{<<"input_len">> := Len, <<"keyed_hash">> := KeyedHex} <- Cases
    ].

%% Spec C.1: chunk hash = blake3_keyed(DATA_KEY, "Hello World!").
%% DATA_KEY inline here; xet_hash owns the constant from T1.4 on.
spec_c1_chunk_hash_test() ->
    DataKey = xet_test_vectors:hex_to_bin(
        "6697f5775b9550de3135cbaca597181c9de421109beb2b58b4d0b04b93adf229"
    ),
    ?assertEqual(
        xet_test_vectors:chunk_hash_raw(),
        xet_nif:blake3_keyed(DataKey, xet_test_vectors:chunk_hash_input())
    ).

iodata_input_test() ->
    Key = binary:copy(<<7>>, 32),
    Flat = <<"hello world, this is iodata">>,
    Nested = [<<"hello ">>, [<<"world">>, <<", ">>], [[<<"this is">>], <<" iodata">>]],
    ?assertEqual(xet_nif:blake3_keyed(Key, Flat), xet_nif:blake3_keyed(Key, Nested)).

dirty_path_consistency_test() ->
    %% Same input hashed below and above the dirty-scheduler threshold
    %% boundary must agree with itself when passed as smaller iodata parts.
    Key = binary:copy(<<1>>, 32),
    % 1.6 MB, dirty path
    Big = binary:copy(<<"0123456789abcdef">>, 100000),
    Parts = [binary:part(Big, I * 160000, 160000) || I <- lists:seq(0, 9)],
    ?assertEqual(xet_nif:blake3_keyed(Key, Big), xet_nif:blake3_keyed(Key, Parts)).

bad_key_test() ->
    ?assertError(function_clause, xet_nif:blake3_keyed(<<1, 2, 3>>, <<"x">>)),
    ?assertError(function_clause, xet_nif:blake3_keyed(not_a_key, <<"x">>)).

pattern(Len) ->
    Base = <<<<(I rem 251)>> || I <- lists:seq(0, 250)>>,
    Full = binary:copy(Base, Len div 251 + 1),
    binary:part(Full, 0, Len).
