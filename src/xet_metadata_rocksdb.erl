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
    stats/1
]).

-define(SCHEMA_KEY, <<"schema">>).
-define(SCHEMA_VERSION, <<1>>).
-define(KEY_RING_KEY, <<"key_ring">>).
-define(VALUE_VERSION, 1).

-record(db, {
    handle :: rocksdb:db_handle(),
    files :: rocksdb:cf_handle(),
    xorbs :: rocksdb:cf_handle(),
    chunks :: rocksdb:cf_handle(),
    meta :: rocksdb:cf_handle()
}).

open(#{dir := Dir}) ->
    DbOpts = [{create_if_missing, true}, {create_missing_column_families, true}],
    Descriptors = [{Name, []} || Name <- ["default", "files", "xorbs", "chunks", "meta"]],
    case rocksdb:open(Dir, DbOpts, Descriptors) of
        {ok, Handle, [_Default, Files, Xorbs, Chunks, Meta]} ->
            Db = #db{handle = Handle, files = Files, xorbs = Xorbs, chunks = Chunks, meta = Meta},
            check_schema(Db);
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
%% power failure (the WAL alone only covers process crashes).
register_xorb(#db{handle = Handle, xorbs = Xorbs}, #{hash := Hash} = Meta) ->
    rocksdb:put(Handle, Xorbs, Hash, encode(maps:remove(hash, Meta)), [{sync, true}]).

xorb_exists(Db, Hash) ->
    get_xorb(Db, Hash) =/= not_found.

get_xorb(#db{handle = Handle, xorbs = Xorbs}, Hash) ->
    case rocksdb:get(Handle, Xorbs, Hash, []) of
        {ok, Value} -> {ok, maps:put(hash, Hash, decode(Value))};
        not_found -> not_found
    end.

register_files(#db{handle = Handle, files = Files, chunks = Chunks}, FileMetas, ChunkEntries) ->
    {ok, Batch} = rocksdb:batch(),
    try
        lists:foreach(
            fun(#{file_hash := Hash} = Meta) ->
                ok = rocksdb:batch_put(Batch, Files, Hash, encode(maps:remove(file_hash, Meta)))
            end,
            FileMetas
        ),
        lists:foreach(
            fun({ChunkHash, XorbHash, Index}) ->
                ok = rocksdb:batch_put(Batch, Chunks, ChunkHash, encode({XorbHash, Index}))
            end,
            ChunkEntries
        ),
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

stats(#db{handle = Handle} = Db) ->
    #{
        files => estimate(Handle, Db#db.files),
        xorbs => estimate(Handle, Db#db.xorbs),
        chunks => estimate(Handle, Db#db.chunks)
    }.

estimate(Handle, Cf) ->
    case rocksdb:get_property(Handle, Cf, <<"rocksdb.estimate-num-keys">>) of
        {ok, Value} -> binary_to_integer(iolist_to_binary(Value));
        _ -> 0
    end.

encode(Term) ->
    <<?VALUE_VERSION, (term_to_binary(Term, [{minor_version, 2}]))/binary>>.

decode(<<?VALUE_VERSION, Bin/binary>>) ->
    binary_to_term(Bin).
