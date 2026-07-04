-module(xet_reconstruction_tests).

-include_lib("eunit/include/eunit.hrl").

%% Two real xorbs so boundary offsets and byte ranges are the real thing.
world() ->
    ChunksA = [xet_test_vectors:splitmix64_data(30 + I * 7, I) || I <- lists:seq(1, 6)],
    ChunksB = [xet_test_vectors:splitmix64_data(20 + I * 5, 100 + I) || I <- lists:seq(1, 5)],
    {ok, XorbA} = xet_xorb:encode(ChunksA, #{nonce => <<0, 0, 0, 0>>}),
    {ok, XorbB} = xet_xorb:encode(ChunksB, #{nonce => <<0, 0, 0, 0>>}),
    Terms = [
        term(XorbA, ChunksA, 0, 4),
        term(XorbB, ChunksB, 1, 5),
        term(XorbA, ChunksA, 2, 6)
    ],
    Source = list_to_binary([data_of(T, XorbA, ChunksA, XorbB, ChunksB) || T <- Terms]),
    #{
        terms => [strip(T) || T <- Terms],
        source => Source,
        info => maps:from_list([info_entry(XorbA), info_entry(XorbB)]),
        chunk_data => #{
            maps:get(hash, XorbA) => ChunksA,
            maps:get(hash, XorbB) => ChunksB
        },
        bins => #{
            maps:get(hash, XorbA) => maps:get(bin, XorbA),
            maps:get(hash, XorbB) => maps:get(bin, XorbB)
        }
    }.

term(Xorb, Chunks, S, E) ->
    Len = lists:sum([byte_size(C) || C <- lists:sublist(Chunks, S + 1, E - S)]),
    #{cas_hash => maps:get(hash, Xorb), chunk_start => S, chunk_end => E, unpacked_len => Len}.

strip(T) -> maps:with([cas_hash, chunk_start, chunk_end, unpacked_len], T).

data_of(#{cas_hash := Cas, chunk_start := S, chunk_end := E}, XA, CA, _XB, CB) ->
    Chunks =
        case Cas =:= maps:get(hash, XA) of
            true -> CA;
            false -> CB
        end,
    lists:sublist(Chunks, S + 1, E - S).

info_entry(Xorb) ->
    {maps:get(hash, Xorb), #{
        unpacked_offsets => maps:get(unpacked_offsets, Xorb),
        boundary_offsets => maps:get(boundary_offsets, Xorb)
    }}.

info_fun(World) ->
    fun(Cas) -> maps:get(Cas, maps:get(info, World)) end.

assemble(Plan, World) ->
    ChunkData = maps:get(chunk_data, World),
    All = list_to_binary([
        lists:sublist(
            maps:get(maps:get(cas_hash, T), ChunkData),
            maps:get(chunk_start, T) + 1,
            maps:get(chunk_end, T) - maps:get(chunk_start, T)
        )
     || T <- maps:get(terms, Plan)
    ]),
    binary:part(
        All,
        maps:get(offset_into_first_range, Plan),
        byte_size(All) - maps:get(offset_into_first_range, Plan)
    ).

full_file_test() ->
    World = world(),
    Source = maps:get(source, World),
    {ok, Plan} = xet_reconstruction:plan(
        maps:get(terms, World), byte_size(Source), all, info_fun(World)
    ),
    ?assertEqual(0, maps:get(offset_into_first_range, Plan)),
    ?assertEqual(Source, assemble(Plan, World)).

ranges_test() ->
    World = world(),
    Source = maps:get(source, World),
    Total = byte_size(Source),
    Cases = [
        {0, 0},
        {0, Total - 1},
        {1, 1},
        {17, 211},
        {Total - 5, Total - 1},
        %% End past EOF clamps.
        {Total - 10, Total + 500},
        {Total div 3, 2 * Total div 3}
    ],
    lists:foreach(
        fun({S, E}) ->
            {ok, Plan} = xet_reconstruction:plan(
                maps:get(terms, World), Total, {S, E}, info_fun(World)
            ),
            Len = min(E, Total - 1) - S + 1,
            Got = binary:part(assemble(Plan, World), 0, Len),
            ?assertEqual(binary:part(Source, S, Len), Got)
        end,
        Cases
    ).

unsatisfiable_test() ->
    World = world(),
    Total = byte_size(maps:get(source, World)),
    ?assertEqual(
        {error, unsatisfiable},
        xet_reconstruction:plan(maps:get(terms, World), Total, {Total, Total}, info_fun(World))
    ),
    ?assertEqual(
        {error, unsatisfiable},
        xet_reconstruction:plan(maps:get(terms, World), Total, {5, 4}, info_fun(World))
    ),
    ?assertEqual(
        {error, unsatisfiable},
        xet_reconstruction:plan([], 0, {0, 0}, fun(_) -> #{} end)
    ).

empty_file_test() ->
    {ok, Plan} = xet_reconstruction:plan([], 0, all, fun(_) -> error(unused) end),
    ?assertEqual(#{offset_into_first_range => 0, terms => [], xorb_ranges => []}, Plan).

inconsistent_metadata_test() ->
    World = world(),
    Bad = fun(_) -> #{unpacked_offsets => [1], boundary_offsets => [1]} end,
    ?assertEqual(
        {error, inconsistent_metadata},
        xet_reconstruction:plan(
            maps:get(terms, World), byte_size(maps:get(source, World)), all, Bad
        )
    ).

%% The rendered byte ranges must slice the serialized xorb to exactly the
%% chunks of the range: fetched bytes parse to the right chunk data.
byte_range_slices_test() ->
    World = world(),
    Source = maps:get(source, World),
    {ok, Plan} = xet_reconstruction:plan(
        maps:get(terms, World), byte_size(Source), {40, 300}, info_fun(World)
    ),
    V1 = xet_reconstruction:to_v1(Plan, render_ctx(World)),
    maps:foreach(
        fun(CasString, Entries) ->
            Cas = xet_hash:from_string(CasString),
            Bin = maps:get(Cas, maps:get(bins, World)),
            lists:foreach(
                fun(
                    #{url_range := #{start := S, 'end' := E}, range := #{start := CS, 'end' := CE}}
                ) ->
                    Slice = binary:part(Bin, S, E - S + 1),
                    {ok, Chunks} = xet_xorb:parse_chunk_stream(Slice),
                    Expected = lists:sublist(
                        maps:get(Cas, maps:get(chunk_data, World)), CS + 1, CE - CS
                    ),
                    ?assertEqual(Expected, Chunks)
                end,
                Entries
            )
        end,
        maps:get(fetch_info, V1)
    ).

render_shapes_test() ->
    World = world(),
    Source = maps:get(source, World),
    {ok, Plan} = xet_reconstruction:plan(
        maps:get(terms, World), byte_size(Source), all, info_fun(World)
    ),
    Ctx = render_ctx(World),
    V1 = xet_reconstruction:to_v1(Plan, Ctx),
    V2 = xet_reconstruction:to_v2(Plan, Ctx),
    ?assertEqual(maps:get(terms, V1), maps:get(terms, V2)),
    ?assertNot(is_map_key(xorbs, V1)),
    ?assertNot(is_map_key(fetch_info, V2)),
    [First | _] = maps:get(terms, V1),
    ?assert(xet_hash:is_hash_string(maps:get(hash, First))),
    %% Every V1 fetch byte span appears among V2's range descriptors.
    V1Spans = lists:sort([
        {Cas, maps:get(start, R), maps:get('end', R)}
     || {Cas, Entries} <- maps:to_list(maps:get(fetch_info, V1)),
        #{url_range := R} <- Entries
    ]),
    V2Spans = lists:sort([
        {Cas, maps:get(start, B), maps:get('end', B)}
     || {Cas, [Entry]} <- maps:to_list(maps:get(xorbs, V2)),
        #{bytes := B} <- maps:get(ranges, Entry)
    ]),
    ?assertEqual(V1Spans, V2Spans).

render_ctx(World) ->
    #{
        url => fun(Cas, {S, E}) ->
            list_to_binary([
                "https://example/",
                xet_hash:to_string(Cas),
                "/",
                integer_to_list(S),
                "-",
                integer_to_list(E)
            ])
        end,
        boundaries => fun(Cas) ->
            maps:get(boundary_offsets, maps:get(Cas, maps:get(info, World)))
        end
    }.
