%% Golden test vectors for the XET protocol test suites.
%%
%% Sources:
%%   - draft-denis-xet-05 Appendix C (doc/spec/draft-denis-xet-05.txt)
%%   - zig-xet cross-implementation vectors (splitmix64 chunk boundaries,
%%     merkle tree roots, byte-grouping), reproducible in any language
%%   - the vendored reference fixtures under test/fixtures/
%%
%% Hash values are kept in the format their consumers need: raw 32-byte
%% binaries for hash inputs, XET string format (Section 6.5) for expected
%% display values.
-module(xet_test_vectors).

-include_lib("eunit/include/eunit.hrl").

-export([
    chunk_hash_input/0,
    chunk_hash_raw/0,
    chunk_hash_string/0,
    hash_string_bytes/0,
    hash_string_expected/0,
    internal_node_children/0,
    internal_node_buffer/0,
    internal_node_result_string/0,
    verification_hashes_raw/0,
    verification_result_string/0,
    merkle_vectors/0,
    bg4_vectors/0,
    splitmix64_data/2,
    chunker_boundaries_random_1mb/0,
    chunker_boundaries_const59_1mb/0,
    expected_file_hash_string/0,
    expected_xorb_hash_string/0,
    fixtures_dir/0,
    fixture_path/1,
    large_fixture_path/1,
    have_large_fixtures/0,
    parse_chunks_file/1,
    hex_to_bin/1
]).

%%--------------------------------------------------------------------
%% Appendix C.1: chunk hash
%%--------------------------------------------------------------------

chunk_hash_input() -> <<"Hello World!">>.

chunk_hash_raw() ->
    hex_to_bin("a29cfb08e608d4d8726dd8659a90b9134b3240d5d8e42d5fcb28e2a6e763a3e8").

chunk_hash_string() ->
    <<"d8d408e608fb9ca213b9909a65d86d725f2de4d8d540324be8a363e7a6e228cb">>.

%%--------------------------------------------------------------------
%% Appendix C.2: hash string conversion
%%--------------------------------------------------------------------

hash_string_bytes() ->
    <<<<I>> || I <- lists:seq(0, 31)>>.

hash_string_expected() ->
    <<"07060504030201000f0e0d0c0b0a090817161514131211101f1e1d1c1b1a1918">>.

%%--------------------------------------------------------------------
%% Appendix C.3: internal node hash
%% Children given as {HashStringFormat, Size}. The hashed buffer uses the
%% string format verbatim: "<hex> : <size>\n" per child.
%%--------------------------------------------------------------------

internal_node_children() ->
    [
        {<<"c28f58387a60d4aa200c311cda7c7f77f686614864f5869eadebf765d0a14a69">>, 100},
        {<<"6e4e3263e073ce2c0e78cc770c361e2778db3b054b98ab65e277fc084fa70f22">>, 200}
    ].

internal_node_buffer() ->
    <<
        "c28f58387a60d4aa200c311cda7c7f77f686614864f5869eadebf765d0a14a69 : 100\n"
        "6e4e3263e073ce2c0e78cc770c361e2778db3b054b98ab65e277fc084fa70f22 : 200\n"
    >>.

internal_node_result_string() ->
    <<"be64c7003ccd3cf4357364750e04c9592b3c36705dee76a71590c011766b6c14">>.

%%--------------------------------------------------------------------
%% Appendix C.4: verification range hash
%% Inputs are the RAW chunk hashes (same two hashes as C.3, raw layout).
%%--------------------------------------------------------------------

verification_hashes_raw() ->
    [
        hex_to_bin("aad4607a38588fc2777f7cda1c310c209e86f564486186f6694aa1d065f7ebad"),
        hex_to_bin("2cce73e063324e6e271e360c77cc780e65ab984b053bdb78220fa74f08fc77e2")
    ].

verification_result_string() ->
    <<"eb06a8ad81d588ac05d1d9a079232d9c1e7d0b07232fa58091caa7bf333a2768">>.

%%--------------------------------------------------------------------
%% Merkle tree golden roots (zig-xet, hashes in XET string format)
%% {Name, [{HashString, Size}], ExpectedRootString}
%%--------------------------------------------------------------------

merkle_vectors() ->
    H1 = <<"cfc5d07f6f03c29bbf424132963fe08d19a37d5757aaf520bf08119f05cd56d6">>,
    H2 = <<"c3e67584b5c4fc2a89837ec39e40f2c8a6bb0b2987ac94cd4b31e5fbdd210a72">>,
    H3 = <<"0d2beb91b9196929a5ddec9f6e306924ddf4a24268e3e59fd8464738d525af37">>,
    H4 = <<"adf8773496a9b7319b2e50dc98093f344053b17d8ad37100b9c07d9805988784">>,
    H5 = <<"4ac202caf347fc1e9c874b1ef6a1c5e619141eb775a6f43f0f0124ccd0060d9e">>,
    H6 = <<"b3b28636f65c149ea52eb1f94669466f70f033b54cea792824c696ba6ef3c389">>,
    H7 = <<"0e2c1a002aae913d2c0fc8ddfa4e9e14b7b311b3b0d458726d5d9f6a6318013c">>,
    Zero = <<"0000000000000000000000000000000000000000000000000000000000000000">>,
    [
        {empty, [], Zero},
        {single_zero, [{Zero, 0}], Zero},
        {single, [{H1, 100}], H1},
        {three, [{H1, 100}, {H2, 200}, {H3, 300}],
            <<"71ec1275fca074724e2dd666921b3277c7cee603e4d025bcab2d4050015be2bc">>},
        {four_identical, lists:duplicate(4, {H1, 100}),
            <<"89f2ada89ff8c96763c6b25010e6dd76a4c05b1466207633ea559acf2093211b">>},
        {six, [{H1, 100}, {H2, 200}, {H1, 100}, {H2, 200}, {H3, 300}, {H4, 400}],
            <<"52c826f99507aa05d0b45e9837fa1709e0485425cfbcb1e80db3905cf98b3ee9">>},
        {eight,
            [
                {Zero, 0},
                {H1, 100},
                {H2, 200},
                {H3, 300},
                {H4, 400},
                {H5, 500},
                {H6, 600},
                {H7, 700}
            ],
            <<"f62abe77e3fb9c954fe52b0028027ddc90c064c45951a4fd2211d87e5c0011db">>},
        {thirty_two, lists:duplicate(32, {H1, 100}),
            <<"0a0123c1617921883b7e13902095fcb86676e77c49120c33b233003b0af0e0a6">>}
    ].

%%--------------------------------------------------------------------
%% Byte grouping (BG4) golden vectors (zig-xet): {Input, Grouped}
%%--------------------------------------------------------------------

bg4_vectors() ->
    [
        {<<0, 1, 2, 3, 4, 5, 6, 7, 8, 9>>, <<0, 4, 8, 1, 5, 9, 2, 6, 3, 7>>},
        {
            <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12>>,
            <<0, 4, 8, 12, 1, 5, 9, 2, 6, 10, 3, 7, 11>>
        },
        {
            <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14>>,
            <<0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11>>
        },
        {<<0, 1, 2, 3, 4, 5, 6, 7>>, <<0, 4, 1, 5, 2, 6, 3, 7>>}
    ].

%%--------------------------------------------------------------------
%% Deterministic pseudo-random input for chunker vectors (splitmix64).
%% Output bytes are the little-endian encoding of successive splitmix64
%% values, truncated to N bytes. Matches zig-xet's createRandomData.
%%--------------------------------------------------------------------

-define(M64, 16#FFFFFFFFFFFFFFFF).

splitmix64_data(N, Seed) when N >= 0 ->
    NWords = (N + 7) div 8,
    Words = splitmix64_words(NWords, Seed, []),
    binary:part(iolist_to_binary(Words), 0, N).

splitmix64_words(0, _State, Acc) ->
    lists:reverse(Acc);
splitmix64_words(K, State0, Acc) ->
    State = (State0 + 16#9E3779B97F4A7C15) band ?M64,
    Z1 = ((State bxor (State bsr 30)) * 16#BF58476D1CE4E5B9) band ?M64,
    Z2 = ((Z1 bxor (Z1 bsr 27)) * 16#94D049BB133111EB) band ?M64,
    Out = Z2 bxor (Z2 bsr 31),
    splitmix64_words(K - 1, State, [<<Out:64/little>> | Acc]).

%% Chunk end offsets for 1,000,000 bytes of splitmix64 data, seed 0.
chunker_boundaries_random_1mb() ->
    [
        84493,
        134421,
        144853,
        243318,
        271793,
        336457,
        467529,
        494581,
        582000,
        596735,
        616815,
        653164,
        678202,
        724510,
        815591,
        827760,
        958832,
        991092,
        1000000
    ].

%% Chunk end offsets for 1,000,000 bytes of constant value 59:
%% no content boundary ever fires, so cuts land at MAX_CHUNK_SIZE multiples.
chunker_boundaries_const59_1mb() ->
    [131072, 262144, 393216, 524288, 655360, 786432, 917504, 1000000].

%%--------------------------------------------------------------------
%% Reference fixture expectations
%%--------------------------------------------------------------------

expected_file_hash_string() ->
    <<"118a53328412787fee04011dcf82fdc4acf3a4a1eddec341c910d30a306aaf97">>.

expected_xorb_hash_string() ->
    <<"eea25d6ee393ccae385820daed127b96ef0ea034dfb7cf6da3a950ce334b7632">>.

fixtures_dir() ->
    filename:join([project_root(), "test", "fixtures"]).

fixture_path(Name) ->
    filename:join(fixtures_dir(), Name).

large_fixture_path(Name) ->
    filename:join([fixtures_dir(), "large", Name]).

have_large_fixtures() ->
    filelib:is_regular(large_fixture_path("Electric_Vehicle_Population_Data_20250917.csv")) andalso
        filelib:is_regular(
            large_fixture_path(
                "eea25d6ee393ccae385820daed127b96ef0ea034dfb7cf6da3a950ce334b7632.xorb"
            )
        ).

%% Parse a ".chunks" listing: one "<hash string> <length>" per line.
parse_chunks_file(Path) ->
    {ok, Bin} = file:read_file(Path),
    Lines = [L || L <- binary:split(Bin, <<"\n">>, [global, trim_all])],
    [
        begin
            [Hash, Len] = binary:split(L, <<" ">>),
            {Hash, binary_to_integer(Len)}
        end
     || L <- Lines
    ].

project_root() ->
    from_beam_dir(filename:dirname(code:which(?MODULE))).

from_beam_dir(Dir) ->
    case filelib:is_regular(filename:join(Dir, "rebar.config")) of
        true ->
            Dir;
        false ->
            Parent = filename:dirname(Dir),
            true = Parent =/= Dir,
            from_beam_dir(Parent)
    end.

hex_to_bin(Hex) when is_list(Hex) ->
    hex_to_bin(list_to_binary(Hex));
hex_to_bin(Hex) when is_binary(Hex), byte_size(Hex) rem 2 =:= 0 ->
    <<<<(binary_to_integer(<<A, B>>, 16))>> || <<A, B>> <= Hex>>.

%%--------------------------------------------------------------------
%% Sanity tests for the vectors themselves (everything here must hold
%% before any production code exists).
%%--------------------------------------------------------------------

splitmix64_test() ->
    Data = splitmix64_data(1000000, 0),
    ?assertEqual(1000000, byte_size(Data)),
    ?assertEqual(175, binary:at(Data, 0)),
    ?assertEqual(132, binary:at(Data, 127)),
    ?assertEqual(118, binary:at(Data, 111111)).

chunks_listing_test() ->
    Chunks = parse_chunks_file(
        fixture_path("Electric_Vehicle_Population_Data_20250917.csv.chunks")
    ),
    ?assertEqual(796, length(Chunks)),
    Total = lists:sum([S || {_, S} <- Chunks]),
    ?assertEqual(63527244, Total),
    %% The three vendored .chunk files are the first three chunks: filename
    %% is the chunk hash, file size is the chunk length.
    lists:foreach(
        fun({Hash, Size}) ->
            Path = fixture_path(<<Hash/binary, ".chunk">>),
            ?assert(filelib:is_regular(Path)),
            ?assertEqual(Size, filelib:file_size(Path))
        end,
        lists:sublist(Chunks, 3)
    ).

xorb_chunks_listing_matches_file_chunks_test() ->
    %% The single xorb contains exactly the file's chunks, in order.
    FileChunks = parse_chunks_file(
        fixture_path("Electric_Vehicle_Population_Data_20250917.csv.chunks")
    ),
    XorbChunks = parse_chunks_file(
        fixture_path(
            "eea25d6ee393ccae385820daed127b96ef0ea034dfb7cf6da3a950ce334b7632.xorb.chunks"
        )
    ),
    ?assertEqual(FileChunks, XorbChunks).

expected_hash_files_test() ->
    {ok, FileHash} = file:read_file(
        fixture_path("Electric_Vehicle_Population_Data_20250917.csv.xet-file-hash")
    ),
    ?assertEqual(expected_file_hash_string(), trim(FileHash)),
    {ok, XorbHash} = file:read_file(
        fixture_path("Electric_Vehicle_Population_Data_20250917.csv.xet-xorb-hash")
    ),
    ?assertEqual(expected_xorb_hash_string(), trim(XorbHash)).

vector_shapes_test() ->
    ?assertEqual(8, length(merkle_vectors())),
    ?assertEqual(4, length(bg4_vectors())),
    ?assertEqual(19, length(chunker_boundaries_random_1mb())),
    ?assertEqual(8, length(chunker_boundaries_const59_1mb())),
    ?assertEqual(32, byte_size(chunk_hash_raw())),
    [?assertEqual(32, byte_size(H)) || H <- verification_hashes_raw()],
    ok.

hex_roundtrip_test() ->
    ?assertEqual(<<16#a2, 16#9c>>, hex_to_bin("a29c")),
    ?assertEqual(
        hash_string_bytes(),
        hex_to_bin(<<
            "000102030405060708090a0b0c0d0e0f"
            "101112131415161718191a1b1c1d1e1f"
        >>)
    ).

trim(Bin) ->
    hd(binary:split(Bin, [<<"\n">>, <<"\r">>], [global, trim_all])).
