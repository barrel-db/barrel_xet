%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(prop_xet_lz4).

-include_lib("proper/include/proper.hrl").

%% Any binary round-trips through a complete LZ4 frame.
prop_roundtrip() ->
    ?FORALL(
        Data,
        binary(),
        begin
            Frame = xet_nif:lz4f_compress(Data),
            {ok, Data} =:= xet_nif:lz4f_decompress(Frame, max(byte_size(Data), 1))
        end
    ).

%% Chunk-sized payloads (up to MAX_CHUNK_SIZE) round-trip under the cap the
%% xorb decoder will use.
prop_roundtrip_chunk_sized() ->
    ?FORALL(
        Data,
        resize(131072, binary()),
        {ok, Data} =:= xet_nif:lz4f_decompress(xet_nif:lz4f_compress(Data), 131072)
    ).

%% Truncating a frame anywhere strictly inside it never yields ok with the
%% original data AND never crashes: it reports an error (or, for cuts that
%% land exactly on a block boundary before the end mark, truncated).
prop_truncation_detected() ->
    ?FORALL(
        {Data, Cut},
        ?LET(
            D,
            non_empty(binary()),
            {D, integer(4, byte_size(xet_nif:lz4f_compress(D)) - 1)}
        ),
        begin
            Frame = xet_nif:lz4f_compress(Data),
            case xet_nif:lz4f_decompress(binary:part(Frame, 0, Cut), byte_size(Data) + 64) of
                {error, _} -> true;
                {ok, Other} -> Other =/= Data
            end
        end
    ).
