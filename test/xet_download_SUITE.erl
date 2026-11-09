%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(xet_download_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    full_roundtrip_sizes/1,
    repetitive_data/1,
    random_ranges/1,
    download_to_file/1,
    file_hash_mismatch_detected/1,
    expired_url_requery/1,
    v2_multi_entry/1,
    fetch_retry/1
]).

-define(TOKEN, <<"dl-token">>).

all() ->
    [
        full_roundtrip_sizes,
        repetitive_data,
        random_ranges,
        download_to_file,
        file_hash_mismatch_detected,
        expired_url_requery,
        v2_multi_entry,
        fetch_retry
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started([barrel_xet, hackney]),
    DataDir = filename:join(proplists:get_value(priv_dir, Config), "dl"),
    {ok, _} = xet_server:start(#{
        name => xet_dl_server,
        data_dir => DataDir,
        %% Short URL TTL so the expired-URL path is reachable.
        url_ttl => 2,
        auth => {xet_auth_static, #{tokens => #{?TOKEN => write}}}
    }),
    Endpoint = list_to_binary(
        "http://127.0.0.1:" ++ integer_to_list(xet_server:port(xet_dl_server))
    ),
    [{endpoint, Endpoint} | Config].

end_per_suite(_Config) ->
    ok = xet_server:stop(xet_dl_server),
    ok.

client(Config) ->
    xet_client:new(#{endpoint => proplists:get_value(endpoint, Config), token => ?TOKEN}).

upload(Client, Id, Data) ->
    {ok, #{file_hash := FileHash}} = xet_client_upload:upload_data(Client, Id, Data),
    FileHash.

full_roundtrip_sizes(Config) ->
    Client = client(Config),
    Sizes = [0, 1, 100, 8191, 8192, 131072, 300000, 2000000],
    lists:foreach(
        fun({I, Size}) ->
            Data = xet_test_vectors:splitmix64_data(Size, 1000 + I),
            FileHash = upload(Client, {size, Size}, Data),
            ?assertEqual({ok, Data}, xet_client_download:download_data(Client, FileHash))
        end,
        lists:zip(lists:seq(1, length(Sizes)), Sizes)
    ).

repetitive_data(Config) ->
    Client = client(Config),
    Data = binary:copy(<<"the same block over and over ">>, 100000),
    FileHash = upload(Client, repetitive, Data),
    ?assertEqual({ok, Data}, xet_client_download:download_data(Client, FileHash)).

random_ranges(Config) ->
    Client = client(Config),
    Data = xet_test_vectors:splitmix64_data(1500000, 55),
    FileHash = upload(Client, ranged, Data),
    Total = byte_size(Data),
    Cases = [
        {0, 0},
        {0, Total - 1},
        {1, 500},
        {100000, 400000},
        {Total - 100, Total - 1},
        {Total div 2, Total div 2 + 262144}
    ],
    lists:foreach(
        fun({Start, End}) ->
            {ok, Got} = xet_client_download:download_range(Client, FileHash, {Start, End}),
            ClampedEnd = min(End, Total - 1),
            Expected = binary:part(Data, Start, ClampedEnd - Start + 1),
            ?assertEqual(Expected, Got)
        end,
        Cases
    ).

download_to_file(Config) ->
    Client = client(Config),
    Data = xet_test_vectors:splitmix64_data(500000, 77),
    FileHash = upload(Client, tofile, Data),
    Out = filename:join(proplists:get_value(priv_dir, Config), "out.bin"),
    ok = xet_client_download:download_file(Client, FileHash, Out),
    ?assertEqual({ok, Data}, file:read_file(Out)).

%% A file registered with a wrong file hash must fail verification on a
%% full download rather than return corrupt bytes. The server refuses such
%% a shard, so the forged entry is written straight into its metadata,
%% standing in for a hostile or buggy server.
file_hash_mismatch_detected(Config) ->
    Client = client(Config),
    Data = xet_test_vectors:splitmix64_data(200000, 88),
    Chunks = xet_chunker:split(Data),
    {ok, Enc} = xet_xorb:encode(Chunks, #{nonce => <<0, 0, 0, 0>>}),
    Hash = maps:get(hash, Enc),
    {ok, _} = xet_client:upload_xorb(Client, <<"default">>, Hash, maps:get(bin, Enc)),
    Entries = lists:zip(maps:get(chunk_hashes, Enc), maps:get(unpacked_sizes, Enc)),
    N = length(Entries),
    WrongHash = <<123456789:256>>,
    File = #{
        file_hash => WrongHash,
        terms => [
            #{cas_hash => Hash, unpacked_len => byte_size(Data), chunk_start => 0, chunk_end => N}
        ],
        verification => [xet_hash:verification_hash([H || {H, _} <- Entries])]
    },
    ShardBin = xet_shard:encode_upload(#{files => [File], cas => []}),
    ?assertMatch({error, _}, xet_client:upload_shard(Client, ShardBin)),
    #{metadata := Metadata} = xet_server:env(xet_dl_server),
    Meta = #{file_hash => WrongHash, total_len => byte_size(Data), terms => maps:get(terms, File)},
    ok = xet_metadata:register_files(Metadata, [Meta], []),
    ?assertEqual(
        {error, file_hash_mismatch},
        xet_client_download:download_data(Client, WrongHash)
    ).

%% With a 2 s URL TTL, sleeping past it forces the fetch to 403; the
%% pipeline re-queries reconstruction once and still succeeds.
expired_url_requery(Config) ->
    Client = client(Config),
    Data = xet_test_vectors:splitmix64_data(300000, 99),
    FileHash = upload(Client, expiring, Data),
    {ok, Recon} = xet_client:get_reconstruction(Client, FileHash),
    [{_CasStr, [#{<<"url">> := Url}]} | _] = maps:to_list(maps:get(<<"xorbs">>, Recon)),
    timer:sleep(3000),
    %% The captured URL is now expired.
    {ok, 403, _, _} = hackney:request(get, Url, [], <<>>, [with_body, {pool, false}]),
    %% The pipeline re-queries and recovers.
    ?assertEqual({ok, Data}, xet_client_download:download_data(Client, FileHash)).

%%--------------------------------------------------------------------
%% Against a fake CAS (canned V2 reconstruction, ranged xorb fetches)
%%--------------------------------------------------------------------

%% A V2 xorb listing several fetch entries is fully fetched, not dropped
%% (other servers split one xorb across entries).
v2_multi_entry(_Config) ->
    with_fake_cas(fun(Fake, Client, FileHash, Data) ->
        _ = Fake,
        ?assertEqual({ok, Data}, xet_client_download:download_data(Client, FileHash))
    end).

%% Transient 5xx on a xorb fetch is retried (spec 12.7); a persistent one
%% surfaces once the retry budget is spent.
fetch_retry(_Config) ->
    with_fake_cas(fun(Fake, Client, FileHash, Data) ->
        ok = xet_fake_s3:fail_next_ranged(Fake, 1, 503),
        ?assertEqual({ok, Data}, xet_client_download:download_data(Client, FileHash)),
        ok = xet_fake_s3:fail_next_ranged(Fake, 100, 503),
        ?assertMatch({error, _}, xet_client_download:download_data(Client, FileHash)),
        ok = xet_fake_s3:fail_next_ranged(Fake, 0, 503)
    end).

with_fake_cas(Fun) ->
    {ok, Fake} = xet_fake_s3:start(),
    try
        Base = <<"http://127.0.0.1:", (integer_to_binary(maps:get(port, Fake)))/binary>>,
        {FileHash, Data} = seed_fake_cas(Fake, Base),
        Client = xet_client:new(#{
            endpoint => Base, fetch_retry => #{max => 2, backoff => {10, 1.0}}
        }),
        Fun(Fake, Client, FileHash, Data)
    after
        xet_fake_s3:stop(Fake)
    end.

%% One 4-chunk xorb, served as two V2 fetch entries of two chunks each.
seed_fake_cas(Fake, Base) ->
    Chunks = [xet_test_vectors:splitmix64_data(9000 + I, I) || I <- lists:seq(1, 4)],
    {ok, Enc} = xet_xorb:encode(Chunks, #{nonce => <<0, 0, 0, 0>>}),
    ok = xet_fake_s3:put_object(Fake, <<"x/xorb">>, maps:get(bin, Enc)),
    Entries = lists:zip(maps:get(chunk_hashes, Enc), maps:get(unpacked_sizes, Enc)),
    FileHash = xet_hash:file_hash(Entries),
    CasStr = xet_hash:to_string(maps:get(hash, Enc)),
    Data = iolist_to_binary(Chunks),
    Boundaries = maps:get(boundary_offsets, Enc),
    Recon = #{
        offset_into_first_range => 0,
        terms => [
            #{
                hash => CasStr,
                range => #{start => 0, 'end' => 4},
                unpacked_length => byte_size(Data)
            }
        ],
        xorbs => #{
            CasStr => [fetch_entry(Base, Boundaries, R) || R <- [{0, 2}, {2, 4}]]
        }
    },
    Path = <<"api/v2/reconstructions/", (xet_hash:to_string(FileHash))/binary>>,
    ok = xet_fake_s3:put_object(Fake, Path, iolist_to_binary(json:encode(Recon))),
    {FileHash, Data}.

fetch_entry(Base, Boundaries, {S, E} = Range) ->
    {BS, BE} = xet_xorb:chunk_byte_range(Boundaries, Range),
    #{
        url => <<Base/binary, "/x/xorb">>,
        ranges => [#{chunks => #{start => S, 'end' => E}, bytes => #{start => BS, 'end' => BE - 1}}]
    }.
