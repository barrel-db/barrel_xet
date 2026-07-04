%% Native primitives for the XET protocol (see c_src/).
%%
%% Inputs above ?DIRTY_THRESHOLD bytes run on dirty CPU schedulers so
%% chunk-sized and xorb-sized workloads never block normal schedulers.
-module(xet_nif).

-export([blake3_keyed/2, lz4f_compress/1, lz4f_decompress/2, gearhash_scan/3, fsync_dir/1]).

-nifs([
    blake3_keyed_nif/2,
    blake3_keyed_dirty_nif/2,
    lz4f_compress_nif/1,
    lz4f_compress_dirty_nif/1,
    lz4f_decompress_nif/2,
    lz4f_decompress_dirty_nif/2,
    gearhash_scan_nif/3,
    gearhash_scan_dirty_nif/3,
    fsync_dir_nif/1
]).
-on_load(init/0).

-define(DIRTY_THRESHOLD, 16384).

%% BLAKE3 keyed hash: 32-byte key, 32-byte digest.
-spec blake3_keyed(<<_:256>>, iodata()) -> <<_:256>>.
blake3_keyed(Key, Data) when is_binary(Key), byte_size(Key) =:= 32 ->
    case iolist_size(Data) > ?DIRTY_THRESHOLD of
        true -> blake3_keyed_dirty_nif(Key, Data);
        false -> blake3_keyed_nif(Key, Data)
    end.

%% Compress data as one complete LZ4 frame (spec compression type 1).
-spec lz4f_compress(iodata()) -> binary().
lz4f_compress(Data) ->
    case iolist_size(Data) > ?DIRTY_THRESHOLD of
        true -> lz4f_compress_dirty_nif(Data);
        false -> lz4f_compress_nif(Data)
    end.

%% Decompress one complete LZ4 frame, rejecting output larger than MaxSize.
-spec lz4f_decompress(iodata(), non_neg_integer()) ->
    {ok, binary()} | {error, corrupt | truncated | too_large | trailing_data}.
lz4f_decompress(Data, MaxSize) when is_integer(MaxSize), MaxSize >= 0 ->
    case iolist_size(Data) > ?DIRTY_THRESHOLD of
        true -> lz4f_decompress_dirty_nif(Data, MaxSize);
        false -> lz4f_decompress_nif(Data, MaxSize)
    end.

%% Gearhash boundary scan over one buffer, carrying {H, ChunkLen} rolling
%% state across calls. Returns cut end-offsets relative to this buffer.
-spec gearhash_scan(non_neg_integer(), non_neg_integer(), iodata()) ->
    {[non_neg_integer()], non_neg_integer(), non_neg_integer()}.
gearhash_scan(H, ChunkLen, Data) ->
    case iolist_size(Data) > ?DIRTY_THRESHOLD of
        true -> gearhash_scan_dirty_nif(H, ChunkLen, Data);
        false -> gearhash_scan_nif(H, ChunkLen, Data)
    end.

%% Make a directory entry durable (after rename-into-place). Runs on a
%% dirty IO scheduler.
-spec fsync_dir(iodata()) -> ok | {error, atom()}.
fsync_dir(Path) ->
    fsync_dir_nif(Path).

init() ->
    erlang:load_nif(filename:join(priv_dir(), "xet_nif"), 0).

priv_dir() ->
    case code:priv_dir(barrel_xet) of
        {error, bad_name} ->
            Ebin = filename:dirname(code:which(?MODULE)),
            filename:join(filename:dirname(Ebin), "priv");
        Dir ->
            Dir
    end.

blake3_keyed_nif(_Key, _Data) ->
    erlang:nif_error(nif_not_loaded).

blake3_keyed_dirty_nif(_Key, _Data) ->
    erlang:nif_error(nif_not_loaded).

lz4f_compress_nif(_Data) ->
    erlang:nif_error(nif_not_loaded).

lz4f_compress_dirty_nif(_Data) ->
    erlang:nif_error(nif_not_loaded).

lz4f_decompress_nif(_Data, _MaxSize) ->
    erlang:nif_error(nif_not_loaded).

lz4f_decompress_dirty_nif(_Data, _MaxSize) ->
    erlang:nif_error(nif_not_loaded).

gearhash_scan_nif(_H, _ChunkLen, _Data) ->
    erlang:nif_error(nif_not_loaded).

gearhash_scan_dirty_nif(_H, _ChunkLen, _Data) ->
    erlang:nif_error(nif_not_loaded).

fsync_dir_nif(_Path) ->
    erlang:nif_error(nif_not_loaded).
