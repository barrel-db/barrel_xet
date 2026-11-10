%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
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

%% Lookup indices count 48-byte entries, as xet-core writes them
%% (metadata_shard/shard_format.rs: file index += block bytes / 48, CAS
%% index += 1 + num_chunks). File 1 spans header + 2 terms + 2
%% verification + 1 ext = 6 entries; CAS blocks of 2, 3, 1 chunks start
%% at 0, 3, 7.
lookup_indices_test() ->
    H = fun(N) -> <<N, 0:248>> end,
    #{files := [F1, F2]} = sample(),
    Files = [F1#{file_hash := H(1)}, F2#{file_hash := H(2)}],
    Cas = [
        #{
            cas_hash => H(10 + I),
            bytes_on_disk => 0,
            chunks => [#{hash => H(100 + 10 * I + J), size => 1} || J <- lists:seq(1, N)]
        }
     || {I, N} <- [{0, 2}, {1, 3}, {2, 1}]
    ],
    {FileTab, CasTab, ChunkTab} = xet_shard_footer:encode_lookups(Files, Cas),
    ?assertEqual([0, 6], [I || <<_:64, I:32/little>> <= FileTab]),
    ?assertEqual([0, 3, 7], [I || <<_:64, I:32/little>> <= CasTab]),
    ?assertEqual(
        [{0, 0}, {0, 1}, {3, 0}, {3, 1}, {3, 2}, {7, 0}],
        [{I, J} || <<_:64, I:32/little, J:32/little>> <= ChunkTab]
    ),
    Bin = xet_shard:encode_stored(#{files => Files, cas => Cas}, #{
        chunk_hash_key => xet_hash:zero_hash(), created_at => 1, key_expiry => 0
    }),
    ?assertMatch({ok, _}, xet_shard:decode(Bin)).

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

%% Spec 9.4/9.5 body rejects on the upload form of sample(). Offsets:
%% header 48; file 1 header at 48 (flags 80, reserved 88), 2 terms at
%% 96 (term CAS flags 128), 2 verification entries at 192 (reserved 224),
%% metadata ext at 288 (reserved 320); file 2 at 336, bookend at 432;
%% CAS header at 480 (flags 512), first chunk at 528 (flags 568,
%% reserved 572).
body_rejects_test() ->
    Bin = xet_shard:encode_upload(sample()),
    Cases = [
        {80, bad_file_flags},
        {88, bad_file_block},
        {128, bad_term_entry},
        {224, bad_verification_entry},
        {320, bad_metadata_ext},
        {512, bad_cas_block},
        {568, bad_chunk_entry},
        {572, bad_chunk_entry}
    ],
    lists:foreach(
        fun({Pos, Reason}) ->
            %% Each target is a zero flag or reserved byte.
            ?assertEqual({Pos, 0}, {Pos, binary:at(Bin, Pos)}),
            ?assertEqual({Pos, {error, Reason}}, {Pos, xet_shard:decode(patch(Bin, Pos, 1))})
        end,
        Cases
    ),
    %% Bookend: 32 x 0xFF then 16 x 0x00.
    ?assertEqual(16#FF, binary:at(Bin, 432)),
    ?assertMatch({error, _}, xet_shard:decode(patch(Bin, 432, 0))),
    ?assertMatch({error, _}, xet_shard:decode(patch(Bin, 432 + 40, 1))).

%% Spec 9.6 footer rejects on a stored shard.
footer_rejects_test() ->
    H = fun(N) -> <<N, 0:248>> end,
    #{files := [F1, F2], cas := Cas} = sample(),
    Shard = #{files => [F1#{file_hash := H(2)}, F2#{file_hash := H(1)}], cas => Cas},
    Bin = xet_shard:encode_stored(Shard, #{
        chunk_hash_key => xet_hash:zero_hash(), created_at => 1, key_expiry => 0
    }),
    ?assertMatch({ok, _}, xet_shard:decode(Bin)),
    FS = byte_size(Bin) - 200,
    ?assertEqual({error, bad_footer_version}, xet_shard:decode(patch(Bin, FS, 2))),
    %% file_info_offset must be 48; cas_info_offset must follow it.
    ?assertEqual({error, bad_footer_offsets}, xet_shard:decode(patch(Bin, FS + 8, 49))),
    ?assertEqual({error, bad_footer_offsets}, xet_shard:decode(patch(Bin, FS + 64, 99))),
    %% Swap the two file lookup entries: no longer sorted.
    <<_:(FS + 24)/binary, Lookup:64/little, _/binary>> = Bin,
    <<Before:Lookup/binary, E1:12/binary, E2:12/binary, After/binary>> = Bin,
    Unsorted = <<Before/binary, E2/binary, E1/binary, After/binary>>,
    ?assertEqual({error, bad_lookup_tables}, xet_shard:decode(Unsorted)).

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

patch(Bin, Pos, Value) ->
    <<Before:Pos/binary, _, After/binary>> = Bin,
    <<Before/binary, Value, After/binary>>.
