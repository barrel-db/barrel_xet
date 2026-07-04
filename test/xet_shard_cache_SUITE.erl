%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(xet_shard_cache_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    offline_dedup_second_session/1,
    keyed_shard_not_indexed/1,
    expiry_prunes/1,
    persists_across_open/1
]).

-define(TOKEN, <<"cache-token">>).

all() ->
    [
        offline_dedup_second_session,
        keyed_shard_not_indexed,
        expiry_prunes,
        persists_across_open
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started([barrel_xet, hackney]),
    DataDir = filename:join(proplists:get_value(priv_dir, Config), "cachesrv"),
    {ok, _} = xet_server:start(#{
        name => xet_cache_server,
        data_dir => DataDir,
        auth => {xet_auth_static, #{tokens => #{?TOKEN => write}}}
    }),
    Endpoint = list_to_binary(
        "http://127.0.0.1:" ++ integer_to_list(xet_server:port(xet_cache_server))
    ),
    [{endpoint, Endpoint} | Config].

end_per_suite(_Config) ->
    ok = xet_server:stop(xet_cache_server),
    ok.

%% A client whose global-dedup query counts calls, so "offline" is
%% provable: zero queries means the cache carried the whole dedup.
counting_client(Config, Counter) ->
    Endpoint = proplists:get_value(endpoint, Config),
    xet_client:new(#{
        endpoint => Endpoint,
        token => ?TOKEN,
        stack => [
            {livery_client_retry, #{max => 2, statuses => [503]}},
            counting_layer(Counter)
        ]
    }).

%% A tiny livery_client layer that bumps a counter on chunk queries.
counting_layer(Counter) ->
    fun(Req, Next) ->
        Path = maps:get(path, Req, <<>>),
        case binary:match(Path, <<"/chunks/">>) of
            nomatch -> ok;
            _ -> counters:add(Counter, 1, 1)
        end,
        Next(Req)
    end.

cache_dir(Config, Sub) ->
    filename:join(proplists:get_value(priv_dir, Config), Sub).

offline_dedup_second_session(Config) ->
    Data = xet_test_vectors:splitmix64_data(300000, 1),
    Dir = cache_dir(Config, "sess"),

    %% Session 1: upload with a cache; the upload shard is cached.
    C1 = counters:new(1, []),
    Cache1 = xet_shard_cache:open(Dir),
    Client1 = counting_client(Config, C1),
    {ok, _} = xet_client_upload:upload_files(
        Client1, [{f, Data}], #{shard_cache => Cache1}
    ),
    ?assert(xet_shard_cache:count(Cache1) > 0),
    ok = xet_shard_cache:close(Cache1),

    %% Session 2: fresh cache handle loads the shard from disk; the
    %% re-upload dedups entirely offline (no chunk queries, no new bytes).
    C2 = counters:new(1, []),
    Cache2 = xet_shard_cache:open(Dir),
    Client2 = counting_client(Config, C2),
    {ok, [#{stats := Stats}]} = xet_client_upload:upload_files(
        Client2, [{f2, Data}], #{shard_cache => Cache2}
    ),
    ok = xet_shard_cache:close(Cache2),
    ?assertEqual(0, maps:get(new_bytes, Stats)),
    ?assertEqual(0, counters:get(C2, 1)).

keyed_shard_not_indexed(Config) ->
    Dir = cache_dir(Config, "keyed"),
    Cache = xet_shard_cache:open(Dir),
    Key = binary:copy(<<7>>, 32),
    Block = #{
        cas_hash => <<1:256>>,
        bytes_on_disk => 100,
        chunks => [#{hash => <<10:256>>, size => 100, dedup_eligible => false}]
    },
    Keyed = xet_dedup:build_response([Block], #{
        chunk_hash_key => Key, created_at => 1, key_expiry => 1 bsl 40
    }),
    ok = xet_shard_cache:store(Cache, Keyed),
    %% Stored but not indexed: the raw chunk hash is not found.
    ?assertEqual(not_found, xet_shard_cache:lookup(Cache, <<10:256>>)),
    ?assertEqual(0, xet_shard_cache:count(Cache)),
    ok = xet_shard_cache:close(Cache).

expiry_prunes(Config) ->
    Dir = cache_dir(Config, "expiry"),
    %% Store an upload shard, then reopen with a zero TTL: the entry is
    %% pruned on load.
    Cache = xet_shard_cache:open(Dir),
    Shard = upload_shard(),
    ok = xet_shard_cache:store(Cache, Shard),
    ?assert(xet_shard_cache:count(Cache) > 0),
    ok = xet_shard_cache:close(Cache),
    Reopened = xet_shard_cache:open(Dir, #{ttl => -1}),
    ?assertEqual(0, xet_shard_cache:count(Reopened)),
    ?assertEqual([], filelib:wildcard(filename:join(Dir, "*.shard"))),
    ok = xet_shard_cache:close(Reopened).

persists_across_open(Config) ->
    Dir = cache_dir(Config, "persist"),
    Cache = xet_shard_cache:open(Dir),
    ok = xet_shard_cache:store(Cache, upload_shard()),
    ok = xet_shard_cache:close(Cache),
    Reopened = xet_shard_cache:open(Dir),
    ?assertEqual({ok, {<<100:256>>, 1}}, xet_shard_cache:lookup(Reopened, <<21:256>>)),
    ok = xet_shard_cache:close(Reopened).

%% An upload-form shard with two raw chunks in one CAS block.
upload_shard() ->
    Cas = #{
        cas_hash => <<100:256>>,
        bytes_on_disk => 500,
        chunks => [
            #{hash => <<20:256>>, size => 200, dedup_eligible => false},
            #{hash => <<21:256>>, size => 300, dedup_eligible => false}
        ]
    },
    File = #{
        file_hash => <<200:256>>,
        terms => [
            #{cas_hash => <<100:256>>, unpacked_len => 500, chunk_start => 0, chunk_end => 2}
        ]
    },
    xet_shard:encode_upload(#{files => [File], cas => [Cas]}).
