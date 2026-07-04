-module(xet_chunk_cache_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    hit_avoids_network/1,
    range_partial_miss/1,
    crc_detects_corruption/1,
    eviction_respects_cap/1,
    persists_across_open/1
]).

-define(TOKEN, <<"chunkcache-token">>).

all() ->
    [
        hit_avoids_network,
        range_partial_miss,
        crc_detects_corruption,
        eviction_respects_cap,
        persists_across_open
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started([barrel_xet, hackney]),
    DataDir = filename:join(proplists:get_value(priv_dir, Config), "ccsrv"),
    {ok, _} = xet_server:start(#{
        name => xet_cc_server,
        data_dir => DataDir,
        auth => {xet_auth_static, #{tokens => #{?TOKEN => write}}}
    }),
    Endpoint = list_to_binary(
        "http://127.0.0.1:" ++ integer_to_list(xet_server:port(xet_cc_server))
    ),
    [{endpoint, Endpoint}, {server_data, DataDir} | Config].

end_per_suite(_Config) ->
    ok = xet_server:stop(xet_cc_server),
    ok.

cache_dir(Config, Sub) ->
    filename:join(proplists:get_value(priv_dir, Config), Sub).

%% Download once to fill the cache, then delete the server's blobs so any
%% network fetch would 404. A second download still succeeds: proof the
%% chunk cache served the data.
hit_avoids_network(Config) ->
    Endpoint = proplists:get_value(endpoint, Config),
    Data = xet_test_vectors:splitmix64_data(400000, 1),
    Uploader = xet_client:new(#{endpoint => Endpoint, token => ?TOKEN}),
    {ok, #{file_hash := FileHash}} = xet_client_upload:upload_data(Uploader, f, Data),

    Cache = xet_chunk_cache:open(cache_dir(Config, "hit")),
    Client = xet_client:new(#{endpoint => Endpoint, token => ?TOKEN, chunk_cache => Cache}),
    ?assertEqual({ok, Data}, xet_client_download:download_data(Client, FileHash)),
    ?assert(xet_chunk_cache:count(Cache) > 0),

    %% Wipe the server-side blobs.
    delete_blobs(Config),
    %% Without the cache the fetch now 404s...
    NoCache = xet_client:new(#{endpoint => Endpoint, token => ?TOKEN}),
    ?assertMatch({error, _}, xet_client_download:download_data(NoCache, FileHash)),
    %% ...but the cached client still reconstructs the file.
    ?assertEqual({ok, Data}, xet_client_download:download_data(Client, FileHash)),
    ok = xet_chunk_cache:close(Cache).

range_partial_miss(Config) ->
    Cache = xet_chunk_cache:open(cache_dir(Config, "partial")),
    Xorb = <<"abc">>,
    ok = xet_chunk_cache:put(Cache, Xorb, 0, <<"zero">>),
    ok = xet_chunk_cache:put(Cache, Xorb, 1, <<"one">>),
    ?assertEqual({ok, [<<"zero">>, <<"one">>]}, xet_chunk_cache:get_range(Cache, Xorb, 0, 2)),
    %% Index 2 absent: the whole range misses.
    ?assertEqual(miss, xet_chunk_cache:get_range(Cache, Xorb, 0, 3)),
    ?assertEqual(miss, xet_chunk_cache:get_range(Cache, Xorb, 2, 3)),
    ok = xet_chunk_cache:close(Cache).

crc_detects_corruption(Config) ->
    Dir = cache_dir(Config, "crc"),
    Cache = xet_chunk_cache:open(Dir),
    ok = xet_chunk_cache:put(Cache, <<"x">>, 0, <<"payload">>),
    ?assertEqual({ok, <<"payload">>}, xet_chunk_cache:get(Cache, <<"x">>, 0)),
    %% Corrupt the stored bytes on disk.
    [Path] = filelib:wildcard(filename:join([Dir, "*", "*.chunk"])),
    ok = file:write_file(Path, <<0, 0, 0, 0, "garbage">>),
    ?assertEqual(not_found, xet_chunk_cache:get(Cache, <<"x">>, 0)),
    ok = xet_chunk_cache:close(Cache).

eviction_respects_cap(Config) ->
    Dir = cache_dir(Config, "evict"),
    %% Cap of ~2 KiB with ~500-byte entries keeps only a few.
    Cache = xet_chunk_cache:open(Dir, #{size_cap => 2048}),
    Chunk = binary:copy(<<"x">>, 500),
    lists:foreach(
        fun(I) -> xet_chunk_cache:put(Cache, <<"cap">>, I, Chunk) end,
        lists:seq(0, 19)
    ),
    Count = xet_chunk_cache:count(Cache),
    ?assert(Count > 0),
    ?assert(Count =< 5),
    ok = xet_chunk_cache:close(Cache).

persists_across_open(Config) ->
    Dir = cache_dir(Config, "persist"),
    Cache = xet_chunk_cache:open(Dir),
    ok = xet_chunk_cache:put(Cache, <<"keep">>, 7, <<"data7">>),
    ok = xet_chunk_cache:close(Cache),
    Reopened = xet_chunk_cache:open(Dir),
    ?assertEqual({ok, <<"data7">>}, xet_chunk_cache:get(Reopened, <<"keep">>, 7)),
    ok = xet_chunk_cache:close(Reopened).

delete_blobs(Config) ->
    XorbDir = filename:join(proplists:get_value(server_data, Config), "xorbs"),
    lists:foreach(
        fun(Path) -> ok = file:delete(Path) end,
        filelib:wildcard(filename:join([XorbDir, "**", "*.xorb"]))
    ).
