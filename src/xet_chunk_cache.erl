%% Local chunk cache (spec 13.2): decompressed chunks on disk, keyed by
%% (xorb hash string, chunk index), so repeat downloads skip the network
%% fetch and decompression. Content is immutable, so a hit never needs
%% revalidation. Eviction is random to a size cap (spec 13.2.3), off by
%% default.
%%
%% Files: <dir>/<xorb hex>/<index>.chunk, each a 4-byte CRC32 followed by
%% the raw chunk bytes. A CRC mismatch drops the entry rather than
%% returning corrupt data. The in-memory index is rebuilt on open.
-module(xet_chunk_cache).

-export([open/1, open/2, close/1, get/3, put/4, get_range/4, put_range/4, count/1]).

-define(DEFAULT_SIZE_CAP, 10737418240).

-type handle() :: #{index := ets:tid(), dir := file:filename_all(), cap := integer()}.
-export_type([handle/0]).

-spec open(file:filename_all()) -> handle().
open(Dir) ->
    open(Dir, #{}).

-spec open(file:filename_all(), map()) -> handle().
open(Dir, Opts) ->
    ok = filelib:ensure_path(Dir),
    Handle = #{
        index => ets:new(xet_chunk_cache, [set, public]),
        dir => Dir,
        cap => maps:get(size_cap, Opts, ?DEFAULT_SIZE_CAP)
    },
    load(Handle),
    Handle.

-spec close(handle()) -> ok.
close(#{index := Index}) ->
    ets:delete(Index),
    ok.

-spec count(handle()) -> non_neg_integer().
count(#{index := Index}) ->
    ets:info(Index, size).

-spec get(handle(), binary(), non_neg_integer()) -> {ok, binary()} | not_found.
get(#{index := Index} = Handle, XorbId, Idx) ->
    case ets:lookup(Index, {XorbId, Idx}) of
        [{_, Path, _Size}] -> read_chunk(Handle, {XorbId, Idx}, Path);
        [] -> not_found
    end.

-spec put(handle(), binary(), non_neg_integer(), binary()) -> ok.
put(#{index := Index, dir := Dir} = Handle, XorbId, Idx, Chunk) ->
    Path = chunk_path(Dir, XorbId, Idx),
    ok = filelib:ensure_dir(Path),
    Crc = erlang:crc32(Chunk),
    ok = file:write_file(Path, <<Crc:32, Chunk/binary>>),
    ets:insert(Index, {{XorbId, Idx}, Path, byte_size(Chunk) + 4}),
    enforce_cap(Handle),
    ok.

%% All chunks of [Start, End) if every one is cached, else a miss.
-spec get_range(handle(), binary(), non_neg_integer(), pos_integer()) ->
    {ok, [binary()]} | miss.
get_range(Handle, XorbId, Start, End) ->
    collect_range(Handle, XorbId, lists:seq(Start, End - 1), []).

collect_range(_Handle, _XorbId, [], Acc) ->
    {ok, lists:reverse(Acc)};
collect_range(Handle, XorbId, [Idx | Rest], Acc) ->
    case get(Handle, XorbId, Idx) of
        {ok, Chunk} -> collect_range(Handle, XorbId, Rest, [Chunk | Acc]);
        not_found -> miss
    end.

-spec put_range(handle(), binary(), non_neg_integer(), [binary()]) -> ok.
put_range(Handle, XorbId, Start, Chunks) ->
    lists:foreach(
        fun({Offset, Chunk}) -> put(Handle, XorbId, Start + Offset, Chunk) end,
        lists:zip(lists:seq(0, length(Chunks) - 1), Chunks)
    ).

%%--------------------------------------------------------------------

read_chunk(#{index := Index}, Key, Path) ->
    case file:read_file(Path) of
        {ok, <<Crc:32, Chunk/binary>>} when byte_size(Chunk) >= 0 ->
            case erlang:crc32(Chunk) of
                Crc -> {ok, Chunk};
                _ -> drop(Index, Key, Path)
            end;
        _ ->
            drop(Index, Key, Path)
    end.

drop(Index, Key, Path) ->
    _ = file:delete(Path),
    ets:delete(Index, Key),
    not_found.

load(#{index := Index, dir := Dir}) ->
    Files = filelib:wildcard(filename:join([Dir, "*", "*.chunk"])),
    lists:foreach(
        fun(Path) ->
            case key_of(Path) of
                {ok, Key} -> ets:insert(Index, {Key, Path, filelib:file_size(Path)});
                error -> _ = file:delete(Path)
            end
        end,
        Files
    ).

%% Key from the last two path components: <xorb>/<index>.chunk.
key_of(Path) ->
    case lists:reverse(filename:split(Path)) of
        [IdxFile, XorbId | _] ->
            case string:to_integer(filename:basename(IdxFile, ".chunk")) of
                {Idx, []} when Idx >= 0 -> {ok, {list_to_binary(XorbId), Idx}};
                _ -> error
            end;
        _ ->
            error
    end.

chunk_path(Dir, XorbId, Idx) ->
    filename:join([Dir, binary_to_list(XorbId), integer_to_list(Idx) ++ ".chunk"]).

%% Random eviction until under the cap (spec 13.2.3).
enforce_cap(#{index := Index, cap := Cap} = Handle) ->
    case total_size(Index) > Cap of
        true ->
            evict_random(Handle),
            enforce_cap(Handle);
        false ->
            ok
    end.

total_size(Index) ->
    ets:foldl(fun({_, _, Size}, Acc) -> Acc + Size end, 0, Index).

evict_random(#{index := Index}) ->
    case ets:info(Index, size) of
        0 ->
            ok;
        N ->
            Keys = [K || {K, _, _} <- ets:tab2list(Index)],
            {Key, Path, _} = lists:keyfind(
                lists:nth(rand:uniform(N), Keys), 1, ets:tab2list(Index)
            ),
            _ = file:delete(Path),
            ets:delete(Index, Key),
            ok
    end.
