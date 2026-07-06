%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(xet_api_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    upload_roundtrip/1,
    upload_v1_alias/1,
    footerless_upload/1,
    hash_mismatch/1,
    corrupted_rejected_and_not_stored/1,
    truncated_rejected/1,
    bad_targets/1,
    unauthorized/1,
    oversize_rejected/1,
    disk_spool_path/1,
    corruption_property/1,
    shard_roundtrip/1,
    shard_missing_xorb/1,
    shard_bad_verification/1,
    shard_cas_mismatch/1,
    shard_footered_tolerated/1,
    shard_bare_alias/1,
    reconstruction_full/1,
    reconstruction_range/1,
    reconstruction_errors/1,
    reconstruction_empty_file/1,
    reconstruction_v2_consistency/1,
    head_file/1,
    data_roundtrip/1,
    data_range/1,
    data_forbidden/1,
    data_errors/1,
    url_secret_survives_restart/1,
    data_ratelimited_per_url/1,
    chunk_dedup_flow/1,
    chunk_miss/1,
    key_rotation/1,
    metrics_counters/1,
    metrics_store_and_chunks/1,
    insufficient_storage/1
]).

-define(TOKEN, <<"write-token">>).

all() ->
    [
        upload_roundtrip,
        upload_v1_alias,
        footerless_upload,
        hash_mismatch,
        corrupted_rejected_and_not_stored,
        truncated_rejected,
        bad_targets,
        unauthorized,
        oversize_rejected,
        disk_spool_path,
        corruption_property,
        shard_roundtrip,
        shard_missing_xorb,
        shard_bad_verification,
        shard_cas_mismatch,
        shard_footered_tolerated,
        shard_bare_alias,
        reconstruction_full,
        reconstruction_range,
        reconstruction_errors,
        reconstruction_empty_file,
        reconstruction_v2_consistency,
        head_file,
        data_roundtrip,
        data_range,
        data_forbidden,
        data_errors,
        url_secret_survives_restart,
        data_ratelimited_per_url,
        chunk_dedup_flow,
        chunk_miss,
        key_rotation,
        metrics_counters,
        metrics_store_and_chunks,
        insufficient_storage
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started([barrel_xet, hackney]),
    DataDir = filename:join(proplists:get_value(priv_dir, Config), "api"),
    {ok, _} = xet_server:start(#{
        name => xet_api_server,
        data_dir => DataDir,
        auth => {xet_auth_static, #{tokens => #{?TOKEN => write}}}
    }),
    [{data_dir, DataDir} | Config].

end_per_suite(_Config) ->
    ok = xet_server:stop(xet_api_server),
    ok.

base() ->
    "http://127.0.0.1:" ++ integer_to_list(xet_server:port(xet_api_server)).

post_xorb(Base, Path, Body) ->
    {ok, Status, _, RespBody} = hackney:request(
        post,
        Base ++ Path,
        [{<<"authorization">>, <<"Bearer ", ?TOKEN/binary>>}],
        Body,
        [with_body, {pool, false}]
    ),
    {Status, RespBody}.

head_xorb(Base, Path) ->
    {ok, Status, _} = hackney:request(
        head,
        Base ++ Path,
        [{<<"authorization">>, <<"Bearer ", ?TOKEN/binary>>}],
        <<>>,
        [{pool, false}]
    ),
    Status.

sample_xorb(Seeds) ->
    Chunks = [xet_test_vectors:splitmix64_data(2000 + S, S) || S <- Seeds],
    {ok, Enc} = xet_xorb:encode(Chunks, #{nonce => <<0, 0, 0, 0>>}),
    Enc.

path_for(Enc) ->
    "/api/v1/xorbs/default/" ++ binary_to_list(xet_hash:to_string(maps:get(hash, Enc))).

upload_roundtrip(_Config) ->
    Enc = sample_xorb([1, 2, 3]),
    Path = path_for(Enc),
    {200, Body} = post_xorb(base(), Path, maps:get(bin, Enc)),
    ?assertEqual(#{<<"was_inserted">> => true}, json:decode(Body)),
    ?assertEqual(200, head_xorb(base(), Path)),
    {200, Body2} = post_xorb(base(), Path, maps:get(bin, Enc)),
    ?assertEqual(#{<<"was_inserted">> => false}, json:decode(Body2)),
    Env = xet_server:env(xet_api_server),
    ?assert(xet_blob_store:exists(maps:get(blob, Env), <<"default">>, maps:get(hash, Enc))),
    {ok, Meta} = xet_metadata:get_xorb(maps:get(metadata, Env), maps:get(hash, Enc)),
    ?assertEqual(maps:get(boundary_offsets, Enc), maps:get(boundary_offsets, Meta)).

upload_v1_alias(_Config) ->
    Enc = sample_xorb([4, 5]),
    Path = "/v1/xorbs/default/" ++ binary_to_list(xet_hash:to_string(maps:get(hash, Enc))),
    {200, Body} = post_xorb(base(), Path, maps:get(bin, Enc)),
    ?assertEqual(#{<<"was_inserted">> => true}, json:decode(Body)).

footerless_upload(_Config) ->
    Enc = sample_xorb([6, 7, 8]),
    Bin = maps:get(bin, Enc),
    {ok, #{data_size := DataSize}} = xet_xorb_footer:decode(Bin),
    Bare = binary:part(Bin, 0, DataSize),
    Path = path_for(Enc),
    {200, Body} = post_xorb(base(), Path, Bare),
    ?assertEqual(#{<<"was_inserted">> => true}, json:decode(Body)),
    %% Stored as received: the bare form's size, not the footered one.
    Env = xet_server:env(xet_api_server),
    ?assertEqual(
        {ok, byte_size(Bare)},
        xet_blob_store:size(maps:get(blob, Env), <<"default">>, maps:get(hash, Enc))
    ).

hash_mismatch(_Config) ->
    Enc = sample_xorb([9]),
    Other = sample_xorb([10]),
    {Status, _} = post_xorb(base(), path_for(Other), maps:get(bin, Enc)),
    ?assertEqual(400, Status),
    ?assertEqual(404, head_xorb(base(), path_for(Other))).

corrupted_rejected_and_not_stored(_Config) ->
    Enc = sample_xorb([11, 12]),
    Bin = maps:get(bin, Enc),
    <<Before:100/binary, Byte, After/binary>> = Bin,
    Corrupt = <<Before/binary, (Byte bxor 255), After/binary>>,
    {Status, _} = post_xorb(base(), path_for(Enc), Corrupt),
    ?assertEqual(400, Status),
    ?assertEqual(404, head_xorb(base(), path_for(Enc))),
    Env = xet_server:env(xet_api_server),
    ?assertNot(xet_blob_store:exists(maps:get(blob, Env), <<"default">>, maps:get(hash, Enc))).

truncated_rejected(_Config) ->
    Enc = sample_xorb([13]),
    Bin = maps:get(bin, Enc),
    {Status, _} = post_xorb(base(), path_for(Enc), binary:part(Bin, 0, byte_size(Bin) - 9)),
    ?assertEqual(400, Status).

bad_targets(_Config) ->
    Enc = sample_xorb([14]),
    HashStr = binary_to_list(xet_hash:to_string(maps:get(hash, Enc))),
    {S1, _} = post_xorb(base(), "/api/v1/xorbs/nope/" ++ HashStr, maps:get(bin, Enc)),
    ?assertEqual(400, S1),
    {S2, _} = post_xorb(base(), "/api/v1/xorbs/default/nothex", maps:get(bin, Enc)),
    ?assertEqual(400, S2).

unauthorized(_Config) ->
    Enc = sample_xorb([15]),
    {ok, Status, _, _} = hackney:request(
        post, base() ++ path_for(Enc), [], maps:get(bin, Enc), [with_body, {pool, false}]
    ),
    ?assertEqual(401, Status).

oversize_rejected(Config) ->
    DataDir = filename:join(proplists:get_value(priv_dir, Config), "tinycap"),
    {ok, _} = xet_server:start(#{
        name => xet_tiny_server,
        data_dir => DataDir,
        max_xorb_bytes => 1000,
        auth => {xet_auth_static, #{tokens => #{?TOKEN => write}}}
    }),
    try
        Enc = sample_xorb([16, 17]),
        Base = "http://127.0.0.1:" ++ integer_to_list(xet_server:port(xet_tiny_server)),
        {Status, Body} = post_xorb(Base, path_for(Enc), maps:get(bin, Enc)),
        ?assertEqual(400, Status),
        ?assertEqual(#{<<"error">> => <<"too_large">>}, json:decode(Body))
    after
        ok = xet_server:stop(xet_tiny_server)
    end.

%% A memory threshold of 1 KiB forces the disk spool path; the spool
%% file must be gone afterwards, success or failure.
disk_spool_path(Config) ->
    DataDir = filename:join(proplists:get_value(priv_dir, Config), "spool"),
    {ok, _} = xet_server:start(#{
        name => xet_spool_server,
        data_dir => DataDir,
        spool_memory_max => 1024,
        auth => {xet_auth_static, #{tokens => #{?TOKEN => write}}}
    }),
    try
        Enc = sample_xorb([18, 19, 20, 21]),
        Base = "http://127.0.0.1:" ++ integer_to_list(xet_server:port(xet_spool_server)),
        {200, Body} = post_xorb(Base, path_for(Enc), maps:get(bin, Enc)),
        ?assertEqual(#{<<"was_inserted">> => true}, json:decode(Body)),
        ?assertEqual([], filelib:wildcard(filename:join([DataDir, "spool", "*"]))),
        Bad = <<(maps:get(bin, sample_xorb([22, 23])))/binary, "junk">>,
        {400, _} = post_xorb(Base, path_for(sample_xorb([22, 23])), Bad),
        ?assertEqual([], filelib:wildcard(filename:join([DataDir, "spool", "*"])))
    after
        ok = xet_server:stop(xet_spool_server)
    end.

%%--------------------------------------------------------------------
%% Shards
%%--------------------------------------------------------------------

%% One uploaded xorb + a shard describing a file over it.
shard_world(Seeds) ->
    Enc = sample_xorb(Seeds),
    {200, _} = post_xorb(base(), path_for(Enc), maps:get(bin, Enc)),
    Entries = lists:zip(maps:get(chunk_hashes, Enc), maps:get(unpacked_sizes, Enc)),
    N = length(Entries),
    Terms = [
        #{
            cas_hash => maps:get(hash, Enc),
            unpacked_len => lists:sum([S || {_, S} <- Entries]),
            chunk_start => 0,
            chunk_end => N
        }
    ],
    FileHash = xet_hash:file_hash(Entries),
    File = #{
        file_hash => FileHash,
        terms => Terms,
        verification => [xet_hash:verification_hash([H || {H, _} <- Entries])],
        sha256 => crypto:hash(sha256, <<"whatever">>)
    },
    CasBlock = #{
        cas_hash => maps:get(hash, Enc),
        bytes_on_disk => maps:get(bytes_on_disk, Enc),
        chunks => [
            #{hash => H, size => S, dedup_eligible => false}
         || {H, S} <- Entries
        ]
    },
    #{xorb => Enc, entries => Entries, file => File, cas => CasBlock, file_hash => FileHash}.

post_shard(Base, Path, Body) ->
    {ok, Status, _, RespBody} = hackney:request(
        post,
        Base ++ Path,
        [{<<"authorization">>, <<"Bearer ", ?TOKEN/binary>>}],
        Body,
        [with_body, {pool, false}]
    ),
    {Status, RespBody}.

shard_roundtrip(_Config) ->
    World = shard_world([40, 41, 42]),
    Bin = xet_shard:encode_upload(#{files => [maps:get(file, World)], cas => [maps:get(cas, World)]}),
    {200, Body} = post_shard(base(), "/api/v1/shards", Bin),
    ?assertEqual(#{<<"result">> => 1}, json:decode(Body)),
    {200, Body2} = post_shard(base(), "/api/v1/shards", Bin),
    ?assertEqual(#{<<"result">> => 0}, json:decode(Body2)),
    Env = xet_server:env(xet_api_server),
    {ok, FileMeta} = xet_metadata:get_file(maps:get(metadata, Env), maps:get(file_hash, World)),
    ?assertEqual(maps:get(terms, maps:get(file, World)), maps:get(terms, FileMeta)),
    %% The first chunk of the file is always dedup-indexed.
    [{FirstHash, _} | _] = maps:get(entries, World),
    ?assertEqual(
        {ok, {maps:get(hash, maps:get(xorb, World)), 0}},
        xet_metadata:find_chunk(maps:get(metadata, Env), FirstHash)
    ).

shard_missing_xorb(_Config) ->
    World = shard_world([43, 44]),
    Ghost = maps:put(cas_hash, <<12345:256>>, hd(maps:get(terms, maps:get(file, World)))),
    File = maps:put(terms, [Ghost], maps:get(file, World)),
    Bin = xet_shard:encode_upload(#{files => [maps:remove(verification, File)], cas => []}),
    {Status, Body} = post_shard(base(), "/api/v1/shards", Bin),
    ?assertEqual(400, Status),
    ?assertEqual(#{<<"error">> => <<"missing_xorb">>}, json:decode(Body)).

shard_bad_verification(_Config) ->
    World = shard_world([45, 46]),
    File = maps:put(verification, [<<0:256>>], maps:get(file, World)),
    Bin = xet_shard:encode_upload(#{files => [File], cas => []}),
    {Status, Body} = post_shard(base(), "/api/v1/shards", Bin),
    ?assertEqual(400, Status),
    ?assertEqual(#{<<"error">> => <<"bad_verification">>}, json:decode(Body)),
    Env = xet_server:env(xet_api_server),
    ?assertEqual(
        not_found,
        xet_metadata:get_file(maps:get(metadata, Env), maps:get(file_hash, World))
    ).

shard_cas_mismatch(_Config) ->
    World = shard_world([47, 48]),
    Cas = maps:get(cas, World),
    [C1 | Rest] = maps:get(chunks, Cas),
    Tampered = Cas#{chunks := [C1#{size := maps:get(size, C1) + 1} | Rest]},
    Bin = xet_shard:encode_upload(#{files => [], cas => [Tampered]}),
    {Status, Body} = post_shard(base(), "/api/v1/shards", Bin),
    ?assertEqual(400, Status),
    %% Cumulative-offset validation in the codec rejects it even before
    %% the layout comparison.
    ?assert(
        lists:member(json:decode(Body), [
            #{<<"error">> => <<"cas_mismatch">>}, #{<<"error">> => <<"bad_chunk_entry">>}
        ])
    ).

%% zig-xet style: footered payload on the upload endpoint is accepted,
%% the tail ignored.
shard_footered_tolerated(_Config) ->
    World = shard_world([49, 50]),
    Bin = xet_shard:encode_stored(
        #{files => [maps:get(file, World)], cas => [maps:get(cas, World)]},
        #{chunk_hash_key => xet_hash:zero_hash(), created_at => 1, key_expiry => 0}
    ),
    {200, Body} = post_shard(base(), "/api/v1/shards", Bin),
    ?assertEqual(#{<<"result">> => 1}, json:decode(Body)).

shard_bare_alias(_Config) ->
    World = shard_world([51, 52]),
    Bin = xet_shard:encode_upload(#{files => [maps:get(file, World)], cas => []}),
    {200, Body} = post_shard(base(), "/shards", Bin),
    ?assertEqual(#{<<"result">> => 1}, json:decode(Body)).

%%--------------------------------------------------------------------
%% Reconstructions
%%--------------------------------------------------------------------

registered_file(Seeds) ->
    World = shard_world(Seeds),
    Bin = xet_shard:encode_upload(#{
        files => [maps:get(file, World)], cas => [maps:get(cas, World)]
    }),
    {200, _} = post_shard(base(), "/api/v1/shards", Bin),
    World.

get_json(Path, Headers) ->
    {ok, Status, RespHeaders, Body} = hackney:request(
        get,
        base() ++ Path,
        [{<<"authorization">>, <<"Bearer ", ?TOKEN/binary>>} | Headers],
        <<>>,
        [with_body, {pool, false}]
    ),
    Decoded =
        case Status of
            200 -> json:decode(Body);
            _ -> Body
        end,
    {Status, RespHeaders, Decoded}.

reconstruction_path(Prefix, World) ->
    Prefix ++ binary_to_list(xet_hash:to_string(maps:get(file_hash, World))).

reconstruction_full(_Config) ->
    World = registered_file([60, 61, 62]),
    {200, Headers, Body} = get_json(reconstruction_path("/api/v1/reconstructions/", World), []),
    ?assertEqual(
        <<"private, no-store">>, proplists:get_value(<<"cache-control">>, Headers)
    ),
    ?assertEqual(0, maps:get(<<"offset_into_first_range">>, Body)),
    XorbHashStr = xet_hash:to_string(maps:get(hash, maps:get(xorb, World))),
    [Term] = maps:get(<<"terms">>, Body),
    ?assertEqual(XorbHashStr, maps:get(<<"hash">>, Term)),
    N = length(maps:get(entries, World)),
    ?assertEqual(#{<<"start">> => 0, <<"end">> => N}, maps:get(<<"range">>, Term)),
    #{XorbHashStr := [Fetch]} = maps:get(<<"fetch_info">>, Body),
    Url = maps:get(<<"url">>, Fetch),
    ?assertNotEqual(nomatch, binary:match(Url, <<"/data?exp=">>)),
    ?assertNotEqual(nomatch, binary:match(Url, <<"&sig=">>)),
    LastBoundary = lists:last(maps:get(boundary_offsets, maps:get(xorb, World))),
    ?assertEqual(
        #{<<"start">> => 0, <<"end">> => LastBoundary - 1},
        maps:get(<<"url_range">>, Fetch)
    ).

reconstruction_range(_Config) ->
    World = registered_file([63, 64, 65]),
    Entries = maps:get(entries, World),
    Total = lists:sum([S || {_, S} <- Entries]),
    Start = Total div 3,
    End = 2 * Total div 3,
    {200, _, Body} = get_json(
        reconstruction_path("/api/v1/reconstructions/", World),
        [{<<"range">>, iolist_to_binary(io_lib:format("bytes=~b-~b", [Start, End]))}]
    ),
    Offset = maps:get(<<"offset_into_first_range">>, Body),
    Terms = maps:get(<<"terms">>, Body),
    ?assert(Offset >= 0),
    Unpacked = lists:sum([maps:get(<<"unpacked_length">>, T) || T <- Terms]),
    ?assert(Unpacked - Offset >= End - Start + 1),
    [First | _] = Terms,
    FirstLen = maps:get(<<"unpacked_length">>, First),
    ?assert(Offset < FirstLen).

reconstruction_errors(_Config) ->
    World = registered_file([66]),
    Path = reconstruction_path("/api/v1/reconstructions/", World),
    Unknown = binary:copy(<<"ab">>, 32),
    {S404, _, _} = get_json("/api/v1/reconstructions/" ++ binary_to_list(Unknown), []),
    ?assertEqual(404, S404),
    {S416a, _, _} = get_json(Path, [{<<"range">>, <<"bytes=zz">>}]),
    ?assertEqual(416, S416a),
    {S416b, _, _} = get_json(Path, [{<<"range">>, <<"bytes=999999999-999999999">>}]),
    ?assertEqual(416, S416b),
    {S400, _, _} = get_json("/api/v1/reconstructions/nothex", []),
    ?assertEqual(400, S400).

reconstruction_empty_file(_Config) ->
    Env = xet_server:env(xet_api_server),
    EmptyHash = xet_hash:zero_hash(),
    ok = xet_metadata:register_files(
        maps:get(metadata, Env),
        [#{file_hash => EmptyHash, total_len => 0, terms => []}],
        []
    ),
    {200, _, Body} = get_json(
        "/api/v1/reconstructions/" ++ binary_to_list(xet_hash:to_string(EmptyHash)), []
    ),
    ?assertEqual(0, maps:get(<<"offset_into_first_range">>, Body)),
    ?assertEqual([], maps:get(<<"terms">>, Body)),
    ?assertEqual(#{}, maps:get(<<"fetch_info">>, Body)).

reconstruction_v2_consistency(_Config) ->
    World = registered_file([67, 68]),
    {200, _, V1} = get_json(reconstruction_path("/api/v1/reconstructions/", World), []),
    {200, _, V2} = get_json(reconstruction_path("/api/v2/reconstructions/", World), []),
    ?assertEqual(maps:get(<<"terms">>, V1), maps:get(<<"terms">>, V2)),
    ?assertNot(is_map_key(<<"fetch_info">>, V2)),
    ?assertNot(is_map_key(<<"xorbs">>, V1)),
    V1Spans = lists:sort([
        {Cas, maps:get(<<"start">>, R), maps:get(<<"end">>, R)}
     || {Cas, Fetches} <- maps:to_list(maps:get(<<"fetch_info">>, V1)),
        #{<<"url_range">> := R} <- Fetches
    ]),
    V2Spans = lists:sort([
        {Cas, maps:get(<<"start">>, B), maps:get(<<"end">>, B)}
     || {Cas, [Entry]} <- maps:to_list(maps:get(<<"xorbs">>, V2)),
        #{<<"bytes">> := B} <- maps:get(<<"ranges">>, Entry)
    ]),
    ?assertEqual(V1Spans, V2Spans),
    %% Also served under the bare /v2 prefix.
    {200, _, _} = get_json(reconstruction_path("/v2/reconstructions/", World), []).

head_file(_Config) ->
    World = registered_file([69]),
    Path = reconstruction_path("/api/v1/files/", World),
    {ok, S1, _} = hackney:request(
        head, base() ++ Path, [{<<"authorization">>, <<"Bearer ", ?TOKEN/binary>>}], <<>>, [
            {pool, false}
        ]
    ),
    ?assertEqual(200, S1),
    Unknown = "/api/v1/files/" ++ binary_to_list(binary:copy(<<"cd">>, 32)),
    {ok, S2, _} = hackney:request(
        head, base() ++ Unknown, [{<<"authorization">>, <<"Bearer ", ?TOKEN/binary>>}], <<>>, [
            {pool, false}
        ]
    ),
    ?assertEqual(404, S2).

%%--------------------------------------------------------------------
%% Data endpoint (signed URLs, no bearer auth)
%%--------------------------------------------------------------------

fetch_url(World) ->
    {200, _, Body} = get_json(reconstruction_path("/api/v1/reconstructions/", World), []),
    XorbHashStr = xet_hash:to_string(maps:get(hash, maps:get(xorb, World))),
    #{XorbHashStr := [Fetch]} = maps:get(<<"fetch_info">>, Body),
    {maps:get(<<"url">>, Fetch), maps:get(<<"url_range">>, Fetch)}.

raw_get(Url, Headers) ->
    {ok, Status, RespHeaders, Body} = hackney:request(get, Url, Headers, <<>>, [
        with_body, {pool, false}
    ]),
    {Status, RespHeaders, Body}.

data_roundtrip(_Config) ->
    World = registered_file([70, 71, 72]),
    {Url, UrlRange} = fetch_url(World),
    {200, Headers, Body} = raw_get(Url, []),
    Stored = maps:get(bin, maps:get(xorb, World)),
    ?assertEqual(Stored, Body),
    HashStr = xet_hash:to_string(maps:get(hash, maps:get(xorb, World))),
    ?assertEqual(<<"\"", HashStr/binary, "\"">>, proplists:get_value(<<"etag">>, Headers)),
    CacheControl = proplists:get_value(<<"cache-control">>, Headers),
    <<"public, immutable, max-age=", AgeBin/binary>> = CacheControl,
    Age = binary_to_integer(AgeBin),
    ?assert(Age > 0 andalso Age =< 900),
    ?assertNotEqual(undefined, proplists:get_value(<<"expires">>, Headers)),
    %% Fetch exactly the advertised url_range: the chunk region parses.
    RangeHeader = iolist_to_binary(
        io_lib:format("bytes=~b-~b", [
            maps:get(<<"start">>, UrlRange), maps:get(<<"end">>, UrlRange)
        ])
    ),
    {206, RangeHeaders, Region} = raw_get(Url, [{<<"range">>, RangeHeader}]),
    ?assertNotEqual(undefined, proplists:get_value(<<"content-range">>, RangeHeaders)),
    {ok, Chunks} = xet_xorb:parse_chunk_stream(Region),
    ?assertEqual(length(maps:get(entries, World)), length(Chunks)).

data_range(_Config) ->
    World = registered_file([73, 74]),
    {Url, _} = fetch_url(World),
    Stored = maps:get(bin, maps:get(xorb, World)),
    {206, _, Slice} = raw_get(Url, [{<<"range">>, <<"bytes=10-99">>}]),
    ?assertEqual(binary:part(Stored, 10, 90), Slice),
    {206, _, Tail} = raw_get(Url, [{<<"range">>, <<"bytes=-25">>}]),
    ?assertEqual(binary:part(Stored, byte_size(Stored) - 25, 25), Tail),
    %% End clamps at EOF.
    {206, _, Clamped} = raw_get(Url, [
        {<<"range">>, iolist_to_binary(io_lib:format("bytes=~b-99999999", [byte_size(Stored) - 5]))}
    ]),
    ?assertEqual(binary:part(Stored, byte_size(Stored) - 5, 5), Clamped).

data_forbidden(_Config) ->
    World = registered_file([75]),
    {Url, _} = fetch_url(World),
    %% Tampered signature.
    {403, _, _} = raw_get(binary:replace(Url, <<"&sig=">>, <<"&sig=x">>), []),
    %% Expired but correctly signed URL.
    Env = xet_server:env(xet_api_server),
    Secret = maps:get(url_secret, maps:get(config, Env)),
    HashStr = xet_hash:to_string(maps:get(hash, maps:get(xorb, World))),
    Past = erlang:system_time(second) - 10,
    Sig = xet_url_signer:sign(Secret, <<"default">>, HashStr, Past),
    Expired = iolist_to_binary([
        base(),
        "/api/v1/xorbs/default/",
        HashStr,
        "/data?exp=",
        integer_to_binary(Past),
        "&sig=",
        Sig
    ]),
    {403, _, Body} = raw_get(Expired, []),
    ?assertEqual(#{<<"error">> => <<"expired">>}, json:decode(Body)),
    %% Missing signature entirely.
    Bare = hd(binary:split(Url, <<"?">>)),
    {403, _, _} = raw_get(Bare, []).

data_errors(_Config) ->
    World = registered_file([76]),
    {Url, _} = fetch_url(World),
    {416, _, _} = raw_get(Url, [{<<"range">>, <<"bytes=99999999-100000000">>}]),
    %% Correctly signed URL for a hash that does not exist.
    Env = xet_server:env(xet_api_server),
    Secret = maps:get(url_secret, maps:get(config, Env)),
    Ghost = xet_hash:to_string(<<424242:256>>),
    Exp = erlang:system_time(second) + 100,
    Sig = xet_url_signer:sign(Secret, <<"default">>, Ghost, Exp),
    Missing = iolist_to_binary([
        base(),
        "/api/v1/xorbs/default/",
        Ghost,
        "/data?exp=",
        integer_to_binary(Exp),
        "&sig=",
        Sig
    ]),
    {404, _, _} = raw_get(Missing, []).

%% Without an explicit url_secret, the secret is persisted in metadata:
%% a signature issued before a restart verifies after it. An explicit
%% config secret takes precedence over the persisted one.
url_secret_survives_restart(Config) ->
    DataDir = filename:join(proplists:get_value(priv_dir, Config), "secret"),
    ServerCfg = #{
        name => xet_secret_server,
        data_dir => DataDir,
        auth => {xet_auth_static, #{tokens => #{?TOKEN => write}}}
    },
    {ok, _} = xet_server:start(ServerCfg),
    Enc = sample_xorb([90, 91]),
    HashStr = xet_hash:to_string(maps:get(hash, Enc)),
    Base1 = "http://127.0.0.1:" ++ integer_to_list(xet_server:port(xet_secret_server)),
    {200, _} = post_xorb(Base1, path_for(Enc), maps:get(bin, Enc)),
    Env1 = xet_server:env(xet_secret_server),
    Secret1 = maps:get(url_secret, maps:get(config, Env1)),
    %% The resolved secret is the persisted one.
    ?assertEqual({ok, Secret1}, xet_metadata:get_url_secret(maps:get(metadata, Env1))),
    Exp = erlang:system_time(second) + 600,
    Sig = xet_url_signer:sign(Secret1, <<"default">>, HashStr, Exp),
    ok = xet_server:stop(xet_secret_server),
    {ok, _} = xet_server:start(ServerCfg),
    %% Signatures are over ns, hash and expiry, not host and port, so the
    %% pre-restart signature is checked against the rebound listener.
    {200, _, Body} = raw_get(data_url(xet_secret_server, HashStr, Exp, Sig), []),
    ?assertEqual(maps:get(bin, Enc), Body),
    ok = xet_server:stop(xet_secret_server),
    %% Explicit config beats the persisted secret: the old signature dies.
    {ok, _} = xet_server:start(ServerCfg#{url_secret => binary:copy(<<"e">>, 32)}),
    try
        {403, _, _} = raw_get(data_url(xet_secret_server, HashStr, Exp, Sig), [])
    after
        ok = xet_server:stop(xet_secret_server)
    end.

%% Each signed URL gets its own bucket: hammering one URL trips 429
%% while a second URL for the same xorb still serves, and sig-less
%% requests pass the limiter to die on the handler's 403.
data_ratelimited_per_url(Config) ->
    DataDir = filename:join(proplists:get_value(priv_dir, Config), "dratelimit"),
    {ok, _} = xet_server:start(#{
        name => xet_drl_server,
        data_dir => DataDir,
        data_ratelimit => #{capacity => 2, per_second => 0.001},
        auth => {xet_auth_static, #{tokens => #{?TOKEN => write}}}
    }),
    try
        Enc = sample_xorb([95, 96]),
        HashStr = xet_hash:to_string(maps:get(hash, Enc)),
        Base = "http://127.0.0.1:" ++ integer_to_list(xet_server:port(xet_drl_server)),
        {200, _} = post_xorb(Base, path_for(Enc), maps:get(bin, Enc)),
        Secret = maps:get(url_secret, maps:get(config, xet_server:env(xet_drl_server))),
        Exp1 = erlang:system_time(second) + 600,
        Exp2 = Exp1 + 1,
        Url1 = data_url(
            xet_drl_server, HashStr, Exp1, xet_url_signer:sign(Secret, <<"default">>, HashStr, Exp1)
        ),
        Url2 = data_url(
            xet_drl_server, HashStr, Exp2, xet_url_signer:sign(Secret, <<"default">>, HashStr, Exp2)
        ),
        Statuses = [element(1, raw_get(Url1, [])) || _ <- lists:seq(1, 5)],
        ?assertEqual(200, hd(Statuses)),
        ?assert(lists:member(429, Statuses)),
        %% A different signed URL is its own bucket.
        {200, _, _} = raw_get(Url2, []),
        %% No signature: the limiter passes, the handler rejects.
        Bare = hd(binary:split(Url1, <<"?">>)),
        {403, _, _} = raw_get(Bare, [])
    after
        ok = xet_server:stop(xet_drl_server)
    end.

data_url(Name, HashStr, Exp, Sig) ->
    iolist_to_binary([
        "http://127.0.0.1:",
        integer_to_list(xet_server:port(Name)),
        "/api/v1/xorbs/default/",
        HashStr,
        "/data?exp=",
        integer_to_binary(Exp),
        "&sig=",
        Sig
    ]).

%%--------------------------------------------------------------------
%% Global dedup chunks endpoint
%%--------------------------------------------------------------------

get_chunk(HashStr) ->
    {ok, Status, Headers, Body} = hackney:request(
        get,
        base() ++ "/api/v1/chunks/default-merkledb/" ++ binary_to_list(HashStr),
        [{<<"authorization">>, <<"Bearer ", ?TOKEN/binary>>}],
        <<>>,
        [with_body, {pool, false}]
    ),
    {Status, Headers, Body}.

chunk_dedup_flow(_Config) ->
    World = registered_file([80, 81, 82]),
    [{FirstHash, _} | _] = maps:get(entries, World),
    {200, Headers, Body} = get_chunk(xet_hash:to_string(FirstHash)),
    ?assertEqual(
        <<"private, max-age=3600">>, proplists:get_value(<<"cache-control">>, Headers)
    ),
    ?assertEqual(<<"authorization">>, proplists:get_value(<<"vary">>, Headers)),
    ?assertEqual(
        <<"application/octet-stream">>, proplists:get_value(<<"content-type">>, Headers)
    ),
    {ok, Shard} = xet_shard:decode(Body),
    Footer = maps:get(footer, Shard),
    ?assertNotEqual(xet_hash:zero_hash(), maps:get(chunk_hash_key, Footer)),
    ?assert(maps:get(key_expiry, Footer) > erlang:system_time(second)),
    %% Client-side matching with the raw (unkeyed) chunk hash.
    ?assertEqual(
        {ok, #{cas_hash => maps:get(hash, maps:get(xorb, World)), chunk_index => 0}},
        xet_dedup:match(Shard, FirstHash)
    ),
    %% Raw hashes never appear on the wire.
    ?assertEqual(nomatch, binary:match(Body, FirstHash)).

chunk_miss(_Config) ->
    {404, _, _} = get_chunk(xet_hash:to_string(<<987654:256>>)).

%% An upload (plus a dedup re-post) and a shard registration bump the
%% domain counters, which appear in the default-on metrics scrape.
metrics_counters(_Config) ->
    _World = registered_file([120, 121, 122]),
    Enc = sample_xorb([120, 121, 122]),
    %% Same xorb again: a dedup hit.
    {200, _} = post_xorb(base(), path_for(Enc), maps:get(bin, Enc)),
    {ok, 200, _, Body} = hackney:request(
        get,
        base() ++ "/metrics",
        [{<<"authorization">>, <<"Bearer ", ?TOKEN/binary>>}],
        <<>>,
        [with_body, {pool, false}]
    ),
    Present = fun(Name) -> ?assertNotEqual(nomatch, binary:match(Body, Name)) end,
    Present(<<"xet.xorbs.uploaded">>),
    Present(<<"xet.xorbs.uploaded.bytes">>),
    Present(<<"xet.xorbs.dedup_hits">>),
    Present(<<"xet.shards.registered">>),
    Present(<<"xet.files.registered">>).

%% An impossibly large min_free_bytes makes the preflight reject uploads
%% with 507 and turns /readyz to 503 listing "disk".
insufficient_storage(Config) ->
    DataDir = filename:join(proplists:get_value(priv_dir, Config), "nospace"),
    {ok, _} = xet_server:start(#{
        name => xet_nospace_server,
        data_dir => DataDir,
        min_free_bytes => 1 bsl 60,
        auth => {xet_auth_static, #{tokens => #{?TOKEN => write}}}
    }),
    try
        Base = "http://127.0.0.1:" ++ integer_to_list(xet_server:port(xet_nospace_server)),
        Enc = sample_xorb([140, 141]),
        {Status, Body} = post_xorb(Base, path_for(Enc), maps:get(bin, Enc)),
        ?assertEqual(507, Status),
        ?assertEqual(#{<<"error">> => <<"insufficient_storage">>}, json:decode(Body)),
        {ok, 503, _, RBody} = hackney:request(
            get, Base ++ "/readyz", [], <<>>, [with_body, {pool, false}]
        ),
        ?assert(lists:member(<<"disk">>, maps:get(<<"failed">>, json:decode(RBody))))
    after
        ok = xet_server:stop(xet_nospace_server)
    end.

%% An upload (FS put) and a chunk query populate the store-op and chunk
%% metrics, labeled with the fs backend. Note the FS /data endpoint
%% streams the file via local_path, not get_range, so read bytes are
%% exercised on the s3 backend instead (store_metrics_labeled there).
metrics_store_and_chunks(_Config) ->
    World = registered_file([130, 131, 132]),
    [{FirstHash, _} | _] = maps:get(entries, World),
    {200, _, _} = get_chunk(xet_hash:to_string(FirstHash)),
    {ok, 200, _, Body} = hackney:request(
        get,
        base() ++ "/metrics",
        [{<<"authorization">>, <<"Bearer ", ?TOKEN/binary>>}],
        <<>>,
        [with_body, {pool, false}]
    ),
    Present = fun(Name) -> ?assertNotEqual(nomatch, binary:match(Body, Name)) end,
    Present(<<"xet.store.op.duration">>),
    Present(<<"xet.store.write.bytes">>),
    Present(<<"backend=\"fs\"">>),
    Present(<<"xet.chunks.queries">>),
    Present(<<"xet.chunks.hits">>).

key_rotation(_Config) ->
    World = registered_file([83, 84]),
    [{FirstHash, _} | _] = maps:get(entries, World),
    HashStr = xet_hash:to_string(FirstHash),
    {200, _, Body1} = get_chunk(HashStr),
    ok = xet_keys:rotate(xet_api_server),
    {200, _, Body2} = get_chunk(HashStr),
    {ok, Shard1} = xet_shard:decode(Body1),
    {ok, Shard2} = xet_shard:decode(Body2),
    Key1 = maps:get(chunk_hash_key, maps:get(footer, Shard1)),
    Key2 = maps:get(chunk_hash_key, maps:get(footer, Shard2)),
    ?assertNotEqual(Key1, Key2),
    %% Both generations of the response match the same original chunk.
    ?assertMatch({ok, _}, xet_dedup:match(Shard1, FirstHash)),
    ?assertMatch({ok, _}, xet_dedup:match(Shard2, FirstHash)),
    %% The rotated ring is persisted with the old key as previous.
    Env = xet_server:env(xet_api_server),
    {ok, Ring} = xet_metadata:get_key_ring(maps:get(metadata, Env)),
    ?assertEqual(Key2, maps:get(key, maps:get(current, Ring))),
    ?assertEqual(Key1, maps:get(key, maps:get(previous, Ring))).

%% Any single corrupted byte outside the ignorable nonce yields 400; a
%% nonce flip is indistinguishable content and lands 200.
%% A fresh xorb per iteration: a nonce-region flip legitimately stores
%% the xorb, so reusing one path would let a later corrupt POST hit the
%% idempotent "already exists" short-circuit and wrongly pass.
corruption_property(_Config) ->
    Forall = proper:forall(
        {proper_types:integer(1000, 1 bsl 30), proper_types:integer(0, 1 bsl 30)},
        fun({Seed, PosSeed}) ->
            Enc = sample_xorb([Seed, Seed + 1]),
            Bin = maps:get(bin, Enc),
            Size = byte_size(Bin),
            Pos = PosSeed rem Size,
            NonceStart = Size - 20,
            <<Before:Pos/binary, Byte, After/binary>> = Bin,
            Flipped = <<Before/binary, (Byte bxor 255), After/binary>>,
            {Status, _} = post_xorb(base(), path_for(Enc), Flipped),
            case Pos >= NonceStart andalso Pos < NonceStart + 4 of
                true -> Status =:= 200;
                false -> Status =:= 400
            end
        end
    ),
    ?assert(proper:quickcheck(Forall, [{numtests, 30}, noshrink, quiet])).
