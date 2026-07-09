%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(xet_metadata_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    xorb_roundtrip/1,
    file_and_chunk_roundtrip/1,
    missing_lookups/1,
    reopen_persistence/1,
    key_ring/1,
    url_secret/1,
    created_at_optional/1,
    schema_guard/1,
    stats/1,
    counters_no_double_count/1,
    counters_backfill/1,
    folds/1,
    delete_file/1,
    delete_xorb/1,
    checkpoint/1,
    tuned_open/1
]).

all() ->
    [
        xorb_roundtrip,
        file_and_chunk_roundtrip,
        missing_lookups,
        reopen_persistence,
        key_ring,
        url_secret,
        created_at_optional,
        schema_guard,
        stats,
        counters_no_double_count,
        counters_backfill,
        folds,
        delete_file,
        delete_xorb,
        checkpoint,
        tuned_open
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

url_secret(Config) ->
    Db = db(Config),
    ?assertEqual(not_found, xet_metadata:get_url_secret(Db)),
    Secret = crypto:strong_rand_bytes(32),
    ok = xet_metadata:put_url_secret(Db, Secret),
    ?assertEqual({ok, Secret}, xet_metadata:get_url_secret(Db)),
    %% Overwrite (explicit rotation) sticks.
    Secret2 = crypto:strong_rand_bytes(32),
    ok = xet_metadata:put_url_secret(Db, Secret2),
    ?assertEqual({ok, Secret2}, xet_metadata:get_url_secret(Db)).

%% created_at is additive: a record written without it (pre-upgrade)
%% still reads, defaulting to 0, and a record with it round-trips.
created_at_optional(Config) ->
    Db = db(Config),
    ok = xet_metadata:register_xorb(Db, xorb_meta(500)),
    {ok, Old} = xet_metadata:get_xorb(Db, <<500:256>>),
    ?assertEqual(0, maps:get(created_at, Old, 0)),
    New = (xorb_meta(501))#{created_at => 1700000000},
    ok = xet_metadata:register_xorb(Db, New),
    {ok, Got} = xet_metadata:get_xorb(Db, <<501:256>>),
    ?assertEqual(1700000000, maps:get(created_at, Got)).

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
    %% Maintained counters are exact; xorb_meta/1 carries bytes_on_disk 400.
    ?assertEqual(1, maps:get(files, Stats)),
    ?assertEqual(1, maps:get(xorbs, Stats)),
    ?assertEqual(400, maps:get(bytes_on_disk, Stats)),
    ?assert(is_integer(maps:get(chunks, Stats))).

%% Re-registering an existing xorb or file does not double-count.
counters_no_double_count(Config) ->
    Db = db(Config),
    ok = xet_metadata:register_xorb(Db, xorb_meta(1)),
    ok = xet_metadata:register_xorb(Db, xorb_meta(2)),
    ok = xet_metadata:register_files(Db, [file_meta(1), file_meta(2)], []),
    ok = xet_metadata:register_xorb(Db, xorb_meta(1)),
    ok = xet_metadata:register_files(Db, [file_meta(1)], []),
    Stats = xet_metadata:stats(Db),
    ?assertEqual(2, maps:get(xorbs, Stats)),
    ?assertEqual(2, maps:get(files, Stats)),
    ?assertEqual(800, maps:get(bytes_on_disk, Stats)).

%% fold_files and fold_xorbs visit every record, decoded with its key.
folds(Config) ->
    Db = db(Config),
    ok = xet_metadata:register_xorb(Db, xorb_meta(1)),
    ok = xet_metadata:register_xorb(Db, xorb_meta(2)),
    ok = xet_metadata:register_files(Db, [file_meta(1), file_meta(2), file_meta(3)], []),
    XorbHashes = lists:sort(
        xet_metadata:fold_xorbs(Db, fun(X, Acc) -> [maps:get(hash, X) | Acc] end, [])
    ),
    ?assertEqual([<<1:256>>, <<2:256>>], XorbHashes),
    FileCount = xet_metadata:fold_files(Db, fun(_F, N) -> N + 1 end, 0),
    ?assertEqual(3, FileCount).

%% delete_file removes the record and decrements the counter; idempotent.
delete_file(Config) ->
    Db = db(Config),
    ok = xet_metadata:register_files(Db, [file_meta(1), file_meta(2)], []),
    ok = xet_metadata:delete_file(Db, <<1:256>>),
    ?assertNot(xet_metadata:file_exists(Db, <<1:256>>)),
    ?assert(xet_metadata:file_exists(Db, <<2:256>>)),
    ?assertEqual(1, maps:get(files, xet_metadata:stats(Db))),
    %% Idempotent second delete.
    ok = xet_metadata:delete_file(Db, <<1:256>>),
    ?assertEqual(1, maps:get(files, xet_metadata:stats(Db))).

%% delete_xorb removes the xorb, its owned chunk entries, and decrements
%% counters; a chunk of the deleted xorb whose dedup index points at a
%% surviving xorb is left intact.
delete_xorb(Config) ->
    Db = db(Config),
    ok = xet_metadata:register_xorb(Db, xorb_meta(1)),
    ok = xet_metadata:register_xorb(Db, xorb_meta(2)),
    %% Both chunk hashes are in xorb 1's entries (<<2>>,<<3>>,<<4>>);
    %% one indexed to xorb 1 (owned), one to xorb 2 (shared).
    Owned = <<2:256>>,
    Shared = <<3:256>>,
    ok = xet_metadata:register_files(Db, [], [{Owned, <<1:256>>, 0}, {Shared, <<2:256>>, 9}]),
    ?assertEqual(800, maps:get(bytes_on_disk, xet_metadata:stats(Db))),
    ok = xet_metadata:delete_xorb(Db, <<1:256>>),
    ?assertNot(xet_metadata:xorb_exists(Db, <<1:256>>)),
    ?assert(xet_metadata:xorb_exists(Db, <<2:256>>)),
    ?assertEqual(1, maps:get(xorbs, xet_metadata:stats(Db))),
    ?assertEqual(400, maps:get(bytes_on_disk, xet_metadata:stats(Db))),
    ?assertEqual(not_found, xet_metadata:find_chunk(Db, Owned)),
    ?assertEqual({ok, {<<2:256>>, 9}}, xet_metadata:find_chunk(Db, Shared)),
    ok = xet_metadata:delete_xorb(Db, <<1:256>>),
    ?assertEqual(1, maps:get(xorbs, xet_metadata:stats(Db))).

%% Opening with tuning options (custom block cache) is transparent:
%% records round-trip and a reopen keeps them.
tuned_open(Config) ->
    Dir = filename:join(proplists:get_value(dir, Config), "tuned"),
    Opts = #{dir => Dir, tuning => #{block_cache_size => 1048576}},
    {ok, Db} = xet_metadata:open(xet_metadata_rocksdb, Opts),
    ok = xet_metadata:register_xorb(Db, xorb_meta(1)),
    ?assertEqual({ok, xorb_meta(1)}, xet_metadata:get_xorb(Db, <<1:256>>)),
    ok = xet_metadata:close(Db),
    {ok, Db2} = xet_metadata:open(xet_metadata_rocksdb, Opts),
    try
        ?assertEqual({ok, xorb_meta(1)}, xet_metadata:get_xorb(Db2, <<1:256>>))
    after
        ok = xet_metadata:close(Db2)
    end.

%% A checkpoint taken under write load opens as a fresh, consistent DB
%% with the records and schema intact.
checkpoint(Config) ->
    Db = db(Config),
    ok = xet_metadata:register_xorb(Db, xorb_meta(1)),
    ok = xet_metadata:register_files(Db, [file_meta(1)], [{<<10:256>>, <<1:256>>, 0}]),
    Target = filename:join(proplists:get_value(dir, Config), "backup/metadata"),
    ok = filelib:ensure_path(filename:dirname(Target)),
    ok = xet_metadata:checkpoint(Db, Target),
    %% Keep writing after the snapshot: it must not affect the copy.
    ok = xet_metadata:register_xorb(Db, xorb_meta(2)),
    {ok, Copy} = xet_metadata:open(xet_metadata_rocksdb, #{dir => Target}),
    try
        ?assertEqual({ok, xorb_meta(1)}, xet_metadata:get_xorb(Copy, <<1:256>>)),
        ?assertEqual({ok, file_meta(1)}, xet_metadata:get_file(Copy, <<1:256>>)),
        %% The write after the checkpoint is not in the snapshot.
        ?assertEqual(not_found, xet_metadata:get_xorb(Copy, <<2:256>>)),
        ?assertEqual(1, maps:get(xorbs, xet_metadata:stats(Copy)))
    after
        ok = xet_metadata:close(Copy)
    end.

%% A database written before the counters existed seeds them from its
%% data on the next open. Simulated with a raw handle that writes xorb
%% records but no counter sentinel.
counters_backfill(Config) ->
    Dir = filename:join(proplists:get_value(dir, Config), "backfill"),
    CfNames = ["default", "files", "xorbs", "chunks", "meta"],
    Descriptors = [{N, []} || N <- CfNames],
    DbOpts = [{create_if_missing, true}, {create_missing_column_families, true}],
    {ok, H, [_D, _F, Xorbs, _C, _M]} = rocksdb:open(Dir, DbOpts, Descriptors),
    Value = fun(Bytes) ->
        Map = #{
            entries => [], boundary_offsets => [1], unpacked_offsets => [1], bytes_on_disk => Bytes
        },
        <<1, (term_to_binary(Map))/binary>>
    end,
    ok = rocksdb:put(H, Xorbs, <<1:256>>, Value(300), []),
    ok = rocksdb:put(H, Xorbs, <<2:256>>, Value(500), []),
    ok = rocksdb:close(H),
    {ok, Db} = xet_metadata:open(xet_metadata_rocksdb, #{dir => Dir}),
    Stats = xet_metadata:stats(Db),
    ?assertEqual(2, maps:get(xorbs, Stats)),
    ?assertEqual(800, maps:get(bytes_on_disk, Stats)),
    ok = xet_metadata:close(Db).

ring(T) ->
    #{
        current => #{
            key => binary:copy(<<7>>, 32),
            created_at => T,
            expires_at => T + 86400
        }
    }.
