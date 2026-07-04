-module(prop_xet_dedup).

-include_lib("proper/include/proper.hrl").

gen_block() ->
    ?LET(
        {CasHash, Chunks},
        {binary(32), non_empty(resize(10, list({binary(32), integer(1, 100000)})))},
        #{
            cas_hash => CasHash,
            bytes_on_disk => 1,
            chunks => [#{hash => H, size => S, dedup_eligible => false} || {H, S} <- Chunks]
        }
    ).

%% Every original chunk is findable through the keyed response; a fresh
%% random hash is not.
prop_match_roundtrip() ->
    ?FORALL(
        {Blocks, Key, Probe},
        {non_empty(resize(4, list(gen_block()))), binary(32), binary(32)},
        begin
            Bin = xet_dedup:build_response(Blocks, #{
                chunk_hash_key => Key, created_at => 1, key_expiry => 10
            }),
            {ok, Shard} = xet_shard:decode(Bin),
            AllFound = lists:all(
                fun(Block) ->
                    lists:all(
                        fun(C) ->
                            case xet_dedup:match(Shard, maps:get(hash, C)) of
                                {ok, _} -> true;
                                not_found -> false
                            end
                        end,
                        maps:get(chunks, Block)
                    )
                end,
                Blocks
            ),
            Known = [maps:get(hash, C) || B <- Blocks, C <- maps:get(chunks, B)],
            ProbeOk =
                case lists:member(Probe, Known) of
                    true -> true;
                    false -> xet_dedup:match(Shard, Probe) =:= not_found
                end,
            AllFound andalso ProbeOk
        end
    ).

prop_first_chunk_always_eligible() ->
    ?FORALL(Hash, binary(32), xet_dedup:eligible(Hash, true)).
