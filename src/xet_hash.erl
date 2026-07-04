%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% XET hashing (spec Section 6): BLAKE3 keyed hashing with four domain
%% separation keys, plus the string representation (Section 6.5).
%%
%% The keys are private to this module; other modules go through the
%% functions below. The Merkle construction lives in xet_merkle.
-module(xet_hash).

-export([
    chunk_hash/1,
    internal_node_hash/1,
    xorb_hash/1,
    file_hash/1,
    verification_hash/1,
    keyed_chunk_hash/2,
    zero_hash/0,
    to_string/1,
    from_string/1,
    is_hash_string/1
]).

-type hash() :: <<_:256>>.
-type hash_string() :: <<_:512>>.
-type entry() :: {hash(), non_neg_integer()}.

-export_type([hash/0, hash_string/0, entry/0]).

%% Section 6.1: chunk hashes.
-define(DATA_KEY,
    <<16#66, 16#97, 16#f5, 16#77, 16#5b, 16#95, 16#50, 16#de, 16#31, 16#35, 16#cb, 16#ac, 16#a5,
        16#97, 16#18, 16#1c, 16#9d, 16#e4, 16#21, 16#10, 16#9b, 16#eb, 16#2b, 16#58, 16#b4, 16#d0,
        16#b0, 16#4b, 16#93, 16#ad, 16#f2, 16#29>>
).
%% Section 6.2.1: internal merkle nodes.
-define(INTERNAL_NODE_KEY,
    <<16#01, 16#7e, 16#c5, 16#c7, 16#a5, 16#47, 16#29, 16#96, 16#fd, 16#94, 16#66, 16#66, 16#b4,
        16#8a, 16#02, 16#e6, 16#5d, 16#dd, 16#53, 16#6f, 16#37, 16#c7, 16#6d, 16#d2, 16#f8, 16#63,
        16#52, 16#e6, 16#4a, 16#53, 16#71, 16#3f>>
).
%% Section 6.4: term verification hashes.
-define(VERIFICATION_KEY,
    <<16#7f, 16#18, 16#57, 16#d6, 16#ce, 16#56, 16#ed, 16#66, 16#12, 16#7f, 16#f9, 16#13, 16#e7,
        16#a5, 16#c3, 16#f3, 16#a4, 16#cd, 16#26, 16#d5, 16#b5, 16#db, 16#49, 16#e6, 16#41, 16#24,
        16#98, 16#7f, 16#28, 16#fb, 16#94, 16#c3>>
).
-define(ZERO_HASH, <<0:256>>).

-spec chunk_hash(iodata()) -> hash().
chunk_hash(Data) ->
    xet_nif:blake3_keyed(?DATA_KEY, Data).

-spec internal_node_hash(iodata()) -> hash().
internal_node_hash(Buffer) ->
    xet_nif:blake3_keyed(?INTERNAL_NODE_KEY, Buffer).

%% Section 6.2.3: merkle root over the xorb's (chunk hash, size) entries.
-spec xorb_hash([entry()]) -> hash().
xorb_hash(Entries) ->
    xet_merkle:root(Entries).

%% Section 6.3: file hash. Empty files are ZERO_HASH; otherwise the merkle
%% root gets a final keyed hash with the all-zero key.
-spec file_hash([entry()]) -> hash().
file_hash([]) ->
    ?ZERO_HASH;
file_hash(Entries) ->
    xet_nif:blake3_keyed(?ZERO_HASH, xet_merkle:root(Entries)).

%% Section 6.4: verification hash over the raw concatenated chunk hashes
%% of a term's range.
-spec verification_hash([hash()]) -> hash().
verification_hash(ChunkHashes) ->
    xet_nif:blake3_keyed(?VERIFICATION_KEY, ChunkHashes).

%% Sections 9.6.2 / 10.3: keyed-hash protection for global dedup. An
%% all-zero key means hashes are stored unprotected (identity), not
%% keyed with zeros.
-spec keyed_chunk_hash(hash(), hash()) -> hash().
keyed_chunk_hash(?ZERO_HASH, ChunkHash) ->
    ChunkHash;
keyed_chunk_hash(Key, ChunkHash) when byte_size(Key) =:= 32 ->
    xet_nif:blake3_keyed(Key, ChunkHash).

-spec zero_hash() -> hash().
zero_hash() ->
    ?ZERO_HASH.

-spec to_string(hash()) -> hash_string().
to_string(Hash) when byte_size(Hash) =:= 32 ->
    Swapped = <<<<S:64/big>> || <<S:64/little>> <= Hash>>,
    binary:encode_hex(Swapped, lowercase).

%% Strict inverse: only the canonical lowercase form is accepted.
-spec from_string(hash_string()) -> hash().
from_string(Str) ->
    case is_hash_string(Str) of
        true ->
            Raw = binary:decode_hex(Str),
            <<<<S:64/little>> || <<S:64/big>> <= Raw>>;
        false ->
            error(badarg)
    end.

-spec is_hash_string(term()) -> boolean().
is_hash_string(Str) when is_binary(Str), byte_size(Str) =:= 64 ->
    lowercase_hex(Str);
is_hash_string(_) ->
    false.

lowercase_hex(<<C, Rest/binary>>) when C >= $0, C =< $9 ->
    lowercase_hex(Rest);
lowercase_hex(<<C, Rest/binary>>) when C >= $a, C =< $f ->
    lowercase_hex(Rest);
lowercase_hex(<<>>) ->
    true;
lowercase_hex(_) ->
    false.
