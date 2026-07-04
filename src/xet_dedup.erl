%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Global deduplication helpers (spec Sections 9.6.2 and 10.3).
%%
%% Servers answer chunk queries with a stored-form shard whose CAS chunk
%% hashes are protected by a keyed hash; clients can only match chunks
%% they already possess. An all-zero key means unprotected hashes.
-module(xet_dedup).

-export([eligible/2, hash_eligible/1, build_response/2, match/2, expired/2]).

-define(GLOBAL_DEDUP_MODULUS, 1024).

%% A chunk qualifies for a global dedup query when it is the first chunk
%% of a file or its hash tail selects it (roughly 1 in 1024).
-spec eligible(xet_hash:hash(), boolean()) -> boolean().
eligible(_ChunkHash, true) ->
    true;
eligible(ChunkHash, false) ->
    hash_eligible(ChunkHash).

-spec hash_eligible(xet_hash:hash()) -> boolean().
hash_eligible(<<_:24/binary, Tail:64/little>>) ->
    Tail rem ?GLOBAL_DEDUP_MODULUS =:= 0.

%% Server side: stored-form shard carrying only CAS info, chunk hashes
%% keyed with the footer's chunk_hash_key.
-spec build_response([xet_shard:cas_info()], map()) -> binary().
build_response(CasBlocks, FooterOpts) ->
    Key = maps:get(chunk_hash_key, FooterOpts),
    Keyed = [protect_block(Block, Key) || Block <- CasBlocks],
    xet_shard:encode_stored(#{files => [], cas => Keyed}, FooterOpts).

protect_block(#{chunks := Chunks} = Block, Key) ->
    Block#{
        chunks := [C#{hash := xet_hash:keyed_chunk_hash(Key, maps:get(hash, C))} || C <- Chunks]
    }.

%% Client side: look up one of our (unkeyed) chunk hashes in a decoded
%% dedupe response; the footer key is applied transparently.
-spec match(xet_shard:shard(), xet_hash:hash()) ->
    {ok, #{cas_hash := xet_hash:hash(), chunk_index := non_neg_integer()}} | not_found.
match(#{cas := CasBlocks, footer := Footer}, ChunkHash) ->
    Key = key_of(Footer),
    Needle = xet_hash:keyed_chunk_hash(Key, ChunkHash),
    find_chunk(CasBlocks, Needle).

key_of(undefined) -> xet_hash:zero_hash();
key_of(#{chunk_hash_key := Key}) -> Key.

find_chunk([], _Needle) ->
    not_found;
find_chunk([#{cas_hash := CasHash, chunks := Chunks} | Rest], Needle) ->
    case chunk_index(Chunks, Needle, 0) of
        {ok, Index} -> {ok, #{cas_hash => CasHash, chunk_index => Index}};
        not_found -> find_chunk(Rest, Needle)
    end.

chunk_index([], _Needle, _I) ->
    not_found;
chunk_index([#{hash := Needle} | _], Needle, I) ->
    {ok, I};
chunk_index([_ | Rest], Needle, I) ->
    chunk_index(Rest, Needle, I + 1).

%% A dedupe response is unusable once its key expired. Unkeyed shards
%% never expire.
-spec expired(xet_shard:shard(), non_neg_integer()) -> boolean().
expired(#{footer := undefined}, _Now) ->
    false;
expired(#{footer := #{chunk_hash_key := Key, key_expiry := Expiry}}, Now) ->
    Key =/= xet_hash:zero_hash() andalso Now >= Expiry.
