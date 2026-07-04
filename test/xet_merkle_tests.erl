%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(xet_merkle_tests).

-include_lib("eunit/include/eunit.hrl").

%% All zig-xet golden roots (hashes and roots in XET string format).
golden_roots_test_() ->
    [
        {atom_to_list(Name), fun() ->
            Entries = [{xet_hash:from_string(S), Size} || {S, Size} <- StringEntries],
            ?assertEqual(Expected, xet_hash:to_string(xet_merkle:root(Entries)))
        end}
     || {Name, StringEntries, Expected} <- xet_test_vectors:merkle_vectors()
    ].

%% Spec C.3: the internal node buffer built from two children matches the
%% vector, both through the raw buffer and through the merge path.
c3_internal_node_test() ->
    [{S1, Size1}, {S2, Size2}] = xet_test_vectors:internal_node_children(),
    Expected = xet_test_vectors:internal_node_result_string(),
    Direct = xet_hash:internal_node_hash(xet_test_vectors:internal_node_buffer()),
    ?assertEqual(Expected, xet_hash:to_string(Direct)),
    Entries = [{xet_hash:from_string(S1), Size1}, {xet_hash:from_string(S2), Size2}],
    ?assertEqual(Expected, xet_hash:to_string(xet_merkle:root(Entries))).

cut_rules_test() ->
    ?assertEqual(0, xet_merkle:next_merge_cut([])),
    H = fun(N) -> {<<N:256>>, 1} end,
    ?assertEqual(1, xet_merkle:next_merge_cut([H(1)])),
    ?assertEqual(2, xet_merkle:next_merge_cut([H(1), H(2)])).

empty_root_test() ->
    ?assertEqual(xet_hash:zero_hash(), xet_merkle:root([])).
