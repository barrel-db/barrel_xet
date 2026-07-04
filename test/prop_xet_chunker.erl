%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(prop_xet_chunker).

-include_lib("proper/include/proper.hrl").

-define(MIN_CHUNK, 8192).
-define(MAX_CHUNK, 131072).

%% Deterministic data by seed keeps generation cheap while covering the
%% interesting size range (several chunks worth of bytes).
gen_data() ->
    ?LET(
        {Seed, Len},
        {integer(0, 1 bsl 48), integer(0, 200000)},
        xet_test_vectors:splitmix64_data(Len, Seed)
    ).

gen_const_data() ->
    ?LET(
        {Byte, Len},
        {integer(0, 255), integer(0, 300000)},
        binary:copy(<<Byte>>, max(Len, 1))
    ).

prop_nif_matches_reference() ->
    ?FORALL(
        Data,
        gen_data(),
        xet_chunker:chunk_boundaries(Data) =:= xet_chunker_ref:chunk_boundaries(Data)
    ).

prop_nif_matches_reference_const() ->
    ?FORALL(
        Data,
        gen_const_data(),
        xet_chunker:chunk_boundaries(Data) =:= xet_chunker_ref:chunk_boundaries(Data)
    ).

%% Splitting the input into arbitrary segments never changes boundaries.
prop_buffer_split_invariance() ->
    ?FORALL(
        {Data, Splits},
        {gen_data(), list(integer(1, 50000))},
        begin
            {Cuts, State} = feed(Data, Splits),
            Cuts ++ xet_chunker:finalize(State) =:=
                xet_chunker:chunk_boundaries(Data)
        end
    ).

%% Structural invariants: strictly increasing, last equals input size,
%% every chunk within [MIN, MAX] except a possibly short final chunk.
prop_boundary_invariants() ->
    ?FORALL(
        Data,
        gen_data(),
        begin
            Bs = xet_chunker:chunk_boundaries(Data),
            Sizes = sizes(0, Bs),
            Increasing = Bs =:= lists:usort(Bs),
            LastOk =
                case byte_size(Data) of
                    0 -> Bs =:= [];
                    N -> lists:last(Bs) =:= N
                end,
            MidOk = lists:all(
                fun(S) -> S >= ?MIN_CHUNK andalso S =< ?MAX_CHUNK end,
                all_but_last(Sizes)
            ),
            FinalOk =
                Sizes =:= [] orelse
                    (lists:last(Sizes) >= 1 andalso lists:last(Sizes) =< ?MAX_CHUNK),
            Increasing andalso LastOk andalso MidOk andalso FinalOk
        end
    ).

feed(Data, Splits) ->
    Pieces = pieces(Data, Splits),
    lists:foldl(
        fun(Piece, {Acc, S0}) ->
            {New, S1} = xet_chunker:update(S0, Piece),
            {Acc ++ New, S1}
        end,
        {[], xet_chunker:new()},
        Pieces
    ).

pieces(Bin, []) ->
    [Bin];
pieces(Bin, [S | Rest]) when byte_size(Bin) > S ->
    <<Piece:S/binary, More/binary>> = Bin,
    [Piece | pieces(More, Rest)];
pieces(Bin, _) ->
    [Bin].

sizes(_Prev, []) -> [];
sizes(Prev, [B | Rest]) -> [B - Prev | sizes(B, Rest)].

all_but_last([]) -> [];
all_but_last(L) -> lists:droplast(L).
