%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(prop_xet_bg4).

-include_lib("proper/include/proper.hrl").

prop_roundtrip() ->
    ?FORALL(
        Data,
        binary(),
        xet_bg4:ungroup(xet_bg4:group(Data), byte_size(Data)) =:= Data
    ).

prop_size_preserved() ->
    ?FORALL(
        Data,
        binary(),
        byte_size(xet_bg4:group(Data)) =:= byte_size(Data)
    ).

prop_multiset_preserved() ->
    ?FORALL(
        Data,
        binary(),
        lists:sort(binary_to_list(xet_bg4:group(Data))) =:=
            lists:sort(binary_to_list(Data))
    ).
