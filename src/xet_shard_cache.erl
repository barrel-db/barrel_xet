%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Local shard cache (spec 10.2, 13.4): keeps shards on disk and an
%% in-memory chunk index so a later session can deduplicate against
%% earlier uploads without any network query.
%%
%% Only shards with raw (unkeyed) chunk hashes are indexed: our own
%% upload shards qualify (their CAS info lists real chunk hashes), so a
%% re-upload dedups fully offline. Keyed global-dedup responses are
%% stored but not indexed (their hashes cannot be reversed) and expire
%% with their key.
-module(xet_shard_cache).

-export([open/1, open/2, close/1, store/2, lookup/2, count/1]).

-define(LOCAL_TTL, 1814400).
-define(DEFAULT_SIZE_CAP, 17179869184).
-define(WRAP_VERSION, 1).

-type handle() :: #{
    index := ets:tid(), dir := file:filename_all(), ttl := integer(), cap := integer()
}.
-export_type([handle/0]).

-spec open(file:filename_all()) -> handle().
open(Dir) ->
    open(Dir, #{}).

-spec open(file:filename_all(), map()) -> handle().
open(Dir, Opts) ->
    ok = filelib:ensure_path(Dir),
    Handle = #{
        index => ets:new(xet_shard_cache, [set, public]),
        dir => Dir,
        ttl => maps:get(ttl, Opts, ?LOCAL_TTL),
        cap => maps:get(size_cap, Opts, ?DEFAULT_SIZE_CAP)
    },
    load(Handle),
    Handle.

-spec close(handle()) -> ok.
close(#{index := Index}) ->
    ets:delete(Index),
    ok.

%% Index chunk_hash -> {cas_hash, chunk_index} for every raw-hash shard.
-spec lookup(handle(), xet_hash:hash()) ->
    {ok, {xet_hash:hash(), non_neg_integer()}} | not_found.
lookup(#{index := Index}, ChunkHash) ->
    case ets:lookup(Index, ChunkHash) of
        [{_, CasHash, Idx}] -> {ok, {CasHash, Idx}};
        [] -> not_found
    end.

-spec count(handle()) -> non_neg_integer().
count(#{index := Index}) ->
    ets:info(Index, size).

%% Persist a shard and index its chunks. The shard bytes are wrapped
%% with a creation time for expiry.
-spec store(handle(), binary()) -> ok.
store(#{dir := Dir} = Handle, ShardBin) ->
    case xet_shard:decode(ShardBin) of
        {ok, Shard} ->
            Now = erlang:system_time(second),
            Path = filename:join(Dir, shard_name(ShardBin)),
            ok = write_file(Path, Now, ShardBin),
            index_shard(Handle, Shard),
            enforce_cap(Handle),
            ok;
        {error, _} ->
            ok
    end.

%%--------------------------------------------------------------------

load(#{dir := Dir} = Handle) ->
    Now = erlang:system_time(second),
    Files = filelib:wildcard(filename:join(Dir, "*.shard")),
    lists:foreach(fun(Path) -> load_one(Handle, Path, Now) end, Files).

load_one(#{ttl := Ttl} = Handle, Path, Now) ->
    case read_file(Path) of
        {ok, Created, ShardBin} when Created + Ttl > Now ->
            case xet_shard:decode(ShardBin) of
                {ok, Shard} ->
                    index_if_fresh(Handle, Shard, Now, Path);
                {error, _} ->
                    _ = file:delete(Path),
                    ok
            end;
        _ ->
            _ = file:delete(Path),
            ok
    end.

index_if_fresh(Handle, Shard, Now, Path) ->
    case keyed_and_expired(Shard, Now) of
        true ->
            _ = file:delete(Path),
            ok;
        false ->
            index_shard(Handle, Shard)
    end.

keyed_and_expired(#{footer := #{chunk_hash_key := Key, key_expiry := Expiry}}, Now) ->
    Key =/= xet_hash:zero_hash() andalso Now >= Expiry;
keyed_and_expired(_Shard, _Now) ->
    false.

%% Raw-hash shards only; keyed ones cannot be looked up by raw hash.
index_shard(#{index := Index}, #{cas := Cas} = Shard) ->
    case raw_hashes(Shard) of
        true ->
            lists:foreach(fun(Block) -> index_block(Index, Block) end, Cas);
        false ->
            ok
    end.

raw_hashes(#{footer := undefined}) -> true;
raw_hashes(#{footer := #{chunk_hash_key := Key}}) -> Key =:= xet_hash:zero_hash().

index_block(Index, #{cas_hash := CasHash, chunks := Chunks}) ->
    lists:foreach(
        fun({Idx, #{hash := Hash}}) -> ets:insert(Index, {Hash, CasHash, Idx}) end,
        lists:zip(lists:seq(0, length(Chunks) - 1), Chunks)
    ).

shard_name(ShardBin) ->
    Digest = binary:encode_hex(crypto:hash(sha256, ShardBin), lowercase),
    <<Digest/binary, ".shard">>.

write_file(Path, Created, ShardBin) ->
    file:write_file(Path, <<?WRAP_VERSION, Created:64/little, ShardBin/binary>>).

read_file(Path) ->
    case file:read_file(Path) of
        {ok, <<?WRAP_VERSION, Created:64/little, ShardBin/binary>>} -> {ok, Created, ShardBin};
        _ -> error
    end.

%% Drop the least-recently-modified files when over the size cap.
enforce_cap(#{dir := Dir, cap := Cap}) ->
    Files = [
        {filelib:last_modified(P), filelib:file_size(P), P}
     || P <- filelib:wildcard(filename:join(Dir, "*.shard"))
    ],
    Total = lists:sum([S || {_, S, _} <- Files]),
    prune(lists:sort(Files), Total, Cap).

prune(_Files, Total, Cap) when Total =< Cap ->
    ok;
prune([], _Total, _Cap) ->
    ok;
prune([{_, Size, Path} | Rest], Total, Cap) ->
    _ = file:delete(Path),
    prune(Rest, Total - Size, Cap).
