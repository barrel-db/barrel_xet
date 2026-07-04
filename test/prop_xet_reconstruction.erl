%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(prop_xet_reconstruction).

-include_lib("proper/include/proper.hrl").

%% A random world: one or two xorbs of small chunks, a file made of
%% random term slices over them, and a random byte range.
gen_world() ->
    ?LET(
        {SeedA, NA, SeedB, NB, TermPicks},
        {
            integer(1, 1 bsl 30),
            integer(2, 8),
            integer(1, 1 bsl 30),
            integer(2, 8),
            non_empty(resize(6, list({range(1, 2), integer(0, 100), integer(1, 100)})))
        },
        begin
            ChunksA = mk_chunks(SeedA, NA),
            ChunksB = mk_chunks(SeedB, NB),
            Terms = [mk_term(Pick, ChunksA, ChunksB) || Pick <- TermPicks],
            {ChunksA, ChunksB, Terms}
        end
    ).

mk_chunks(Seed, N) ->
    [xet_test_vectors:splitmix64_data(1 + (Seed + I) rem 40, Seed + I) || I <- lists:seq(1, N)].

mk_term({Which, StartPick, SpanPick}, ChunksA, ChunksB) ->
    Chunks =
        case Which of
            1 -> ChunksA;
            2 -> ChunksB
        end,
    N = length(Chunks),
    S = StartPick rem N,
    E = S + 1 + (SpanPick rem (N - S)),
    Len = lists:sum([byte_size(C) || C <- lists:sublist(Chunks, S + 1, E - S)]),
    {Which, #{chunk_start => S, chunk_end => E, unpacked_len => Len}}.

prop_slice_equals_source() ->
    ?FORALL(
        {{ChunksA, ChunksB, TaggedTerms}, RangeSeed},
        {gen_world(), {integer(0, 1 bsl 30), integer(0, 1 bsl 30)}},
        begin
            HashA = xet_hash:xorb_hash([{xet_hash:chunk_hash(C), byte_size(C)} || C <- ChunksA]),
            HashB = xet_hash:xorb_hash([{xet_hash:chunk_hash(C), byte_size(C)} || C <- ChunksB]),
            Info = #{
                HashA => xorb_info(ChunksA),
                HashB => xorb_info(ChunksB)
            },
            Data = #{HashA => ChunksA, HashB => ChunksB},
            Terms = [
                T#{cas_hash => tag_hash(Which, HashA, HashB)}
             || {Which, T} <- TaggedTerms
            ],
            Source = list_to_binary([term_data(T, Data) || T <- Terms]),
            Total = byte_size(Source),
            {S0, E0} = RangeSeed,
            Start = S0 rem max(Total, 1),
            End = Start + (E0 rem max(Total - Start, 1)),
            InfoFun = fun(Cas) -> maps:get(Cas, Info) end,
            {ok, Plan} = xet_reconstruction:plan(Terms, Total, {Start, End}, InfoFun),
            Len = min(End, Total - 1) - Start + 1,
            Assembled = assemble(Plan, Data),
            binary:part(Assembled, 0, Len) =:= binary:part(Source, Start, Len)
        end
    ).

tag_hash(1, HashA, _) -> HashA;
tag_hash(2, _, HashB) -> HashB.

xorb_info(Chunks) ->
    Sizes = [byte_size(C) || C <- Chunks],
    {Offsets, _} = lists:mapfoldl(fun(S, Acc) -> {Acc + S, Acc + S} end, 0, Sizes),
    %% Serialized boundaries are irrelevant for plan/4; reuse unpacked.
    #{unpacked_offsets => Offsets, boundary_offsets => Offsets}.

term_data(#{cas_hash := Cas, chunk_start := S, chunk_end := E}, Data) ->
    lists:sublist(maps:get(Cas, Data), S + 1, E - S).

assemble(Plan, Data) ->
    All = list_to_binary([term_data(T, Data) || T <- maps:get(terms, Plan)]),
    Skip = maps:get(offset_into_first_range, Plan),
    binary:part(All, Skip, byte_size(All) - Skip).

prop_full_plan_is_identity() ->
    ?FORALL(
        {ChunksA, ChunksB, TaggedTerms},
        gen_world(),
        begin
            HashA = xet_hash:xorb_hash([{xet_hash:chunk_hash(C), byte_size(C)} || C <- ChunksA]),
            HashB = xet_hash:xorb_hash([{xet_hash:chunk_hash(C), byte_size(C)} || C <- ChunksB]),
            Info = #{HashA => xorb_info(ChunksA), HashB => xorb_info(ChunksB)},
            Terms = [
                T#{cas_hash => tag_hash(Which, HashA, HashB)}
             || {Which, T} <- TaggedTerms
            ],
            Total = lists:sum([maps:get(unpacked_len, T) || T <- Terms]),
            InfoFun = fun(Cas) -> maps:get(Cas, Info) end,
            {ok, Plan} = xet_reconstruction:plan(Terms, Total, all, InfoFun),
            maps:get(terms, Plan) =:= Terms andalso
                maps:get(offset_into_first_range, Plan) =:= 0
        end
    ).
