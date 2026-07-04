-module(xet_dedup_tests).

-include_lib("eunit/include/eunit.hrl").

eligibility_test() ->
    NotSelected = <<0:192, 1:64/little>>,
    Selected = <<0:192, 2048:64/little>>,
    ?assert(xet_dedup:eligible(NotSelected, true)),
    ?assertNot(xet_dedup:eligible(NotSelected, false)),
    ?assert(xet_dedup:eligible(Selected, false)),
    ?assert(xet_dedup:hash_eligible(xet_hash:zero_hash())).

sample_blocks() ->
    [
        #{
            cas_hash => <<1:256>>,
            bytes_on_disk => 500,
            chunks => [
                #{hash => xet_hash:chunk_hash(<<"a">>), size => 100, dedup_eligible => true},
                #{hash => xet_hash:chunk_hash(<<"b">>), size => 200, dedup_eligible => false}
            ]
        },
        #{
            cas_hash => <<2:256>>,
            bytes_on_disk => 300,
            chunks => [
                #{hash => xet_hash:chunk_hash(<<"c">>), size => 50, dedup_eligible => false}
            ]
        }
    ].

keyed_response_roundtrip_test() ->
    Key = binary:copy(<<3>>, 32),
    Bin = xet_dedup:build_response(sample_blocks(), #{
        chunk_hash_key => Key, created_at => 1, key_expiry => 2
    }),
    {ok, Shard} = xet_shard:decode(Bin),
    ?assertEqual([], maps:get(files, Shard)),
    ?assertEqual(
        {ok, #{cas_hash => <<2:256>>, chunk_index => 0}},
        xet_dedup:match(Shard, xet_hash:chunk_hash(<<"c">>))
    ),
    ?assertEqual(
        {ok, #{cas_hash => <<1:256>>, chunk_index => 1}},
        xet_dedup:match(Shard, xet_hash:chunk_hash(<<"b">>))
    ),
    ?assertEqual(not_found, xet_dedup:match(Shard, xet_hash:chunk_hash(<<"nope">>))),
    %% The wire form must not contain the raw hashes.
    ?assertEqual(nomatch, binary:match(Bin, xet_hash:chunk_hash(<<"a">>))).

zero_key_response_test() ->
    Bin = xet_dedup:build_response(sample_blocks(), #{
        chunk_hash_key => xet_hash:zero_hash(), created_at => 1, key_expiry => 0
    }),
    {ok, Shard} = xet_shard:decode(Bin),
    ?assertMatch({ok, _}, xet_dedup:match(Shard, xet_hash:chunk_hash(<<"a">>))),
    ?assertNotEqual(nomatch, binary:match(Bin, xet_hash:chunk_hash(<<"a">>))).

expiry_test() ->
    Key = binary:copy(<<4>>, 32),
    Bin = xet_dedup:build_response(sample_blocks(), #{
        chunk_hash_key => Key, created_at => 100, key_expiry => 200
    }),
    {ok, Shard} = xet_shard:decode(Bin),
    ?assertNot(xet_dedup:expired(Shard, 199)),
    ?assert(xet_dedup:expired(Shard, 200)),
    Unkeyed = xet_dedup:build_response(sample_blocks(), #{
        chunk_hash_key => xet_hash:zero_hash(), created_at => 100, key_expiry => 0
    }),
    {ok, Shard2} = xet_shard:decode(Unkeyed),
    ?assertNot(xet_dedup:expired(Shard2, 1 bsl 50)).

%% The reference dedupe shard: every stored hash must equal
%% keyed_chunk_hash(footer key, original chunk hash), and match/2 must
%% locate every original chunk at its position.
reference_dedupe_match_test() ->
    {ok, Bin} = file:read_file(
        xet_test_vectors:fixture_path("Electric_Vehicle_Population_Data_20250917.csv.shard.dedupe")
    ),
    {ok, Shard} = xet_shard:decode(Bin),
    #{chunk_hash_key := Key} = maps:get(footer, Shard),
    ?assertNotEqual(xet_hash:zero_hash(), Key),
    Listing = xet_test_vectors:parse_chunks_file(
        xet_test_vectors:fixture_path("Electric_Vehicle_Population_Data_20250917.csv.chunks")
    ),
    Originals = [xet_hash:from_string(S) || {S, _} <- Listing],
    [#{chunks := StoredChunks, cas_hash := CasHash}] = maps:get(cas, Shard),
    ?assertEqual(length(Originals), length(StoredChunks)),
    Stored = [maps:get(hash, C) || C <- StoredChunks],
    Keyed = [xet_hash:keyed_chunk_hash(Key, H) || H <- Originals],
    ?assertEqual(Stored, Keyed),
    ?assertEqual(
        xet_test_vectors:expected_xorb_hash_string(),
        xet_hash:to_string(CasHash)
    ),
    lists:foreach(
        fun({I, Original}) ->
            ?assertEqual(
                {ok, #{cas_hash => CasHash, chunk_index => I}},
                xet_dedup:match(Shard, Original)
            )
        end,
        lists:zip(lists:seq(0, 9), lists:sublist(Originals, 10))
    ).
