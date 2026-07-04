%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Xorb container codec (spec Section 7): serialize chunks with per-chunk
%% compression, decode with the full set of 7.3.2 validation MUSTs.
%%
%% encode/2 compression option:
%%   auto (default): per 32-chunk window, the BG4 predictor picks between
%%   lz4 and bg4_lz4 on the window's first chunk (xet-core behavior);
%%   every chunk falls back to raw storage when compression does not
%%   shrink it, which also keeps compressed_size <= MAX_CHUNK_SIZE.
-module(xet_xorb).

-export([encode/1, encode/2, decode/1, decode_any/1, parse_chunk_stream/1, extract_range/3]).
-export([chunk_byte_range/2]).

-define(MAX_XORB_SIZE, 67108864).
-define(MAX_XORB_CHUNKS, 8192).
-define(MAX_CHUNK_SIZE, 131072).
-define(RETEST_INTERVAL, 32).

-type encoded() :: #{
    bin := binary(),
    hash := xet_hash:hash(),
    chunk_hashes := [xet_hash:hash()],
    unpacked_sizes := [pos_integer()],
    boundary_offsets := [pos_integer()],
    unpacked_offsets := [pos_integer()],
    bytes_on_disk := pos_integer(),
    total_unpacked := pos_integer()
}.
-type decoded() :: #{
    chunks := [binary()],
    hash := xet_hash:hash(),
    chunk_hashes := [xet_hash:hash()],
    boundary_offsets := [pos_integer()],
    unpacked_offsets := [pos_integer()],
    bytes_on_disk := pos_integer(),
    total_unpacked := non_neg_integer()
}.
-export_type([encoded/0, decoded/0]).

-spec encode([binary()]) -> {ok, encoded()} | {error, atom()}.
encode(Chunks) ->
    encode(Chunks, #{}).

-spec encode([binary()], map()) -> {ok, encoded()} | {error, atom()}.
encode([], _Opts) ->
    {error, empty_xorb};
encode(Chunks, _Opts) when length(Chunks) > ?MAX_XORB_CHUNKS ->
    {error, too_many_chunks};
encode(Chunks, Opts) ->
    case check_chunk_sizes(Chunks, 0) of
        ok ->
            Schemes = schemes(Chunks, maps:get(compression, Opts, auto)),
            Nonce = maps:get(nonce, Opts, crypto:strong_rand_bytes(4)),
            build(Chunks, Schemes, Nonce);
        Error ->
            Error
    end.

check_chunk_sizes([], Total) when Total =< ?MAX_XORB_SIZE ->
    ok;
check_chunk_sizes([], _Total) ->
    {error, xorb_too_large};
check_chunk_sizes([C | Rest], Total) when
    is_binary(C), byte_size(C) >= 1, byte_size(C) =< ?MAX_CHUNK_SIZE
->
    check_chunk_sizes(Rest, Total + byte_size(C));
check_chunk_sizes(_, _) ->
    {error, bad_chunk_size}.

%% One scheme per chunk. Fixed schemes apply uniformly; auto re-runs the
%% predictor on the first chunk of every 32-chunk window.
schemes(Chunks, auto) ->
    windows(Chunks);
schemes(Chunks, Scheme) when Scheme =:= none; Scheme =:= lz4; Scheme =:= bg4_lz4 ->
    [Scheme || _ <- Chunks].

windows([]) ->
    [];
windows(Chunks) ->
    {Window, Rest} = split_at(Chunks, ?RETEST_INTERVAL),
    Scheme = xet_bg4:predict(hd(Window)),
    [Scheme || _ <- Window] ++ windows(Rest).

split_at(List, N) when length(List) =< N -> {List, []};
split_at(List, N) -> lists:split(N, List).

build(Chunks, Schemes, Nonce) ->
    Acc0 = {[], [], [], [], []},
    {Entries, Hashes, Sizes, Boundaries, Unpacked} =
        lists:foldl(fun add_chunk/2, Acc0, lists:zip(Chunks, Schemes)),
    finish_encode(
        lists:reverse(Entries),
        lists:reverse(Hashes),
        lists:reverse(Sizes),
        lists:reverse(Boundaries),
        lists:reverse(Unpacked),
        Nonce
    ).

add_chunk({Chunk, Scheme}, {Es, Hs, Ss, Bs, Us}) ->
    {Type, Payload} = compress_chunk(Chunk, Scheme),
    Size = byte_size(Chunk),
    Entry = [<<0, (iolist_size(Payload)):24/little, Type, Size:24/little>>, Payload],
    BOff = boundary_acc(Bs) + 8 + iolist_size(Payload),
    UOff = boundary_acc(Us) + Size,
    {[Entry | Es], [xet_hash:chunk_hash(Chunk) | Hs], [Size | Ss], [BOff | Bs], [UOff | Us]}.

finish_encode(Entries, ChunkHashes, UnpackedSizes, Boundaries, Unpacked, Nonce) ->
    XorbHash = xet_hash:xorb_hash(lists:zip(ChunkHashes, UnpackedSizes)),
    Tail = xet_xorb_footer:encode(XorbHash, ChunkHashes, Boundaries, Unpacked, Nonce),
    Bin = iolist_to_binary([Entries, Tail]),
    {ok, #{
        bin => Bin,
        hash => XorbHash,
        chunk_hashes => ChunkHashes,
        unpacked_sizes => UnpackedSizes,
        boundary_offsets => Boundaries,
        unpacked_offsets => Unpacked,
        bytes_on_disk => byte_size(Bin),
        total_unpacked => lists:sum(UnpackedSizes)
    }}.

boundary_acc([]) -> 0;
boundary_acc([Last | _]) -> Last.

compress_chunk(Chunk, none) ->
    {0, Chunk};
compress_chunk(Chunk, lz4) ->
    smaller_or_raw(Chunk, 1, xet_nif:lz4f_compress(Chunk));
compress_chunk(Chunk, bg4_lz4) ->
    smaller_or_raw(Chunk, 2, xet_nif:lz4f_compress(xet_bg4:group(Chunk))).

smaller_or_raw(Chunk, Type, Compressed) when byte_size(Compressed) < byte_size(Chunk) ->
    {Type, Compressed};
smaller_or_raw(Chunk, _Type, _Compressed) ->
    {0, Chunk}.

%% Full strict decode: footer consistency, every 7.3.2 rule, recomputed
%% chunk hashes and xorb hash.
-spec decode(binary()) -> {ok, decoded()} | {error, term()}.
decode(Bin) ->
    case xet_xorb_footer:decode(Bin) of
        {ok, Info} -> decode_chunks(Bin, Info);
        {error, _} = Error -> Error
    end.

decode_chunks(Bin, Info) ->
    #{
        hash := XorbHash,
        chunk_hashes := ChunkHashes,
        boundary_offsets := Boundaries,
        unpacked_offsets := Unpacked,
        data_size := DataSize
    } = Info,
    Region = binary:part(Bin, 0, DataSize),
    case parse_chunk_stream(Region) of
        {ok, Chunks} ->
            verify(Bin, Chunks, XorbHash, ChunkHashes, Boundaries, Unpacked, Region);
        {error, _} = Error ->
            Error
    end.

verify(Bin, Chunks, XorbHash, ChunkHashes, Boundaries, Unpacked, Region) ->
    Computed = [xet_hash:chunk_hash(C) || C <- Chunks],
    Sizes = [byte_size(C) || C <- Chunks],
    Checks = [
        {count_mismatch, length(Chunks) =:= length(ChunkHashes)},
        {chunk_hash_mismatch, Computed =:= ChunkHashes},
        {unpacked_mismatch, cumulative(Sizes) =:= Unpacked},
        {boundary_mismatch, actual_boundaries(Region) =:= Boundaries},
        {xorb_hash_mismatch, xet_hash:xorb_hash(lists:zip(Computed, Sizes)) =:= XorbHash}
    ],
    case [Reason || {Reason, false} <- Checks] of
        [] ->
            {ok, #{
                chunks => Chunks,
                hash => XorbHash,
                chunk_hashes => ChunkHashes,
                boundary_offsets => Boundaries,
                unpacked_offsets => Unpacked,
                bytes_on_disk => byte_size(Bin),
                total_unpacked => lists:sum(Sizes)
            }};
        [Reason | _] ->
            {error, Reason}
    end.

cumulative(Sizes) ->
    {Offsets, _} = lists:mapfoldl(fun(S, Acc) -> {Acc + S, Acc + S} end, 0, Sizes),
    Offsets.

actual_boundaries(Region) ->
    boundaries_loop(Region, 0, []).

boundaries_loop(<<>>, _Pos, Acc) ->
    lists:reverse(Acc);
boundaries_loop(<<0, CompSize:24/little, _Type, _USize:24/little, Rest/binary>>, Pos, Acc) ->
    <<_:CompSize/binary, Next/binary>> = Rest,
    End = Pos + 8 + CompSize,
    boundaries_loop(Next, End, [End | Acc]).

%% Accept either serialized form on the upload path: a full xorb with a
%% CasObjectInfo footer (validated strictly) or a bare chunk stream
%% (xet-core's serialize_footer is optional), for which the layout is
%% recomputed from the chunks themselves.
-spec decode_any(binary()) -> {ok, decoded()} | {error, term()}.
decode_any(Bin) ->
    case xet_xorb_footer:decode(Bin) of
        {ok, _} ->
            decode(Bin);
        {error, _} ->
            decode_bare(Bin)
    end.

decode_bare(Bin) ->
    case parse_chunk_stream(Bin) of
        {ok, Chunks} ->
            Computed = [xet_hash:chunk_hash(C) || C <- Chunks],
            Sizes = [byte_size(C) || C <- Chunks],
            {ok, #{
                chunks => Chunks,
                hash => xet_hash:xorb_hash(lists:zip(Computed, Sizes)),
                chunk_hashes => Computed,
                boundary_offsets => actual_boundaries(Bin),
                unpacked_offsets => cumulative(Sizes),
                bytes_on_disk => byte_size(Bin),
                total_unpacked => lists:sum(Sizes)
            }};
        {error, _} = Error ->
            Error
    end.

%% Parse and decompress a bare chunk stream (headers + payloads, no
%% footer), as downloaded from a fetch URL byte range.
-spec parse_chunk_stream(binary()) -> {ok, [binary()]} | {error, term()}.
parse_chunk_stream(Bin) ->
    parse_chunks(Bin, []).

parse_chunks(<<>>, Acc) ->
    {ok, lists:reverse(Acc)};
parse_chunks(<<0, CompSize:24/little, Type, USize:24/little, Rest/binary>>, Acc) when
    USize >= 1,
    USize =< ?MAX_CHUNK_SIZE,
    CompSize >= 1,
    CompSize =< ?MAX_CHUNK_SIZE,
    CompSize =< byte_size(Rest)
->
    <<Payload:CompSize/binary, Next/binary>> = Rest,
    case decompress_chunk(Type, Payload, USize) of
        {ok, Data} -> parse_chunks(Next, [Data | Acc]);
        {error, _} = Error -> Error
    end;
parse_chunks(<<0, _CompSize:24/little, _Type, _USize:24/little, _/binary>>, _Acc) ->
    {error, bad_chunk_size};
parse_chunks(<<Version, _/binary>>, _Acc) when Version =/= 0 ->
    {error, bad_chunk_version};
parse_chunks(_, _Acc) ->
    {error, truncated}.

decompress_chunk(0, Payload, USize) when byte_size(Payload) =:= USize ->
    {ok, Payload};
decompress_chunk(0, _Payload, _USize) ->
    {error, bad_chunk_size};
decompress_chunk(1, Payload, USize) ->
    exact_size(xet_nif:lz4f_decompress(Payload, USize), USize);
decompress_chunk(2, Payload, USize) ->
    case exact_size(xet_nif:lz4f_decompress(Payload, USize), USize) of
        {ok, Grouped} -> {ok, xet_bg4:ungroup(Grouped, USize)};
        {error, _} = Error -> Error
    end;
decompress_chunk(Type, _Payload, _USize) ->
    {error, {unknown_compression, Type}}.

exact_size({ok, Data}, USize) when byte_size(Data) =:= USize ->
    {ok, Data};
exact_size({ok, _Data}, _USize) ->
    {error, bad_chunk_size};
exact_size({error, Reason}, _USize) ->
    {error, {decompress, Reason}}.

%% Decompressed chunks [Start, End) of a full serialized xorb, located
%% through the footer's boundary offsets.
-spec extract_range(binary(), non_neg_integer(), pos_integer()) ->
    {ok, [binary()]} | {error, term()}.
extract_range(Bin, Start, End) ->
    case xet_xorb_footer:decode(Bin) of
        {ok, #{boundary_offsets := Boundaries}} when
            Start >= 0, End > Start, End =< length(Boundaries)
        ->
            {ByteStart, ByteEnd} = chunk_byte_range(Boundaries, {Start, End}),
            parse_chunk_stream(binary:part(Bin, ByteStart, ByteEnd - ByteStart));
        {ok, _} ->
            {error, bad_range};
        {error, _} = Error ->
            Error
    end.

%% Serialized byte span (end-exclusive) covering chunk indices [Start, End),
%% given the footer's serialized end offsets.
-spec chunk_byte_range([pos_integer()], {non_neg_integer(), pos_integer()}) ->
    {non_neg_integer(), pos_integer()}.
chunk_byte_range(Boundaries, {0, End}) ->
    {0, lists:nth(End, Boundaries)};
chunk_byte_range(Boundaries, {Start, End}) ->
    {lists:nth(Start, Boundaries), lists:nth(End, Boundaries)}.
