%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(prop_xet_merkle).

-include_lib("proper/include/proper.hrl").

entry() ->
    {binary(32), integer(0, 1000000)}.

prop_root_deterministic() ->
    ?FORALL(
        Entries,
        list(entry()),
        xet_merkle:root(Entries) =:= xet_merkle:root(Entries)
    ).

prop_root_shape() ->
    ?FORALL(
        Entries,
        list(entry()),
        byte_size(xet_merkle:root(Entries)) =:= 32
    ).

%% Cut sizes: n for n =< 2, otherwise between 3 and min(9, n).
prop_cut_bounds() ->
    ?FORALL(
        Entries,
        list(entry()),
        begin
            Cut = xet_merkle:next_merge_cut(Entries),
            N = length(Entries),
            case N =< 2 of
                true -> Cut =:= N;
                false -> Cut >= 3 andalso Cut =< min(9, N)
            end
        end
    ).

prop_single_entry_is_root() ->
    ?FORALL(
        {Hash, Size},
        entry(),
        xet_merkle:root([{Hash, Size}]) =:= Hash
    ).

%% The root must depend on entry order: lists that differ from their
%% reverse by construction (distinct first and last entries) never share
%% a root.
prop_order_sensitive() ->
    ?FORALL(
        {First, Last, Mid},
        ?SUCHTHAT({A, B, _}, {entry(), entry(), list(entry())}, A =/= B),
        begin
            Entries = [First | Mid] ++ [Last],
            xet_merkle:root(Entries) =/= xet_merkle:root(lists:reverse(Entries))
        end
    ).
