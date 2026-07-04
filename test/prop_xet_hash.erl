%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(prop_xet_hash).

-include_lib("proper/include/proper.hrl").

prop_string_roundtrip() ->
    ?FORALL(
        Hash,
        binary(32),
        xet_hash:from_string(xet_hash:to_string(Hash)) =:= Hash
    ).

prop_string_form() ->
    ?FORALL(
        Hash,
        binary(32),
        xet_hash:is_hash_string(xet_hash:to_string(Hash))
    ).
