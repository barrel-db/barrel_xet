%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% CasObjectInfo footer codec (spec Section 7.5).
%%
%% Layout: main header ("XETBLOB", version 1, xorb hash), hash section
%% ("XBLBHSH", version 0, chunk hashes), boundary section ("XBLBBND",
%% version 1, serialized end offsets then unpacked end offsets), 28-byte
%% trailer (num_chunks, section offsets measured back from the footer
%% end, 16-byte buffer whose first 4 bytes are an ignorable nonce), then
%% a 4-byte little-endian length of the footer itself.
-module(xet_xorb_footer).

-export([encode/5, decode/1]).

-define(MAIN_IDENT, <<"XETBLOB">>).
-define(HASH_IDENT, <<"XBLBHSH">>).
-define(BOUNDARY_IDENT, <<"XBLBBND">>).
-define(TRAILER_SIZE, 28).
-define(MAX_XORB_CHUNKS, 8192).

-type info() :: #{
    hash := xet_hash:hash(),
    chunk_hashes := [xet_hash:hash()],
    boundary_offsets := [non_neg_integer()],
    unpacked_offsets := [non_neg_integer()],
    data_size := non_neg_integer()
}.
-export_type([info/0]).

%% Returns the full tail of a serialized xorb: footer plus length field.
-spec encode(
    xet_hash:hash(), [xet_hash:hash()], [non_neg_integer()], [non_neg_integer()], binary()
) ->
    iodata().
encode(XorbHash, ChunkHashes, BoundaryOffsets, UnpackedOffsets, Nonce) when
    byte_size(Nonce) =:= 4
->
    N = length(ChunkHashes),
    Main = [?MAIN_IDENT, 1, XorbHash],
    HashSection = [?HASH_IDENT, 0, <<N:32/little>>, ChunkHashes],
    BoundarySection = [
        ?BOUNDARY_IDENT,
        1,
        <<N:32/little>>,
        [<<Off:32/little>> || Off <- BoundaryOffsets],
        [<<Off:32/little>> || Off <- UnpackedOffsets]
    ],
    HashStart = iolist_size(Main),
    BoundaryStart = HashStart + iolist_size(HashSection),
    FooterLen = BoundaryStart + iolist_size(BoundarySection) + ?TRAILER_SIZE,
    Trailer = [
        <<N:32/little, (FooterLen - HashStart):32/little, (FooterLen - BoundaryStart):32/little>>,
        Nonce,
        <<0:96>>
    ],
    [Main, HashSection, BoundarySection, Trailer, <<FooterLen:32/little>>].

%% Strict parse from the end of a full serialized xorb.
-spec decode(binary()) -> {ok, info()} | {error, atom()}.
decode(Bin) when byte_size(Bin) < 4 + 40 + ?TRAILER_SIZE ->
    {error, truncated};
decode(Bin) ->
    Total = byte_size(Bin),
    <<_:(Total - 4)/binary, InfoLen:32/little>> = Bin,
    case InfoLen >= 40 + ?TRAILER_SIZE andalso InfoLen =< Total - 4 of
        true ->
            Footer = binary:part(Bin, Total - 4 - InfoLen, InfoLen),
            decode_footer(Footer, Total - 4 - InfoLen);
        false ->
            {error, bad_footer}
    end.

decode_footer(<<"XETBLOB", 1, XorbHash:32/binary, _/binary>> = Footer, DataSize) ->
    FooterLen = byte_size(Footer),
    Trailer = binary:part(Footer, FooterLen - ?TRAILER_SIZE, ?TRAILER_SIZE),
    <<N:32/little, HashOff:32/little, BoundaryOff:32/little, _Nonce:4/binary, Reserved:12/binary>> =
        Trailer,
    case Reserved of
        _ when N =:= 0 ->
            {error, empty_xorb};
        _ when N > ?MAX_XORB_CHUNKS ->
            {error, too_many_chunks};
        <<0:96>> ->
            sections(Footer, DataSize, XorbHash, N, FooterLen - HashOff, FooterLen - BoundaryOff);
        _ ->
            {error, reserved_not_zero}
    end;
decode_footer(<<"XETBLOB", _, _/binary>>, _DataSize) ->
    {error, bad_footer_version};
decode_footer(_, _DataSize) ->
    {error, bad_footer}.

%% The hash section directly follows the 40-byte main header (7.5 exact
%% field order).
sections(Footer, DataSize, XorbHash, N, HashStart, BoundaryStart) when
    HashStart =:= 40,
    BoundaryStart > HashStart,
    BoundaryStart < byte_size(Footer),
    HashStart + 12 + N * 32 =:= BoundaryStart,
    BoundaryStart + 12 + N * 8 + ?TRAILER_SIZE =:= byte_size(Footer)
->
    HashBytes = N * 32,
    OffBytes = N * 4,
    case Footer of
        <<_:HashStart/binary, "XBLBHSH", 0, N:32/little, Hashes:HashBytes/binary, "XBLBBND", 1,
            N:32/little, Boundaries:OffBytes/binary, Unpacked:OffBytes/binary,
            _:?TRAILER_SIZE/binary>> ->
            {ok, #{
                hash => XorbHash,
                chunk_hashes => [H || <<H:32/binary>> <= Hashes],
                boundary_offsets => [Off || <<Off:32/little>> <= Boundaries],
                unpacked_offsets => [Off || <<Off:32/little>> <= Unpacked],
                data_size => DataSize
            }};
        _ ->
            {error, bad_footer}
    end;
sections(_, _, _, _, _, _) ->
    {error, bad_footer}.
