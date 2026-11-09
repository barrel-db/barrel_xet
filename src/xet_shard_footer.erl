%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Stored-shard tail (spec Section 9.6): the three lookup tables sorted by
%% truncated hash, then the 200-byte footer.
-module(xet_shard_footer).

-export([encode/6, decode/1, encode_lookups/2]).

-include("xet_shard.hrl").

-type footer() :: #{
    chunk_hash_key := xet_hash:hash(),
    created_at := non_neg_integer(),
    key_expiry := non_neg_integer(),
    stored_bytes_on_disk := non_neg_integer(),
    materialized_bytes := non_neg_integer(),
    stored_bytes := non_neg_integer()
}.
-export_type([footer/0]).

-spec encode(
    [xet_shard:file_info()],
    [xet_shard:cas_info()],
    non_neg_integer(),
    non_neg_integer(),
    non_neg_integer(),
    map()
) -> iodata().
encode(Files, Cas, FileOffset, CasOffset, LookupStart, Opts) ->
    {FileLookup, CasLookup, ChunkLookup} = encode_lookups(Files, Cas),
    NF = length(Files),
    NC = length(Cas),
    NChunks = lists:sum([length(maps:get(chunks, B)) || B <- Cas]),
    CasLookupOffset = LookupStart + 12 * NF,
    ChunkLookupOffset = CasLookupOffset + 12 * NC,
    FooterOffset = ChunkLookupOffset + 16 * NChunks,
    Footer = <<
        ?SHARD_FOOTER_VERSION:64/little,
        FileOffset:64/little,
        CasOffset:64/little,
        LookupStart:64/little,
        NF:64/little,
        CasLookupOffset:64/little,
        NC:64/little,
        ChunkLookupOffset:64/little,
        NChunks:64/little,
        (maps:get(chunk_hash_key, Opts, xet_hash:zero_hash())):32/binary,
        (maps:get(created_at, Opts, 0)):64/little,
        (maps:get(key_expiry, Opts, 16#FFFFFFFFFFFFFFFF)):64/little,
        0:384,
        (stored_bytes_on_disk(Cas)):64/little,
        (materialized_bytes(Files)):64/little,
        (stored_bytes(Cas)):64/little,
        FooterOffset:64/little
    >>,
    [FileLookup, CasLookup, ChunkLookup, Footer].

%% Lookup tables, each sorted by truncated hash (u64 LE of the first 8
%% hash bytes). Exposed so decode can verify a stored shard's tables.
%%
%% Indices count 48-byte entries from the start of their section, not
%% blocks, so a reader can seek to offset + 48 * index (xet-core,
%% metadata_shard/shard_format.rs: a file block spans its header, terms,
%% verification entries and metadata ext; a CAS block its header and
%% chunks).
-spec encode_lookups([xet_shard:file_info()], [xet_shard:cas_info()]) ->
    {binary(), binary(), binary()}.
encode_lookups(Files, Cas) ->
    FileEntries = [
        {trunc_hash(maps:get(file_hash, F)), I}
     || {I, F} <- entry_indices(Files, fun file_entries/1)
    ],
    CasIndexed = entry_indices(Cas, fun(B) -> 1 + length(maps:get(chunks, B)) end),
    CasEntries = [{trunc_hash(maps:get(cas_hash, B)), I} || {I, B} <- CasIndexed],
    ChunkEntries = lists:append([
        [
            {trunc_hash(maps:get(hash, Chunk)), I, J}
         || {J, Chunk} <- enumerate(maps:get(chunks, B))
        ]
     || {I, B} <- CasIndexed
    ]),
    {
        <<<<T:64/little, I:32/little>> || {T, I} <- lists:sort(FileEntries)>>,
        <<<<T:64/little, I:32/little>> || {T, I} <- lists:sort(CasEntries)>>,
        <<<<T:64/little, I:32/little, J:32/little>> || {T, I, J} <- lists:sort(ChunkEntries)>>
    }.

enumerate(List) ->
    lists:zip(lists:seq(0, length(List) - 1), List).

%% Pair each block with the entry index it starts at.
entry_indices(Blocks, SizeFun) ->
    {Indexed, _} = lists:mapfoldl(fun(B, I) -> {{I, B}, I + SizeFun(B)} end, 0, Blocks),
    Indexed.

file_entries(#{terms := Terms} = File) ->
    N = length(Terms),
    1 + N + optional_entries(verification, File, N) + optional_entries(sha256, File, 1).

optional_entries(Key, Map, Count) ->
    case maps:get(Key, Map, undefined) of
        undefined -> 0;
        _ -> Count
    end.

trunc_hash(<<T:64/little, _/binary>>) -> T.

stored_bytes_on_disk(Cas) ->
    lists:sum([maps:get(bytes_on_disk, B) || B <- Cas]).

stored_bytes(Cas) ->
    lists:sum([lists:sum([maps:get(size, C) || C <- maps:get(chunks, B)]) || B <- Cas]).

materialized_bytes(Files) ->
    lists:sum([
        lists:sum([maps:get(unpacked_len, T) || T <- maps:get(terms, F)])
     || F <- Files
    ]).

%% Parse the stored tail from everything after the 48-byte header.
%% Returns the footer map, the absolute offset where the body (file +
%% CAS sections) ends (= where the lookup tables begin), and the three
%% lookup table entry counts.
-spec decode(binary()) ->
    {ok, footer(), non_neg_integer(), {non_neg_integer(), non_neg_integer(), non_neg_integer()}}
    | {error, atom()}.
decode(Rest) when byte_size(Rest) < ?SHARD_FOOTER_SIZE ->
    {error, truncated};
decode(Rest) ->
    Total = ?SHARD_HEADER_SIZE + byte_size(Rest),
    Footer = binary:part(Rest, byte_size(Rest) - ?SHARD_FOOTER_SIZE, ?SHARD_FOOTER_SIZE),
    case Footer of
        <<?SHARD_FOOTER_VERSION:64/little, FileOffset:64/little, CasOffset:64/little,
            FileLookupOffset:64/little, NF:64/little, CasLookupOffset:64/little, NC:64/little,
            ChunkLookupOffset:64/little, NChunks:64/little, Key:32/binary, Created:64/little,
            Expiry:64/little, _Reserved:48/binary, OnDisk:64/little, Materialized:64/little,
            Stored:64/little, FooterOffset:64/little>> ->
            Offsets =
                {FileOffset, CasOffset, FileLookupOffset, CasLookupOffset, ChunkLookupOffset,
                    FooterOffset},
            Counts = {NF, NC, NChunks},
            Fields = {Key, Created, Expiry, OnDisk, Materialized, Stored},
            checked(Offsets, Counts, Fields, Total);
        _ ->
            {error, bad_footer_version}
    end.

checked(
    {FileOffset, CasOffset, FileLookup, CasLookup, ChunkLookup, FooterOffset} = _Offsets,
    {NF, NC, NChunks} = Counts,
    Fields,
    Total
) when
    FileOffset =:= ?SHARD_HEADER_SIZE,
    CasOffset > FileOffset,
    FileLookup >= CasOffset,
    CasLookup =:= FileLookup + 12 * NF,
    ChunkLookup =:= CasLookup + 12 * NC,
    FooterOffset =:= ChunkLookup + 16 * NChunks,
    FooterOffset =:= Total - ?SHARD_FOOTER_SIZE
->
    {Key, Created, Expiry, OnDisk, Materialized, Stored} = Fields,
    Footer = #{
        chunk_hash_key => Key,
        created_at => Created,
        key_expiry => Expiry,
        stored_bytes_on_disk => OnDisk,
        materialized_bytes => Materialized,
        stored_bytes => Stored
    },
    {ok, Footer, FileLookup, Counts};
checked(_Offsets, _Counts, _Fields, _Total) ->
    {error, bad_footer_offsets}.
