%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(xet_upload_plan_tests).

-include_lib("eunit/include/eunit.hrl").

run_plan(Files, Opts) ->
    S0 = xet_upload_plan:new(Opts),
    {AllEmitted, S1} = lists:foldl(
        fun({Id, Chunks}, {Acc, S}) ->
            {Emitted, S2} = xet_upload_plan:add_file(S, Id, Chunks),
            {Acc ++ Emitted, S2}
        end,
        {[], S0},
        Files
    ),
    Result = xet_upload_plan:finalize(S1),
    Result#{xorbs := AllEmitted ++ maps:get(xorbs, Result)}.

xorb_map(Result, Extra) ->
    maps:merge(
        Extra,
        maps:from_list([{maps:get(hash, X), maps:get(chunks, X)} || X <- maps:get(xorbs, Result)])
    ).

replay(File, XorbMap) ->
    list_to_binary([
        lists:sublist(
            maps:get(maps:get(cas_hash, T), XorbMap),
            maps:get(chunk_start, T) + 1,
            maps:get(chunk_end, T) - maps:get(chunk_start, T)
        )
     || T <- maps:get(terms, File)
    ]).

chunks(Seeds) ->
    [xet_test_vectors:splitmix64_data(400 + (Seed rem 300), Seed) || Seed <- Seeds].

single_file_test() ->
    Data = chunks([1, 2, 3, 4]),
    Result = run_plan([{f1, Data}], #{}),
    [File] = maps:get(files, Result),
    [Xorb] = maps:get(xorbs, Result),
    ?assertEqual(list_to_binary(Data), replay(File, xorb_map(Result, #{}))),
    Entries = [{xet_hash:chunk_hash(C), byte_size(C)} || C <- Data],
    ?assertEqual(xet_hash:file_hash(Entries), maps:get(file_hash, File)),
    ?assertEqual(
        crypto:hash(sha256, list_to_binary(Data)),
        maps:get(sha256, File)
    ),
    ?assertEqual(Entries, maps:get(entries, Xorb)),
    Stats = maps:get(stats, Result),
    ?assertEqual(4, maps:get(new_chunks, Stats)),
    ?assertEqual(0, maps:get(deduped_chunks, Stats)).

intra_file_dedup_test() ->
    [A, B, C] = chunks([10, 11, 12]),
    Result = run_plan([{f1, [A, B, A, B, C]}], #{}),
    [File] = maps:get(files, Result),
    ?assertEqual(list_to_binary([A, B, A, B, C]), replay(File, xorb_map(Result, #{}))),
    [Xorb] = maps:get(xorbs, Result),
    ?assertEqual(3, length(maps:get(chunks, Xorb))),
    Stats = maps:get(stats, Result),
    ?assertEqual(3, maps:get(new_chunks, Stats)),
    ?assertEqual(2, maps:get(deduped_chunks, Stats)).

cross_file_dedup_test() ->
    Data = chunks([20, 21, 22]),
    Result = run_plan([{f1, Data}, {f2, Data}], #{}),
    [F1, F2] = maps:get(files, Result),
    Map = xorb_map(Result, #{}),
    ?assertEqual(list_to_binary(Data), replay(F1, Map)),
    ?assertEqual(list_to_binary(Data), replay(F2, Map)),
    ?assertEqual(maps:get(file_hash, F1), maps:get(file_hash, F2)),
    ?assertEqual(3, maps:get(new_chunks, maps:get(stats, Result))),
    ?assertEqual(3, maps:get(deduped_chunks, maps:get(stats, Result))),
    ?assertEqual(
        [
            #{
                cas_hash => maps:get(hash, hd(maps:get(xorbs, Result))),
                unpacked_len => maps:get(total_len, F2),
                chunk_start => 0,
                chunk_end => 3
            }
        ],
        maps:get(terms, F2)
    ).

cut_limits_test() ->
    Data = chunks(lists:seq(30, 39)),
    Result = run_plan([{f1, Data}], #{cut_chunks => 4}),
    Xorbs = maps:get(xorbs, Result),
    ?assertEqual([4, 4, 2], [length(maps:get(chunks, X)) || X <- Xorbs]),
    [File] = maps:get(files, Result),
    ?assertEqual(list_to_binary(Data), replay(File, xorb_map(Result, #{}))),
    ?assertEqual(3, length(maps:get(terms, File))).

cache_dedup_test() ->
    Corpus = chunks([40, 41, 42]),
    CasHash = <<77:256>>,
    CacheMap = maps:from_list([
        {xet_hash:chunk_hash(C), {CasHash, I}}
     || {I, C} <- lists:zip(lists:seq(0, 2), Corpus)
    ]),
    Cache = fun(H) ->
        case maps:find(H, CacheMap) of
            {ok, Loc} -> {ok, Loc};
            error -> not_found
        end
    end,
    Result = run_plan([{f1, Corpus}], #{cache => Cache}),
    ?assertEqual([], maps:get(xorbs, Result)),
    [File] = maps:get(files, Result),
    ?assertEqual(
        list_to_binary(Corpus),
        replay(File, #{CasHash => Corpus})
    ),
    ?assertEqual(0, maps:get(new_chunks, maps:get(stats, Result))).

global_query_test() ->
    Corpus = chunks([50, 51, 52, 53]),
    CasHash = <<88:256>>,
    Mappings = [
        {xet_hash:chunk_hash(C), CasHash, I}
     || {I, C} <- lists:zip(lists:seq(0, 3), Corpus)
    ],
    Counter = ets:new(queries, [public]),
    ets:insert(Counter, {count, 0}),
    Query = fun(_Hash) ->
        ets:update_counter(Counter, count, 1),
        {ok, Mappings}
    end,
    Result = run_plan([{f1, Corpus}], #{query => Query}),
    %% The first chunk is always eligible; its answer maps every chunk,
    %% and spacing gates any further query.
    ?assertEqual([{count, 1}], ets:lookup(Counter, count)),
    ?assertEqual(0, maps:get(new_chunks, maps:get(stats, Result))),
    [File] = maps:get(files, Result),
    ?assertEqual(list_to_binary(Corpus), replay(File, #{CasHash => Corpus})).

defrag_prevention_test() ->
    Corpus = chunks(lists:seq(60, 79)),
    CasHash = <<99:256>>,
    CacheMap = maps:from_list([
        {xet_hash:chunk_hash(C), {CasHash, I}}
     || {I, C} <- lists:zip(lists:seq(0, 19), Corpus)
    ]),
    Cache = fun(H) ->
        case maps:find(H, CacheMap) of
            {ok, Loc} -> {ok, Loc};
            error -> not_found
        end
    end,
    %% Window 4 fills with ranges (3-chunk dedup runs and 1-chunk new
    %% ranges alternating: average 2), then a lone scattered dedup (run
    %% length 1 < 2) must be prevented and stored as new data.
    Fresh = chunks([100, 101, 102]),
    Input =
        lists:sublist(Corpus, 1, 3) ++ [lists:nth(1, Fresh)] ++
            lists:sublist(Corpus, 8, 3) ++ [lists:nth(2, Fresh)] ++
            [lists:nth(15, Corpus)] ++ [lists:nth(3, Fresh)],
    Result = run_plan([{f1, Input}], #{cache => Cache, defrag => {4, 8.0, 0.5}}),
    Stats = maps:get(stats, Result),
    ?assertEqual(1, maps:get(defrag_prevented_chunks, Stats)),
    ?assertEqual(4, maps:get(new_chunks, Stats)),
    [File] = maps:get(files, Result),
    ?assertEqual(
        list_to_binary(Input),
        replay(File, xorb_map(Result, #{CasHash => Corpus}))
    ).

verification_test() ->
    Corpus = chunks([80, 81]),
    CasHash = <<111:256>>,
    Cache = fun(H) ->
        Map = maps:from_list([
            {xet_hash:chunk_hash(C), {CasHash, I}}
         || {I, C} <- lists:zip([0, 1], Corpus)
        ]),
        case maps:find(H, Map) of
            {ok, Loc} -> {ok, Loc};
            error -> not_found
        end
    end,
    Fresh = chunks([90, 91]),
    Input = Corpus ++ Fresh,
    Result = run_plan([{f1, Input}], #{cache => Cache}),
    [File] = maps:get(files, Result),
    [V1, V2] = maps:get(verification, File),
    ?assertEqual(
        xet_hash:verification_hash([xet_hash:chunk_hash(C) || C <- Corpus]), V1
    ),
    ?assertEqual(
        xet_hash:verification_hash([xet_hash:chunk_hash(C) || C <- Fresh]), V2
    ).

empty_file_test() ->
    Result = run_plan([{f1, []}], #{}),
    [File] = maps:get(files, Result),
    ?assertEqual(xet_hash:zero_hash(), maps:get(file_hash, File)),
    ?assertEqual([], maps:get(terms, File)),
    ?assertEqual(0, maps:get(total_len, File)),
    ?assertEqual([], maps:get(xorbs, Result)).
