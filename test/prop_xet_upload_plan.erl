-module(prop_xet_upload_plan).

-include_lib("proper/include/proper.hrl").

%% Files drawing from a shared pool of chunks (forcing dedup) mixed with
%% fresh unique chunks.
gen_input() ->
    ?LET(
        {PoolSeeds, FileCount},
        {non_empty(resize(6, list(integer(1, 1 bsl 30)))), integer(1, 3)},
        ?LET(
            Picks,
            vector(
                FileCount,
                resize(25, list(oneof([{pool, integer(1, 100)}, {fresh, integer(1, 1 bsl 30)}])))
            ),
            begin
                Pool = [chunk(S) || S <- PoolSeeds],
                Files = [
                    {FileIdx, [
                        case Pick of
                            {pool, K} -> lists:nth(1 + K rem length(Pool), Pool);
                            {fresh, S} -> chunk(S + 7919 * FileIdx)
                        end
                     || Pick <- FilePicks
                    ]}
                 || {FileIdx, FilePicks} <- lists:enumerate(Picks)
                ],
                Files
            end
        )
    ).

chunk(Seed) ->
    xet_test_vectors:splitmix64_data(50 + (Seed rem 400), Seed).

prop_replay_and_limits() ->
    ?FORALL(
        {Files, CutChunks},
        {gen_input(), integer(2, 6)},
        begin
            S0 = xet_upload_plan:new(#{cut_chunks => CutChunks}),
            {Emitted, S1} = lists:foldl(
                fun({Id, Chunks}, {Acc, S}) ->
                    {E, S2} = xet_upload_plan:add_file(S, Id, Chunks),
                    {Acc ++ E, S2}
                end,
                {[], S0},
                Files
            ),
            Result = xet_upload_plan:finalize(S1),
            Xorbs = Emitted ++ maps:get(xorbs, Result),
            XorbMap = maps:from_list([{maps:get(hash, X), maps:get(chunks, X)} || X <- Xorbs]),
            LimitsOk = lists:all(
                fun(X) -> length(maps:get(chunks, X)) =< CutChunks end, Xorbs
            ),
            HashesOk = lists:all(
                fun(X) ->
                    maps:get(hash, X) =:= xet_hash:xorb_hash(maps:get(entries, X))
                end,
                Xorbs
            ),
            ReplayOk = lists:all(
                fun({{Id, Chunks}, File}) ->
                    Id =:= maps:get(file_id, File) andalso
                        replay(File, XorbMap) =:= list_to_binary(Chunks) andalso
                        maps:get(file_hash, File) =:=
                            xet_hash:file_hash([
                                {xet_hash:chunk_hash(C), byte_size(C)}
                             || C <- Chunks
                            ])
                end,
                lists:zip(Files, maps:get(files, Result))
            ),
            LimitsOk andalso HashesOk andalso ReplayOk
        end
    ).

prop_duplicate_session_no_new_bytes() ->
    ?FORALL(
        Files,
        gen_input(),
        begin
            Once = total_new(Files),
            Twice = total_new(Files ++ [{dup, Chunks} || {_, Chunks} <- Files]),
            Once =:= Twice
        end
    ).

total_new(Files) ->
    S0 = xet_upload_plan:new(#{}),
    S1 = lists:foldl(
        fun({Id, Chunks}, S) ->
            {_, S2} = xet_upload_plan:add_file(S, Id, Chunks),
            S2
        end,
        S0,
        Files
    ),
    maps:get(new_bytes, maps:get(stats, xet_upload_plan:finalize(S1))).

replay(File, XorbMap) ->
    list_to_binary([
        lists:sublist(
            maps:get(maps:get(cas_hash, T), XorbMap),
            maps:get(chunk_start, T) + 1,
            maps:get(chunk_end, T) - maps:get(chunk_start, T)
        )
     || T <- maps:get(terms, File)
    ]).
