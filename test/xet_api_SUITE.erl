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
    shard_bare_alias/1
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
        shard_bare_alias
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
        [with_body]
    ),
    {Status, RespBody}.

head_xorb(Base, Path) ->
    {ok, Status, _} = hackney:request(
        head,
        Base ++ Path,
        [{<<"authorization">>, <<"Bearer ", ?TOKEN/binary>>}],
        <<>>,
        []
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
        post, base() ++ path_for(Enc), [], maps:get(bin, Enc), [with_body]
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
        [with_body]
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

%% Any single corrupted byte outside the ignorable nonce yields 400; a
%% nonce flip is indistinguishable content and lands 200.
corruption_property(_Config) ->
    Enc = sample_xorb([30, 31]),
    Bin = maps:get(bin, Enc),
    Size = byte_size(Bin),
    NonceStart = Size - 20,
    Path = path_for(Enc),
    Forall = proper:forall(proper_types:integer(0, Size - 1), fun(Pos) ->
        <<Before:Pos/binary, Byte, After/binary>> = Bin,
        Flipped = <<Before/binary, (Byte bxor 255), After/binary>>,
        {Status, _} = post_xorb(base(), Path, Flipped),
        case Pos >= NonceStart andalso Pos < NonceStart + 4 of
            true -> Status =:= 200;
            false -> Status =:= 400
        end
    end),
    ?assert(proper:quickcheck(Forall, [{numtests, 30}, noshrink, quiet])).
