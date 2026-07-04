-module(xet_store_fs_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    roundtrip/1,
    stream_put/1,
    idempotent_put_and_delete/1,
    concurrent_same_hash_puts/1,
    bad_ranges/1,
    missing_blob/1,
    tmp_sweep/1,
    namespace_guard/1
]).

-define(NS, <<"default">>).

all() ->
    [
        roundtrip,
        stream_put,
        idempotent_put_and_delete,
        concurrent_same_hash_puts,
        bad_ranges,
        missing_blob,
        tmp_sweep,
        namespace_guard
    ].

init_per_testcase(Case, Config) ->
    Dir = filename:join(proplists:get_value(priv_dir, Config), atom_to_list(Case)),
    {ok, Store} = xet_blob_store:open(xet_store_fs, #{dir => Dir}),
    [{store, Store}, {dir, Dir} | Config].

end_per_testcase(_Case, _Config) ->
    ok.

store(Config) -> proplists:get_value(store, Config).

roundtrip(Config) ->
    Store = store(Config),
    Data = xet_test_vectors:splitmix64_data(100000, 1),
    Hash = <<1:256>>,
    ok = xet_blob_store:put(Store, ?NS, Hash, Data),
    ?assert(xet_blob_store:exists(Store, ?NS, Hash)),
    ?assertEqual({ok, 100000}, xet_blob_store:size(Store, ?NS, Hash)),
    ?assertEqual({ok, Data}, xet_blob_store:get_range(Store, ?NS, Hash, 0, 100000)),
    ?assertEqual(
        {ok, binary:part(Data, 5000, 250)},
        xet_blob_store:get_range(Store, ?NS, Hash, 5000, 250)
    ),
    ?assertEqual(
        {ok, binary:part(Data, 99999, 1)},
        xet_blob_store:get_range(Store, ?NS, Hash, 99999, 1)
    ).

stream_put(Config) ->
    Store = store(Config),
    Parts = [xet_test_vectors:splitmix64_data(30000, I) || I <- [1, 2, 3]],
    Producer = producer(Parts),
    ok = xet_blob_store:put(Store, ?NS, <<2:256>>, {stream, Producer}),
    ?assertEqual(
        {ok, list_to_binary(Parts)},
        xet_blob_store:get_range(Store, ?NS, <<2:256>>, 0, 90000)
    ).

producer([]) ->
    fun() -> eof end;
producer([Part | Rest]) ->
    fun() -> {ok, Part, producer(Rest)} end.

idempotent_put_and_delete(Config) ->
    Store = store(Config),
    Data = <<"same bytes">>,
    ok = xet_blob_store:put(Store, ?NS, <<3:256>>, Data),
    ok = xet_blob_store:put(Store, ?NS, <<3:256>>, Data),
    ?assertEqual({ok, Data}, xet_blob_store:get_range(Store, ?NS, <<3:256>>, 0, byte_size(Data))),
    ok = xet_blob_store:delete(Store, ?NS, <<3:256>>),
    ok = xet_blob_store:delete(Store, ?NS, <<3:256>>),
    ?assertNot(xet_blob_store:exists(Store, ?NS, <<3:256>>)).

concurrent_same_hash_puts(Config) ->
    Store = store(Config),
    Data = xet_test_vectors:splitmix64_data(200000, 9),
    Hash = <<4:256>>,
    Parent = self(),
    Pids = [
        spawn_link(fun() ->
            Result = xet_blob_store:put(Store, ?NS, Hash, Data),
            Parent ! {done, self(), Result}
        end)
     || _ <- lists:seq(1, 10)
    ],
    Results = [
        receive
            {done, Pid, R} -> R
        after 10000 -> timeout
        end
     || Pid <- Pids
    ],
    ?assertEqual(lists:duplicate(10, ok), Results),
    ?assertEqual({ok, Data}, xet_blob_store:get_range(Store, ?NS, Hash, 0, 200000)),
    %% No stray tmp files left behind.
    Dir = proplists:get_value(dir, Config),
    ?assertEqual([], filelib:wildcard(filename:join([Dir, "**", "*.tmp"]))).

bad_ranges(Config) ->
    Store = store(Config),
    ok = xet_blob_store:put(Store, ?NS, <<5:256>>, <<"0123456789">>),
    ?assertEqual({error, bad_range}, xet_blob_store:get_range(Store, ?NS, <<5:256>>, 5, 100)),
    ?assertEqual({error, bad_range}, xet_blob_store:get_range(Store, ?NS, <<5:256>>, 10, 1)),
    ?assertEqual({ok, <<"9">>}, xet_blob_store:get_range(Store, ?NS, <<5:256>>, 9, 1)).

missing_blob(Config) ->
    Store = store(Config),
    ?assertEqual({error, not_found}, xet_blob_store:get_range(Store, ?NS, <<6:256>>, 0, 1)),
    ?assertEqual({error, not_found}, xet_blob_store:size(Store, ?NS, <<6:256>>)),
    ?assertNot(xet_blob_store:exists(Store, ?NS, <<6:256>>)).

tmp_sweep(Config) ->
    Dir = proplists:get_value(dir, Config),
    Stale = filename:join([Dir, "default", "aa", "bb", "stale.w1.tmp"]),
    ok = filelib:ensure_dir(Stale),
    ok = file:write_file(Stale, <<"junk">>),
    {ok, _Store} = xet_blob_store:open(xet_store_fs, #{dir => Dir}),
    ?assertNot(filelib:is_regular(Stale)).

namespace_guard(Config) ->
    Store = store(Config),
    ?assertEqual(
        {error, bad_namespace},
        xet_blob_store:put(Store, <<"../evil">>, <<7:256>>, <<"x">>)
    ),
    ?assertEqual(
        {error, bad_namespace},
        xet_blob_store:put(Store, <<"UPPER">>, <<7:256>>, <<"x">>)
    ),
    ?assertEqual({error, bad_namespace}, xet_blob_store:put(Store, <<>>, <<7:256>>, <<"x">>)),
    ok = xet_blob_store:put(Store, <<"default-merkledb">>, <<7:256>>, <<"x">>).
