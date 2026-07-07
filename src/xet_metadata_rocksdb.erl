%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% rocksdb metadata backend. One database, four column families:
%%   files:  FileHash  -> file_meta()
%%   xorbs:  XorbHash  -> xorb_meta()
%%   chunks: ChunkHash -> {XorbHash, Index}   (dedup-eligible chunks only)
%%   meta:   schema version, dedup key ring
%%
%% Values are versioned term_to_binary envelopes; keys are the raw
%% 32-byte hashes. File and chunk registration from one shard goes into a
%% single atomic write batch.
-module(xet_metadata_rocksdb).

-behaviour(xet_metadata).

-export([
    open/1,
    close/1,
    register_xorb/2,
    xorb_exists/2,
    get_xorb/2,
    register_files/3,
    get_file/2,
    file_exists/2,
    find_chunk/2,
    get_key_ring/1,
    put_key_ring/2,
    get_url_secret/1,
    put_url_secret/2,
    stats/1
]).

-define(SCHEMA_KEY, <<"schema">>).
-define(SCHEMA_VERSION, <<1>>).
-define(KEY_RING_KEY, <<"key_ring">>).
-define(URL_SECRET_KEY, <<"url_secret">>).
-define(VALUE_VERSION, 1).

%% Maintained counters in the meta CF (erlang_merge_operator, signed
%% int_add deltas so GC can decrement). They bypass the value envelope:
%% base value is term_to_binary(Integer), deltas term_to_binary(
%% {int_add, N}). ?COUNTERS_KEY marks a one-time backfill of a DB that
%% predates them.
-define(COUNTER_XORBS, <<"count:xorbs">>).
-define(COUNTER_FILES, <<"count:files">>).
-define(COUNTER_BYTES, <<"count:bytes_on_disk">>).
-define(COUNTERS_KEY, <<"counters_ready">>).

-record(db, {
    handle :: rocksdb:db_handle(),
    files :: rocksdb:cf_handle(),
    xorbs :: rocksdb:cf_handle(),
    chunks :: rocksdb:cf_handle(),
    meta :: rocksdb:cf_handle()
}).

open(#{dir := Dir}) ->
    DbOpts = [{create_if_missing, true}, {create_missing_column_families, true}],
    Descriptors = [
        {"default", []},
        {"files", []},
        {"xorbs", []},
        {"chunks", []},
        {"meta", [{merge_operator, erlang_merge_operator}]}
    ],
    case rocksdb:open(Dir, DbOpts, Descriptors) of
        {ok, Handle, [_Default, Files, Xorbs, Chunks, Meta]} ->
            Db = #db{handle = Handle, files = Files, xorbs = Xorbs, chunks = Chunks, meta = Meta},
            maybe
                {ok, Db1} ?= check_schema(Db),
                ok ?= ensure_counters(Db1),
                {ok, Db1}
            end;
        {error, _} = Error ->
            Error
    end.

check_schema(#db{handle = Handle, meta = Meta} = Db) ->
    case rocksdb:get(Handle, Meta, ?SCHEMA_KEY, []) of
        {ok, ?SCHEMA_VERSION} ->
            {ok, Db};
        not_found ->
            ok = rocksdb:put(Handle, Meta, ?SCHEMA_KEY, ?SCHEMA_VERSION, [{sync, true}]),
            {ok, Db};
        {ok, Other} ->
            ok = rocksdb:close(Handle),
            {error, {schema_mismatch, Other}};
        {error, _} = Error ->
            ok = rocksdb:close(Handle),
            Error
    end.

close(#db{handle = Handle}) ->
    rocksdb:close(Handle).

%% Synced: an acknowledged xorb upload must never lose its metadata to a
%% power failure (the WAL alone only covers process crashes). A new xorb
%% bumps the xorb and bytes counters in the same batch; re-registering an
%% existing one (same content-addressed hash) is a plain overwrite.
register_xorb(#db{handle = Handle, xorbs = Xorbs, meta = Meta} = Db, #{hash := Hash} = M) ->
    Value = encode(maps:remove(hash, M)),
    case xorb_exists(Db, Hash) of
        true ->
            rocksdb:put(Handle, Xorbs, Hash, Value, [{sync, true}]);
        false ->
            with_batch(Handle, fun(Batch) ->
                ok = rocksdb:batch_put(Batch, Xorbs, Hash, Value),
                ok = rocksdb:batch_merge(Batch, Meta, ?COUNTER_XORBS, merge_delta(1)),
                ok = rocksdb:batch_merge(
                    Batch, Meta, ?COUNTER_BYTES, merge_delta(maps:get(bytes_on_disk, M))
                )
            end)
    end.

xorb_exists(Db, Hash) ->
    get_xorb(Db, Hash) =/= not_found.

get_xorb(#db{handle = Handle, xorbs = Xorbs}, Hash) ->
    case rocksdb:get(Handle, Xorbs, Hash, []) of
        {ok, Value} -> {ok, maps:put(hash, Hash, decode(Value))};
        not_found -> not_found
    end.

register_files(
    #db{handle = Handle, files = Files, chunks = Chunks, meta = Meta} = Db, FileMetas, ChunkEntries
) ->
    NewFiles = length([H || #{file_hash := H} <- FileMetas, get_file(Db, H) =:= not_found]),
    with_batch(Handle, fun(Batch) ->
        lists:foreach(
            fun(#{file_hash := Hash} = M) ->
                ok = rocksdb:batch_put(Batch, Files, Hash, encode(maps:remove(file_hash, M)))
            end,
            FileMetas
        ),
        lists:foreach(
            fun({ChunkHash, XorbHash, Index}) ->
                ok = rocksdb:batch_put(Batch, Chunks, ChunkHash, encode({XorbHash, Index}))
            end,
            ChunkEntries
        ),
        ok = rocksdb:batch_merge(Batch, Meta, ?COUNTER_FILES, merge_delta(NewFiles))
    end).

%% Run Fun against a fresh write batch, then commit it synced.
with_batch(Handle, Fun) ->
    {ok, Batch} = rocksdb:batch(),
    try
        Fun(Batch),
        rocksdb:write_batch(Handle, Batch, [{sync, true}])
    after
        rocksdb:release_batch(Batch)
    end.

get_file(#db{handle = Handle, files = Files}, Hash) ->
    case rocksdb:get(Handle, Files, Hash, []) of
        {ok, Value} -> {ok, maps:put(file_hash, Hash, decode(Value))};
        not_found -> not_found
    end.

file_exists(Db, Hash) ->
    get_file(Db, Hash) =/= not_found.

find_chunk(#db{handle = Handle, chunks = Chunks}, Hash) ->
    case rocksdb:get(Handle, Chunks, Hash, []) of
        {ok, Value} -> {ok, decode(Value)};
        not_found -> not_found
    end.

get_key_ring(#db{handle = Handle, meta = Meta}) ->
    case rocksdb:get(Handle, Meta, ?KEY_RING_KEY, []) of
        {ok, Value} -> {ok, decode(Value)};
        not_found -> not_found
    end.

put_key_ring(#db{handle = Handle, meta = Meta}, Ring) ->
    rocksdb:put(Handle, Meta, ?KEY_RING_KEY, encode(Ring), [{sync, true}]).

get_url_secret(#db{handle = Handle, meta = Meta}) ->
    case rocksdb:get(Handle, Meta, ?URL_SECRET_KEY, []) of
        {ok, Value} -> {ok, decode(Value)};
        not_found -> not_found
    end.

put_url_secret(#db{handle = Handle, meta = Meta}, Secret) ->
    rocksdb:put(Handle, Meta, ?URL_SECRET_KEY, encode(Secret), [{sync, true}]).

stats(#db{handle = Handle, meta = Meta} = Db) ->
    #{
        files => read_counter(Handle, Meta, ?COUNTER_FILES),
        xorbs => read_counter(Handle, Meta, ?COUNTER_XORBS),
        bytes_on_disk => read_counter(Handle, Meta, ?COUNTER_BYTES),
        chunks => estimate(Handle, Db#db.chunks)
    }.

estimate(Handle, Cf) ->
    case rocksdb:get_property(Handle, Cf, <<"rocksdb.estimate-num-keys">>) of
        {ok, Value} -> binary_to_integer(iolist_to_binary(Value));
        _ -> 0
    end.

merge_delta(N) ->
    term_to_binary({int_add, N}).

read_counter(Handle, Meta, Key) ->
    case rocksdb:get(Handle, Meta, Key, []) of
        {ok, Bin} -> binary_to_term(Bin);
        not_found -> 0
    end.

%% Seed the counters once from the existing data, for a DB created before
%% they were maintained. A fresh DB scans nothing and seeds zeros.
ensure_counters(#db{handle = Handle, meta = Meta} = Db) ->
    case rocksdb:get(Handle, Meta, ?COUNTERS_KEY, []) of
        {ok, _} ->
            ok;
        not_found ->
            {XorbN, Bytes} = scan_xorbs(Db),
            FileN = scan_files(Db),
            with_batch(Handle, fun(Batch) ->
                ok = rocksdb:batch_put(Batch, Meta, ?COUNTER_XORBS, term_to_binary(XorbN)),
                ok = rocksdb:batch_put(Batch, Meta, ?COUNTER_FILES, term_to_binary(FileN)),
                ok = rocksdb:batch_put(Batch, Meta, ?COUNTER_BYTES, term_to_binary(Bytes)),
                ok = rocksdb:batch_put(Batch, Meta, ?COUNTERS_KEY, <<1>>)
            end);
        {error, _} = Error ->
            Error
    end.

scan_xorbs(#db{handle = Handle, xorbs = Xorbs}) ->
    {ok, It} = rocksdb:iterator(Handle, Xorbs, []),
    try
        sum_xorbs(It, rocksdb:iterator_move(It, first), 0, 0)
    after
        rocksdb:iterator_close(It)
    end.

sum_xorbs(_It, {error, invalid_iterator}, N, Bytes) ->
    {N, Bytes};
sum_xorbs(It, {ok, _Key, Value}, N, Bytes) ->
    B = maps:get(bytes_on_disk, decode(Value), 0),
    sum_xorbs(It, rocksdb:iterator_move(It, next), N + 1, Bytes + B).

scan_files(#db{handle = Handle, files = Files}) ->
    {ok, It} = rocksdb:iterator(Handle, Files, []),
    try
        count_keys(It, rocksdb:iterator_move(It, first), 0)
    after
        rocksdb:iterator_close(It)
    end.

count_keys(_It, {error, invalid_iterator}, N) ->
    N;
count_keys(It, {ok, _Key, _Value}, N) ->
    count_keys(It, rocksdb:iterator_move(It, next), N + 1).

encode(Term) ->
    <<?VALUE_VERSION, (term_to_binary(Term, [{minor_version, 2}]))/binary>>.

decode(<<?VALUE_VERSION, Bin/binary>>) ->
    binary_to_term(Bin).
