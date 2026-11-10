%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(xet_xorb_tests).

-include_lib("eunit/include/eunit.hrl").

-define(NONCE0, <<0, 0, 0, 0>>).

chunks3() ->
    [
        binary:copy(<<"compress me ">>, 500),
        xet_test_vectors:splitmix64_data(9000, 4),
        <<"tiny">>
    ].

roundtrip_test() ->
    {ok, Enc} = xet_xorb:encode(chunks3(), #{nonce => ?NONCE0}),
    {ok, Dec} = xet_xorb:decode(maps:get(bin, Enc)),
    ?assertEqual(chunks3(), maps:get(chunks, Dec)),
    ?assertEqual(maps:get(hash, Enc), maps:get(hash, Dec)),
    Entries = lists:zip(maps:get(chunk_hashes, Enc), maps:get(unpacked_sizes, Enc)),
    ?assertEqual(xet_hash:xorb_hash(Entries), maps:get(hash, Enc)).

explicit_schemes_test() ->
    lists:foreach(
        fun(Scheme) ->
            {ok, Enc} = xet_xorb:encode(chunks3(), #{compression => Scheme, nonce => ?NONCE0}),
            {ok, Dec} = xet_xorb:decode(maps:get(bin, Enc)),
            ?assertEqual(chunks3(), maps:get(chunks, Dec))
        end,
        [none, lz4, bg4_lz4]
    ).

%% Compression type byte of the first chunk sits at offset 4.
auto_scheme_test() ->
    Text = binary:copy(<<"all work and no play makes jack a dull boy. ">>, 200),
    {ok, E1} = xet_xorb:encode([Text], #{nonce => ?NONCE0}),
    ?assertEqual(1, binary:at(maps:get(bin, E1), 4)),
    {ok, E2} = xet_xorb:encode([skewed_chunk()], #{nonce => ?NONCE0}),
    ?assertEqual(2, binary:at(maps:get(bin, E2), 4)),
    Random = xet_test_vectors:splitmix64_data(8192, 21),
    {ok, E3} = xet_xorb:encode([Random], #{nonce => ?NONCE0}),
    ?assertEqual(0, binary:at(maps:get(bin, E3), 4)).

%% Same input, same nonce: identical bytes. Different nonce: different
%% bytes, same hash, both decode.
determinism_and_nonce_test() ->
    {ok, E1} = xet_xorb:encode(chunks3(), #{nonce => ?NONCE0}),
    {ok, E2} = xet_xorb:encode(chunks3(), #{nonce => ?NONCE0}),
    ?assertEqual(maps:get(bin, E1), maps:get(bin, E2)),
    {ok, E3} = xet_xorb:encode(chunks3(), #{nonce => <<1, 2, 3, 4>>}),
    ?assertNotEqual(maps:get(bin, E1), maps:get(bin, E3)),
    ?assertEqual(maps:get(hash, E1), maps:get(hash, E3)),
    ?assertMatch({ok, _}, xet_xorb:decode(maps:get(bin, E3))).

limits_test() ->
    ?assertEqual({error, empty_xorb}, xet_xorb:encode([])),
    ?assertEqual({error, bad_chunk_size}, xet_xorb:encode([<<>>])),
    ?assertEqual({error, bad_chunk_size}, xet_xorb:encode([binary:copy(<<1>>, 131073)])),
    ?assertEqual(
        {error, too_many_chunks},
        xet_xorb:encode(lists:duplicate(8193, <<1>>))
    ),
    Big = binary:copy(<<7>>, 8193),
    ?assertEqual(
        {error, xorb_too_large},
        xet_xorb:encode(lists:duplicate(8192, Big))
    ).

tamper_test() ->
    {ok, Enc} = xet_xorb:encode(chunks3(), #{nonce => ?NONCE0}),
    Bin = maps:get(bin, Enc),
    %% Payload byte.
    ?assertMatch({error, _}, xet_xorb:decode(flip(Bin, 20))),
    %% Chunk header version byte.
    ?assertEqual({error, bad_chunk_version}, xet_xorb:decode(flip(Bin, 0))),
    %% Truncation.
    ?assertMatch({error, _}, xet_xorb:decode(binary:part(Bin, 0, byte_size(Bin) - 3))),
    %% Reserved footer bytes must be zero.
    ?assertEqual({error, reserved_not_zero}, xet_xorb:decode(flip(Bin, byte_size(Bin) - 10))),
    %% Unknown compression type.
    Patched = patch(Bin, 4, 3),
    ?assertEqual({error, {unknown_compression, 3}}, xet_xorb:decode(Patched)).

%% Spec 7.1 on decode: limits are enforced on hand-assembled streams,
%% since encode never produces them.
decode_limits_test() ->
    Tiny = <<<<0, 1:24/little, 0, 1:24/little, 7>> || _ <- lists:seq(1, 8193)>>,
    ?assertEqual({error, too_many_chunks}, xet_xorb:decode_any(Tiny)),
    Zeros = xet_nif:lz4f_compress(<<0:(131072 * 8)>>),
    Header = <<0, (byte_size(Zeros)):24/little, 1, 131072:24/little>>,
    Inflating = binary:copy(<<Header/binary, Zeros/binary>>, 513),
    ?assertEqual({error, xorb_too_large}, xet_xorb:decode_any(Inflating)),
    ?assertEqual({error, empty_xorb}, xet_xorb:decode_any(<<>>)),
    {ok, Enc} = xet_xorb:encode(chunks3(), #{nonce => ?NONCE0}),
    Bin = maps:get(bin, Enc),
    NPos = byte_size(Bin) - 4 - 28,
    <<Before:NPos/binary, _:32, After/binary>> = Bin,
    ?assertEqual(
        {error, too_many_chunks}, xet_xorb:decode(<<Before/binary, 8193:32/little, After/binary>>)
    ),
    ?assertEqual(
        {error, empty_xorb}, xet_xorb:decode(<<Before/binary, 0:32/little, After/binary>>)
    ).

%% Spec 7.3.2 size rules on hand-built chunk headers.
chunk_header_rejects_test() ->
    Hdr = fun(Comp, Type, USize) -> <<0, Comp:24/little, Type, USize:24/little>> end,
    Bad = [
        %% uncompressed_size 0, and above 128 KiB
        <<(Hdr(1, 0, 0))/binary, 7>>,
        <<(Hdr(1, 0, 131073))/binary, 7>>,
        %% compressed_size 0, above 128 KiB, and above the remaining bytes
        Hdr(0, 0, 1),
        <<(Hdr(131073, 0, 131073))/binary, 0:(131073 * 8)>>,
        <<(Hdr(5, 0, 5))/binary, 1, 2>>,
        %% type 0 (none) with compressed =/= uncompressed
        <<(Hdr(2, 0, 3))/binary, 1, 2>>
    ],
    [?assertEqual({error, bad_chunk_size}, xet_xorb:parse_chunk_stream(B)) || B <- Bad].

%% Spec 7.5: unknown idents or versions and inconsistent num_chunks are
%% rejected.
footer_rejects_test() ->
    {ok, Enc} = xet_xorb:encode(chunks3(), #{nonce => ?NONCE0}),
    Bin = maps:get(bin, Enc),
    Size = byte_size(Bin),
    <<_:(Size - 4)/binary, InfoLen:32/little>> = Bin,
    F = Size - 4 - InfoLen,
    %% 3 chunks: hash section at F+40, boundary section at F+40+12+96.
    B = F + 40 + 12 + 3 * 32,
    ?assertEqual({error, bad_footer}, xet_xorb:decode(flip(Bin, F))),
    ?assertEqual({error, bad_footer_version}, xet_xorb:decode(patch(Bin, F + 7, 2))),
    %% Hash section: ident, version (MUST be 0), num_chunks.
    ?assertEqual({error, bad_footer}, xet_xorb:decode(flip(Bin, F + 40))),
    ?assertEqual({error, bad_footer}, xet_xorb:decode(patch(Bin, F + 47, 1))),
    ?assertEqual({error, bad_footer}, xet_xorb:decode(patch(Bin, F + 48, 4))),
    %% Boundary section: ident, version (MUST be 1), num_chunks.
    ?assertEqual({error, bad_footer}, xet_xorb:decode(flip(Bin, B))),
    ?assertEqual({error, bad_footer}, xet_xorb:decode(patch(Bin, B + 7, 0))),
    ?assertEqual({error, bad_footer}, xet_xorb:decode(patch(Bin, B + 8, 4))).

%% A footer whose boundary points past the chunk data is refused, not
%% sliced into footer bytes.
extract_range_untrusted_footer_test() ->
    Chunks = [xet_test_vectors:splitmix64_data(1000 + I, I) || I <- lists:seq(1, 10)],
    {ok, Enc} = xet_xorb:encode(Chunks, #{nonce => ?NONCE0}),
    Bin = maps:get(bin, Enc),
    LastBoundary = byte_size(Bin) - 4 - 28 - 10 * 4 - 4,
    <<Before:LastBoundary/binary, _:32, After/binary>> = Bin,
    Bad = <<Before/binary, 16#7FFFFFFF:32/little, After/binary>>,
    ?assertEqual({error, bad_range}, xet_xorb:extract_range(Bad, 9, 10)).

extract_range_test() ->
    Chunks = [xet_test_vectors:splitmix64_data(1000 + I, I) || I <- lists:seq(1, 10)],
    {ok, Enc} = xet_xorb:encode(Chunks, #{nonce => ?NONCE0}),
    Bin = maps:get(bin, Enc),
    {ok, Middle} = xet_xorb:extract_range(Bin, 3, 7),
    ?assertEqual(lists:sublist(Chunks, 4, 4), Middle),
    {ok, All} = xet_xorb:extract_range(Bin, 0, 10),
    ?assertEqual(Chunks, All),
    ?assertEqual({error, bad_range}, xet_xorb:extract_range(Bin, 4, 3)),
    ?assertEqual({error, bad_range}, xet_xorb:extract_range(Bin, 0, 11)).

%% Reference xorb: full decode, hash equality, chunk listing equality,
%% content equality with the source CSV, and the range hash.
reference_xorb_test_() ->
    case xet_test_vectors:have_large_fixtures() of
        false -> {"large fixtures absent, skipped", []};
        true -> {timeout, 300, fun reference_xorb_check/0}
    end.

%% Upstream quirk, pinned here on purpose: the hosted reference .xorb is
%% the bare chunk stream followed by the 4 bytes "XETB" (the start of a
%% CasObjectInfo ident, nothing more). It carries no parseable footer, so
%% the strict decode must reject it and the chunk region is validated
%% directly. If the dataset is ever fixed, the tail assertion fails and
%% this test should switch to xet_xorb:decode/1.
reference_xorb_check() ->
    Name = "eea25d6ee393ccae385820daed127b96ef0ea034dfb7cf6da3a950ce334b7632",
    {ok, Bin} = file:read_file(xet_test_vectors:large_fixture_path(Name ++ ".xorb")),
    ?assertMatch({error, _}, xet_xorb:decode(Bin)),
    Tail = binary:part(Bin, byte_size(Bin) - 4, 4),
    ?assertEqual(<<"XETB">>, Tail),
    Region = binary:part(Bin, 0, byte_size(Bin) - 4),
    {ok, Chunks} = xet_xorb:parse_chunk_stream(Region),
    Entries = [{xet_hash:chunk_hash(C), byte_size(C)} || C <- Chunks],
    ?assertEqual(
        xet_test_vectors:expected_xorb_hash_string(),
        xet_hash:to_string(xet_hash:xorb_hash(Entries))
    ),
    Listing = xet_test_vectors:parse_chunks_file(
        xet_test_vectors:fixture_path(Name ++ ".xorb.chunks")
    ),
    Got = [{xet_hash:to_string(H), S} || {H, S} <- Entries],
    ?assertEqual(Listing, Got),
    {ok, Csv} = file:read_file(
        xet_test_vectors:large_fixture_path("Electric_Vehicle_Population_Data_20250917.csv")
    ),
    ?assertEqual(Csv, list_to_binary(Chunks)),
    {ok, RangeHash} = file:read_file(xet_test_vectors:fixture_path(Name ++ ".xorb.range-hash")),
    Trimmed = hd(binary:split(RangeHash, [<<"\n">>], [global, trim_all])),
    ?assertEqual(
        Trimmed,
        xet_hash:to_string(xet_hash:verification_hash([H || {H, _} <- Entries]))
    ).

%% One byte class pinned near popcount 8 (with every bin represented so
%% the predictor doesn't skip it), three classes random: recommends BG4.
skewed_chunk() ->
    Fillers = <<16#00, 16#01, 16#03, 16#07, 16#0F, 16#1F, 16#3F, 16#7F>>,
    Rnd = xet_test_vectors:splitmix64_data(3 * 8192, 99),
    list_to_binary([
        begin
            C0 =
                case I < 8 of
                    true -> binary:at(Fillers, I);
                    false -> 16#FF
                end,
            <<C0, (binary:at(Rnd, 3 * I)), (binary:at(Rnd, 3 * I + 1)),
                (binary:at(Rnd, 3 * I + 2))>>
        end
     || I <- lists:seq(0, 8191)
    ]).

flip(Bin, Pos) ->
    patch(Bin, Pos, binary:at(Bin, Pos) bxor 16#FF).

patch(Bin, Pos, Value) ->
    <<Before:Pos/binary, _, After/binary>> = Bin,
    <<Before/binary, Value, After/binary>>.
