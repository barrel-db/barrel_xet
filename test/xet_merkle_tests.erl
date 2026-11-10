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

%% Spec 6.2.2.2: with more than two entries, cut after the first index
%% >= 2 whose hash tail (u64 LE of bytes 24..31) is divisible by 4,
%% capped at 9 children.
cut_point_rule_test() ->
    T = fun(Tail) -> {<<0:192, Tail:64/little>>, 1} end,
    %% Index 2 divisible: merge 3.
    ?assertEqual(3, xet_merkle:next_merge_cut([T(1), T(1), T(4), T(1)])),
    %% Divisible tails at index 0 and 1 do not count.
    ?assertEqual(5, xet_merkle:next_merge_cut([T(4), T(8), T(1), T(1), T(12), T(1)])),
    %% No divisible tail: everything up to the 9-child cap.
    ?assertEqual(5, xet_merkle:next_merge_cut([T(1) || _ <- lists:seq(1, 5)])),
    ?assertEqual(9, xet_merkle:next_merge_cut([T(1) || _ <- lists:seq(1, 12)])),
    %% A divisible tail past the cap is ignored.
    ?assertEqual(9, xet_merkle:next_merge_cut([T(1) || _ <- lists:seq(1, 9)] ++ [T(4)])).

empty_root_test() ->
    ?assertEqual(xet_hash:zero_hash(), xet_merkle:root([])).
