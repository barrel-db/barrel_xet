-module(xet_shard_tests).

-include_lib("eunit/include/eunit.hrl").

sample() ->
    H = fun(N) -> <<N:256>> end,
    #{
        files => [
            #{
                file_hash => H(1),
                terms => [
                    #{cas_hash => H(10), unpacked_len => 1000, chunk_start => 0, chunk_end => 4},
                    #{cas_hash => H(11), unpacked_len => 500, chunk_start => 2, chunk_end => 5}
                ],
                verification => [H(20), H(21)],
                sha256 => H(30)
            },
            #{
                file_hash => H(2),
                terms => [
                    #{cas_hash => H(10), unpacked_len => 64, chunk_start => 1, chunk_end => 2}
                ]
            }
        ],
        cas => [
            #{
                cas_hash => H(10),
                bytes_on_disk => 900,
                chunks => [
                    #{hash => H(40), size => 300, dedup_eligible => true},
                    #{hash => H(41), size => 700, dedup_eligible => false}
                ]
            }
        ]
    }.

upload_roundtrip_test() ->
    Bin = xet_shard:encode_upload(sample()),
    {ok, Dec} = xet_shard:decode(Bin),
    #{files := Files, cas := Cas} = sample(),
    ?assertEqual(Files, maps:get(files, Dec)),
    ?assertEqual(Cas, maps:get(cas, Dec)),
    ?assertEqual(undefined, maps:get(footer, Dec)).

stored_roundtrip_test() ->
    Key = binary:copy(<<9>>, 32),
    Bin = xet_shard:encode_stored(sample(), #{
        chunk_hash_key => Key, created_at => 1751500000, key_expiry => 1751600000
    }),
    {ok, Dec} = xet_shard:decode(Bin),
    #{files := Files, cas := Cas} = sample(),
    ?assertEqual(Files, maps:get(files, Dec)),
    ?assertEqual(Cas, maps:get(cas, Dec)),
    Footer = maps:get(footer, Dec),
    ?assertEqual(Key, maps:get(chunk_hash_key, Footer)),
    ?assertEqual(1751500000, maps:get(created_at, Footer)),
    ?assertEqual(1751600000, maps:get(key_expiry, Footer)),
    ?assertEqual(900, maps:get(stored_bytes_on_disk, Footer)),
    ?assertEqual(1564, maps:get(materialized_bytes, Footer)),
    ?assertEqual(1000, maps:get(stored_bytes, Footer)).

empty_sections_test() ->
    Bin = xet_shard:encode_upload(#{files => [], cas => []}),
    {ok, Dec} = xet_shard:decode(Bin),
    ?assertEqual([], maps:get(files, Dec)),
    ?assertEqual([], maps:get(cas, Dec)).

tamper_test() ->
    Bin = xet_shard:encode_upload(sample()),
    ?assertEqual({error, bad_magic}, xet_shard:decode(flip(Bin, 20))),
    ?assertEqual({error, bad_version}, xet_shard:decode(flip(Bin, 32))),
    ?assertEqual({error, bad_footer_size}, xet_shard:decode(flip(Bin, 40))),
    ?assertMatch({error, _}, xet_shard:decode(binary:part(Bin, 0, byte_size(Bin) - 1))),
    ?assertMatch({error, _}, xet_shard:decode(<<Bin/binary, 0>>)),
    %% Break the cumulative chunk byte_range_start rule.
    {error, _} = xet_shard:decode(flip(Bin, byte_size(Bin) - 60)).

%% Golden shards from the reference dataset (all vendored, no skip).
reference_upload_form_test() ->
    {ok, Bin} = file:read_file(fixture(".shard.verification-no-footer")),
    {ok, Dec} = xet_shard:decode(Bin),
    ?assertEqual(undefined, maps:get(footer, Dec)),
    [File] = maps:get(files, Dec),
    ?assertEqual(
        xet_test_vectors:expected_file_hash_string(),
        xet_hash:to_string(maps:get(file_hash, File))
    ),
    %% Re-encode must be byte-identical.
    Re = xet_shard:encode_upload(#{files => maps:get(files, Dec), cas => maps:get(cas, Dec)}),
    ?assertEqual(Bin, Re).

reference_stored_forms_test() ->
    lists:foreach(
        fun(Suffix) ->
            {ok, Bin} = file:read_file(fixture(Suffix)),
            {ok, Dec} = xet_shard:decode(Bin),
            ?assertNotEqual(undefined, maps:get(footer, Dec))
        end,
        [".shard", ".shard.verification"]
    ).

reference_dedupe_form_test() ->
    {ok, Bin} = file:read_file(fixture(".shard.dedupe")),
    {ok, Dec} = xet_shard:decode(Bin),
    Footer = maps:get(footer, Dec),
    ?assertNotEqual(undefined, Footer),
    ?assertNotEqual(xet_hash:zero_hash(), maps:get(chunk_hash_key, Footer)).

%% The upload-form shard's verification hashes are recomputable from the
%% chunk listing: term ranges select chunk hashes, keyed verification
%% hash per term.
reference_verification_recompute_test() ->
    {ok, Bin} = file:read_file(fixture(".shard.verification-no-footer")),
    {ok, Dec} = xet_shard:decode(Bin),
    [File] = maps:get(files, Dec),
    Chunks = xet_test_vectors:parse_chunks_file(
        xet_test_vectors:fixture_path("Electric_Vehicle_Population_Data_20250917.csv.chunks")
    ),
    Hashes = list_to_tuple([xet_hash:from_string(S) || {S, _} <- Chunks]),
    Expected = [
        xet_hash:verification_hash([
            element(I + 1, Hashes)
         || I <- lists:seq(maps:get(chunk_start, T), maps:get(chunk_end, T) - 1)
        ])
     || T <- maps:get(terms, File)
    ],
    ?assertEqual(Expected, maps:get(verification, File)).

fixture(Suffix) ->
    xet_test_vectors:fixture_path("Electric_Vehicle_Population_Data_20250917.csv" ++ Suffix).

flip(Bin, Pos) ->
    <<Before:Pos/binary, Byte, After/binary>> = Bin,
    <<Before/binary, (Byte bxor 16#FF), After/binary>>.
