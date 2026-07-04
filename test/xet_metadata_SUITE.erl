-module(xet_metadata_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    xorb_roundtrip/1,
    file_and_chunk_roundtrip/1,
    missing_lookups/1,
    reopen_persistence/1,
    key_ring/1,
    schema_guard/1,
    stats/1
]).

all() ->
    [
        xorb_roundtrip,
        file_and_chunk_roundtrip,
        missing_lookups,
        reopen_persistence,
        key_ring,
        schema_guard,
        stats
    ].

init_per_testcase(Case, Config) ->
    Dir = filename:join(
        proplists:get_value(priv_dir, Config),
        atom_to_list(Case)
    ),
    {ok, Db} = xet_metadata:open(xet_metadata_rocksdb, #{dir => Dir}),
    [{db, Db}, {dir, Dir} | Config].

%% Cases that exercise reopening close their own handle; closing twice
%% is not an error worth failing teardown over.
end_per_testcase(_Case, Config) ->
    try
        xet_metadata:close(proplists:get_value(db, Config))
    catch
        _:_ -> ok
    end,
    ok.

db(Config) -> proplists:get_value(db, Config).

xorb_meta(N) ->
    #{
        hash => <<N:256>>,
        entries => [{<<(N + I):256>>, 100 + I} || I <- lists:seq(1, 3)],
        boundary_offsets => [120, 250, 400],
        unpacked_offsets => [101, 203, 306],
        bytes_on_disk => 400
    }.

file_meta(N) ->
    #{
        file_hash => <<N:256>>,
        total_len => 1000 * N,
        terms => [
            #{
                cas_hash => <<(N + 100):256>>,
                unpacked_len => 1000 * N,
                chunk_start => 0,
                chunk_end => 3
            }
        ],
        verification => [<<(N + 200):256>>],
        sha256 => <<(N + 300):256>>
    }.

xorb_roundtrip(Config) ->
    Db = db(Config),
    Meta = xorb_meta(1),
    ok = xet_metadata:register_xorb(Db, Meta),
    ?assert(xet_metadata:xorb_exists(Db, <<1:256>>)),
    ?assertEqual({ok, Meta}, xet_metadata:get_xorb(Db, <<1:256>>)),
    %% Idempotent re-register.
    ok = xet_metadata:register_xorb(Db, Meta),
    ?assertEqual({ok, Meta}, xet_metadata:get_xorb(Db, <<1:256>>)).

file_and_chunk_roundtrip(Config) ->
    Db = db(Config),
    Files = [file_meta(1), file_meta(2)],
    Chunks = [{<<10:256>>, <<101:256>>, 0}, {<<11:256>>, <<101:256>>, 7}],
    ok = xet_metadata:register_files(Db, Files, Chunks),
    ?assert(xet_metadata:file_exists(Db, <<1:256>>)),
    ?assertEqual({ok, file_meta(2)}, xet_metadata:get_file(Db, <<2:256>>)),
    ?assertEqual({ok, {<<101:256>>, 7}}, xet_metadata:find_chunk(Db, <<11:256>>)).

missing_lookups(Config) ->
    Db = db(Config),
    ?assertEqual(not_found, xet_metadata:get_file(Db, <<99:256>>)),
    ?assertEqual(not_found, xet_metadata:get_xorb(Db, <<99:256>>)),
    ?assertEqual(not_found, xet_metadata:find_chunk(Db, <<99:256>>)),
    ?assertEqual(not_found, xet_metadata:get_key_ring(Db)),
    ?assertNot(xet_metadata:file_exists(Db, <<99:256>>)),
    ?assertNot(xet_metadata:xorb_exists(Db, <<99:256>>)).

reopen_persistence(Config) ->
    Db = db(Config),
    Dir = proplists:get_value(dir, Config),
    ok = xet_metadata:register_xorb(Db, xorb_meta(5)),
    ok = xet_metadata:register_files(Db, [file_meta(6)], [{<<7:256>>, <<5:256>>, 2}]),
    Ring = ring(1000),
    ok = xet_metadata:put_key_ring(Db, Ring),
    ok = xet_metadata:close(Db),
    {ok, Db2} = xet_metadata:open(xet_metadata_rocksdb, #{dir => Dir}),
    try
        ?assertEqual({ok, xorb_meta(5)}, xet_metadata:get_xorb(Db2, <<5:256>>)),
        ?assertEqual({ok, file_meta(6)}, xet_metadata:get_file(Db2, <<6:256>>)),
        ?assertEqual({ok, {<<5:256>>, 2}}, xet_metadata:find_chunk(Db2, <<7:256>>)),
        ?assertEqual({ok, Ring}, xet_metadata:get_key_ring(Db2))
    after
        ok = xet_metadata:close(Db2)
    end.

key_ring(Config) ->
    Db = db(Config),
    Ring1 = ring(100),
    ok = xet_metadata:put_key_ring(Db, Ring1),
    ?assertEqual({ok, Ring1}, xet_metadata:get_key_ring(Db)),
    Ring2 = (ring(200))#{previous => maps:get(current, Ring1)},
    ok = xet_metadata:put_key_ring(Db, Ring2),
    ?assertEqual({ok, Ring2}, xet_metadata:get_key_ring(Db)).

schema_guard(Config) ->
    %% A database written with a different schema version must refuse to
    %% open instead of silently misreading values.
    Dir = filename:join(proplists:get_value(dir, Config), "other"),
    {ok, Db} = xet_metadata:open(xet_metadata_rocksdb, #{dir => Dir}),
    ok = xet_metadata:close(Db),
    {ok, Handle, [_D, _F, _X, _C, Meta]} = rocksdb:open(
        Dir,
        [{create_if_missing, false}],
        [{Name, []} || Name <- ["default", "files", "xorbs", "chunks", "meta"]]
    ),
    ok = rocksdb:put(Handle, Meta, <<"schema">>, <<42>>, []),
    ok = rocksdb:close(Handle),
    ?assertMatch(
        {error, {schema_mismatch, <<42>>}},
        xet_metadata:open(xet_metadata_rocksdb, #{dir => Dir})
    ).

stats(Config) ->
    Db = db(Config),
    ok = xet_metadata:register_xorb(Db, xorb_meta(1)),
    ok = xet_metadata:register_files(Db, [file_meta(1)], [{<<10:256>>, <<1:256>>, 0}]),
    Stats = xet_metadata:stats(Db),
    ?assert(is_integer(maps:get(files, Stats))),
    ?assert(is_integer(maps:get(xorbs, Stats))),
    ?assert(is_integer(maps:get(chunks, Stats))).

ring(T) ->
    #{
        current => #{
            key => binary:copy(<<7>>, 32),
            created_at => T,
            expires_at => T + 86400
        }
    }.
