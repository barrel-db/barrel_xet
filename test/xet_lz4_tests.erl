%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(xet_lz4_tests).

-include_lib("eunit/include/eunit.hrl").

-define(MAX_CHUNK, 131072).

roundtrip_empty_test() ->
    Frame = xet_nif:lz4f_compress(<<>>),
    ?assertEqual({ok, <<>>}, xet_nif:lz4f_decompress(Frame, ?MAX_CHUNK)).

roundtrip_small_test() ->
    Data = <<"hello xet, hello xet, hello xet">>,
    Frame = xet_nif:lz4f_compress(Data),
    ?assertEqual({ok, Data}, xet_nif:lz4f_decompress(Frame, ?MAX_CHUNK)).

roundtrip_compressible_test() ->
    %% Repetitive data must shrink and round-trip.
    Data = binary:copy(<<"abcdefgh">>, 16384),
    Frame = xet_nif:lz4f_compress(Data),
    ?assert(byte_size(Frame) < byte_size(Data)),
    ?assertEqual({ok, Data}, xet_nif:lz4f_decompress(Frame, byte_size(Data))).

roundtrip_incompressible_test() ->
    %% High-entropy input round-trips even when the frame is larger.
    Data = xet_test_vectors:splitmix64_data(100000, 42),
    Frame = xet_nif:lz4f_compress(Data),
    ?assertEqual({ok, Data}, xet_nif:lz4f_decompress(Frame, byte_size(Data))).

roundtrip_large_dirty_test() ->
    %% Above the dirty-scheduler threshold on both directions.
    Data = binary:copy(xet_test_vectors:splitmix64_data(65536, 7), 16),
    Frame = xet_nif:lz4f_compress(Data),
    ?assertEqual({ok, Data}, xet_nif:lz4f_decompress(Frame, byte_size(Data))).

iodata_test() ->
    Flat = <<"iodata comes in parts sometimes">>,
    Nested = [<<"iodata ">>, [<<"comes in ">>, <<"parts">>], <<" sometimes">>],
    ?assertEqual(xet_nif:lz4f_compress(Flat), xet_nif:lz4f_compress(Nested)).

output_cap_test() ->
    Data = binary:copy(<<"x">>, 200000),
    Frame = xet_nif:lz4f_compress(Data),
    ?assertEqual({error, too_large}, xet_nif:lz4f_decompress(Frame, 100000)),
    ?assertEqual({ok, Data}, xet_nif:lz4f_decompress(Frame, 200000)).

truncated_test() ->
    Data = binary:copy(<<"truncate me ">>, 4096),
    Frame = xet_nif:lz4f_compress(Data),
    Cut = binary:part(Frame, 0, byte_size(Frame) - 7),
    ?assertEqual({error, truncated}, xet_nif:lz4f_decompress(Cut, ?MAX_CHUNK)).

corrupt_magic_test() ->
    Frame = xet_nif:lz4f_compress(<<"data">>),
    Bad = <<255, 255, 255, 255, (binary:part(Frame, 4, byte_size(Frame) - 4))/binary>>,
    ?assertEqual({error, corrupt}, xet_nif:lz4f_decompress(Bad, ?MAX_CHUNK)).

garbage_test() ->
    ?assertMatch(
        {error, _},
        xet_nif:lz4f_decompress(xet_test_vectors:splitmix64_data(256, 1), ?MAX_CHUNK)
    ).

trailing_data_test() ->
    Frame = xet_nif:lz4f_compress(<<"payload">>),
    ?assertEqual(
        {error, trailing_data},
        xet_nif:lz4f_decompress(<<Frame/binary, "extra">>, ?MAX_CHUNK)
    ).

%% Interop: decompress a frame produced by the lz4 CLI when available.
cli_interop_test_() ->
    case os:find_executable("lz4") of
        false ->
            [];
        _Lz4 ->
            [fun cli_interop/0]
    end.

cli_interop() ->
    Dir = filename:join(xet_test_vectors:fixtures_dir(), "../.."),
    In = filename:join(Dir, "_build/lz4_interop_in.bin"),
    Out = filename:join(Dir, "_build/lz4_interop_out.lz4"),
    Data = binary:copy(<<"interop payload! ">>, 1000),
    ok = file:write_file(In, Data),
    _ = os:cmd("lz4 -f -q " ++ In ++ " " ++ Out),
    {ok, Frame} = file:read_file(Out),
    ?assertEqual({ok, Data}, xet_nif:lz4f_decompress(Frame, byte_size(Data) + 1)),
    file:delete(In),
    file:delete(Out),
    ok.
