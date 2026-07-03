-module(xet_hash_domain_tests).

-include_lib("eunit/include/eunit.hrl").

%% Spec C.1 through the public chunk_hash API.
c1_chunk_hash_test() ->
    ?assertEqual(
        xet_test_vectors:chunk_hash_raw(),
        xet_hash:chunk_hash(xet_test_vectors:chunk_hash_input())
    ).

%% Spec C.4: verification hash over two raw chunk hashes.
c4_verification_hash_test() ->
    ?assertEqual(
        xet_test_vectors:verification_result_string(),
        xet_hash:to_string(xet_hash:verification_hash(xet_test_vectors:verification_hashes_raw()))
    ).

empty_file_hash_test() ->
    ?assertEqual(xet_hash:zero_hash(), xet_hash:file_hash([])).

%% The reference listing gives every (chunk hash, size) of the real 63 MB
%% file: the file hash and the single xorb's hash must both fall out of
%% the merkle stack exactly.
reference_file_and_xorb_hash_test() ->
    Chunks = xet_test_vectors:parse_chunks_file(
        xet_test_vectors:fixture_path("Electric_Vehicle_Population_Data_20250917.csv.chunks")
    ),
    Entries = [{xet_hash:from_string(S), Size} || {S, Size} <- Chunks],
    ?assertEqual(
        xet_test_vectors:expected_file_hash_string(),
        xet_hash:to_string(xet_hash:file_hash(Entries))
    ),
    ?assertEqual(
        xet_test_vectors:expected_xorb_hash_string(),
        xet_hash:to_string(xet_hash:xorb_hash(Entries))
    ).

keyed_chunk_hash_test() ->
    ChunkHash = xet_test_vectors:chunk_hash_raw(),
    %% All-zero key means identity, not keyed-with-zeros.
    ?assertEqual(ChunkHash, xet_hash:keyed_chunk_hash(xet_hash:zero_hash(), ChunkHash)),
    Key = binary:copy(<<5>>, 32),
    Keyed = xet_hash:keyed_chunk_hash(Key, ChunkHash),
    ?assertNotEqual(ChunkHash, Keyed),
    ?assertEqual(32, byte_size(Keyed)).
