%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Reference-fixture conformance gate: pins our implementation against the
%% Hugging Face xet-team golden files. Small fixtures are vendored and
%% always run; large-fixture cases skip without `make fixtures`.
-module(xet_interop_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([
    chunk_files_hash_to_names/1,
    reference_shard_forms/1,
    reference_dedupe_matching/1,
    reference_chunking_and_hashes/1,
    reference_xorb_object/1,
    reference_upload_shard_byte_identical/1
]).

-define(CSV, "Electric_Vehicle_Population_Data_20250917.csv").
-define(XORB, "eea25d6ee393ccae385820daed127b96ef0ea034dfb7cf6da3a950ce334b7632").

all() ->
    [
        chunk_files_hash_to_names,
        reference_shard_forms,
        reference_dedupe_matching,
        reference_chunking_and_hashes,
        reference_xorb_object,
        reference_upload_shard_byte_identical
    ].

fixture(Name) ->
    xet_test_vectors:fixture_path(Name).

require_large(Case) ->
    case xet_test_vectors:have_large_fixtures() of
        true -> Case();
        false -> {skip, "large fixtures absent; run make fixtures"}
    end.

csv() ->
    {ok, Data} = file:read_file(
        xet_test_vectors:large_fixture_path(?CSV)
    ),
    Data.

listing() ->
    xet_test_vectors:parse_chunks_file(fixture(?CSV ".chunks")).

%%--------------------------------------------------------------------
%% Small-fixture cases (always run)
%%--------------------------------------------------------------------

%% Each standalone .chunk file's bytes hash to the chunk hash in its name.
chunk_files_hash_to_names(_Config) ->
    Names = [
        "099cb228194fe640e36a6c7d274ee5ed3a714ccd557a0951d9b6b43a7292b5d1",
        "26255591fa803b6baf25d88c315b8a6f5153d5bcfdf18ec5ef526264e0ccc907",
        "b10aa1dc71c61661de92280c41a188aabc47981739b785724a099945d8dc5ce4"
    ],
    lists:foreach(
        fun(Name) ->
            {ok, Bytes} = file:read_file(fixture(Name ++ ".chunk")),
            ?assertEqual(list_to_binary(Name), xet_hash:to_string(xet_hash:chunk_hash(Bytes)))
        end,
        Names
    ).

reference_shard_forms(_Config) ->
    lists:foreach(
        fun(Suffix) ->
            {ok, Bin} = file:read_file(fixture(?CSV ++ Suffix)),
            ?assertMatch({ok, _}, xet_shard:decode(Bin))
        end,
        [".shard", ".shard.verification", ".shard.verification-no-footer", ".shard.dedupe"]
    ),
    %% The upload form carries no footer; the stored forms do.
    {ok, Upload} = file:read_file(fixture(?CSV ".shard.verification-no-footer")),
    {ok, UploadShard} = xet_shard:decode(Upload),
    ?assertEqual(undefined, maps:get(footer, UploadShard)),
    {ok, Stored} = file:read_file(fixture(?CSV ".shard")),
    {ok, StoredShard} = xet_shard:decode(Stored),
    ?assertNotEqual(undefined, maps:get(footer, StoredShard)).

%% Every chunk in the dedupe response is the keyed hash of a listed chunk.
reference_dedupe_matching(_Config) ->
    {ok, Bin} = file:read_file(fixture(?CSV ".shard.dedupe")),
    {ok, Shard} = xet_shard:decode(Bin),
    #{chunk_hash_key := Key} = maps:get(footer, Shard),
    Originals = [xet_hash:from_string(S) || {S, _} <- listing()],
    [#{chunks := Stored, cas_hash := CasHash}] = maps:get(cas, Shard),
    ?assertEqual(
        [xet_hash:keyed_chunk_hash(Key, H) || H <- Originals],
        [maps:get(hash, C) || C <- Stored]
    ),
    ?assertEqual(
        {ok, #{cas_hash => CasHash, chunk_index => 0}},
        xet_dedup:match(Shard, hd(Originals))
    ).

%%--------------------------------------------------------------------
%% Large-fixture cases
%%--------------------------------------------------------------------

reference_chunking_and_hashes(_Config) ->
    require_large(fun() ->
        Data = csv(),
        Listing = listing(),
        Chunks = xet_chunker:split(Data),
        Entries = [{xet_hash:chunk_hash(C), byte_size(C)} || C <- Chunks],
        %% Boundaries + hashes match the listing.
        ?assertEqual(
            Listing,
            [{xet_hash:to_string(H), S} || {H, S} <- Entries]
        ),
        %% File and xorb hashes match the pinned strings.
        ?assertEqual(
            xet_test_vectors:expected_file_hash_string(),
            xet_hash:to_string(xet_hash:file_hash(Entries))
        ),
        ?assertEqual(
            xet_test_vectors:expected_xorb_hash_string(),
            xet_hash:to_string(xet_hash:xorb_hash(Entries))
        )
    end).

%% The hosted .xorb is a bare chunk stream + 4 stray "XETB" bytes (no
%% parseable footer); validate the chunk region and its range hash.
reference_xorb_object(_Config) ->
    require_large(fun() ->
        {ok, Bin} = file:read_file(xet_test_vectors:large_fixture_path(?XORB ".xorb")),
        Region = binary:part(Bin, 0, byte_size(Bin) - 4),
        {ok, Chunks} = xet_xorb:parse_chunk_stream(Region),
        Entries = [{xet_hash:chunk_hash(C), byte_size(C)} || C <- Chunks],
        ?assertEqual(
            [{H, S} || {H, S} <- listing_raw()],
            Entries
        ),
        ?assertEqual(csv(), list_to_binary(Chunks)),
        {ok, RangeHash} = file:read_file(fixture(?XORB ".xorb.range-hash")),
        Trimmed = hd(binary:split(RangeHash, [<<"\n">>], [global, trim_all])),
        ?assertEqual(
            Trimmed,
            xet_hash:to_string(xet_hash:verification_hash([H || {H, _} <- Entries]))
        )
    end).

listing_raw() ->
    [{xet_hash:from_string(S), Sz} || {S, Sz} <- listing()].

%% Our upload-form shard encoder reproduces the reference bytes exactly,
%% matching its choices (bytes_on_disk 0, no eligibility flags set).
reference_upload_shard_byte_identical(_Config) ->
    require_large(fun() ->
        Data = csv(),
        Chunks = xet_chunker:split(Data),
        Entries = [{xet_hash:chunk_hash(C), byte_size(C)} || C <- Chunks],
        XorbHash = xet_hash:xorb_hash(Entries),
        N = length(Entries),
        File = #{
            file_hash => xet_hash:file_hash(Entries),
            terms => [
                #{
                    cas_hash => XorbHash,
                    unpacked_len => byte_size(Data),
                    chunk_start => 0,
                    chunk_end => N
                }
            ],
            verification => [xet_hash:verification_hash([H || {H, _} <- Entries])],
            sha256 => crypto:hash(sha256, Data)
        },
        Cas = #{
            cas_hash => XorbHash,
            bytes_on_disk => 0,
            chunks => [
                #{hash => H, size => S, dedup_eligible => false}
             || {H, S} <- Entries
            ]
        },
        Bin = xet_shard:encode_upload(#{files => [File], cas => [Cas]}),
        {ok, Reference} = file:read_file(fixture(?CSV ".shard.verification-no-footer")),
        ?assertEqual(Reference, Bin)
    end).
