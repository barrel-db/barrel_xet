-module(xet_chunker_tests).

-include_lib("eunit/include/eunit.hrl").

%% zig-xet golden vector: 1 MB of splitmix64(seed 0) data, both the NIF
%% path and the pure reference.
golden_random_1mb_test_() ->
    {timeout, 120, fun() ->
        Data = xet_test_vectors:splitmix64_data(1000000, 0),
        Expected = xet_test_vectors:chunker_boundaries_random_1mb(),
        ?assertEqual(Expected, xet_chunker:chunk_boundaries(Data)),
        ?assertEqual(Expected, xet_chunker_ref:chunk_boundaries(Data))
    end}.

%% Constant bytes never match the mask: cuts land exactly at
%% MAX_CHUNK_SIZE multiples.
golden_const59_1mb_test_() ->
    {timeout, 120, fun() ->
        Data = binary:copy(<<59>>, 1000000),
        Expected = xet_test_vectors:chunker_boundaries_const59_1mb(),
        ?assertEqual(Expected, xet_chunker:chunk_boundaries(Data)),
        ?assertEqual(Expected, xet_chunker_ref:chunk_boundaries(Data))
    end}.

empty_test() ->
    ?assertEqual([], xet_chunker:chunk_boundaries(<<>>)),
    ?assertEqual([], xet_chunker_ref:chunk_boundaries(<<>>)).

%% Inputs below MIN_CHUNK_SIZE are one final chunk.
small_input_test() ->
    ?assertEqual([3], xet_chunker:chunk_boundaries(<<"abc">>)),
    Data = xet_test_vectors:splitmix64_data(8191, 3),
    ?assertEqual([8191], xet_chunker:chunk_boundaries(Data)).

%% Feeding the same bytes in odd-sized pieces gives identical boundaries.
split_invariance_test() ->
    Data = xet_test_vectors:splitmix64_data(300000, 11),
    OneShot = xet_chunker:chunk_boundaries(Data),
    Pieces = split_at(Data, [1, 100, 8191, 65536, 150001]),
    {Cuts, State} = lists:foldl(
        fun(Piece, {Acc, S0}) ->
            {New, S1} = xet_chunker:update(S0, Piece),
            {Acc ++ New, S1}
        end,
        {[], xet_chunker:new()},
        Pieces
    ),
    ?assertEqual(OneShot, Cuts ++ xet_chunker:finalize(State)).

split_helper_test() ->
    Data = xet_test_vectors:splitmix64_data(200000, 5),
    Chunks = xet_chunker:split(Data),
    ?assertEqual(Data, list_to_binary(Chunks)),
    Boundaries = xet_chunker:chunk_boundaries(Data),
    ?assertEqual(length(Boundaries), length(Chunks)).

%% Full conformance against the reference dataset: chunk the real 63 MB
%% file and compare every boundary AND every chunk hash to the listing.
reference_file_test_() ->
    case xet_test_vectors:have_large_fixtures() of
        false ->
            {"large fixtures absent, skipped", []};
        true ->
            {timeout, 300, fun reference_file_check/0}
    end.

reference_file_check() ->
    {ok, Data} = file:read_file(
        xet_test_vectors:large_fixture_path("Electric_Vehicle_Population_Data_20250917.csv")
    ),
    Listing = xet_test_vectors:parse_chunks_file(
        xet_test_vectors:fixture_path("Electric_Vehicle_Population_Data_20250917.csv.chunks")
    ),
    Boundaries = xet_chunker:chunk_boundaries(Data),
    ?assertEqual(length(Listing), length(Boundaries)),
    Sizes = [Size || {_, Size} <- Listing],
    ?assertEqual(Sizes, diffs(0, Boundaries)),
    Hashes = [
        xet_hash:to_string(xet_hash:chunk_hash(Chunk))
     || Chunk <- xet_chunker:split(Data)
    ],
    ?assertEqual([Hash || {Hash, _} <- Listing], Hashes).

diffs(_Prev, []) -> [];
diffs(Prev, [B | Rest]) -> [B - Prev | diffs(B, Rest)].

split_at(Bin, Sizes) ->
    split_at(Bin, Sizes, []).

split_at(Bin, [], Acc) ->
    lists:reverse([Bin | Acc]);
split_at(Bin, [S | Rest], Acc) when byte_size(Bin) > S ->
    <<Piece:S/binary, More/binary>> = Bin,
    split_at(More, Rest, [Piece | Acc]);
split_at(Bin, _Sizes, Acc) ->
    lists:reverse([Bin | Acc]).
