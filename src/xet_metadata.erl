%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Metadata store behaviour: files, xorb layouts, the global dedup chunk
%% index, and the dedup key ring. The server holds a {Module, State}
%% handle and goes through the wrappers here; xet_metadata_rocksdb is the
%% default backend.
-module(xet_metadata).

-export([
    open/2,
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
    fold_files/3,
    fold_xorbs/3,
    delete_file/2,
    delete_xorb/2,
    stats/1
]).

-type handle() :: {module(), term()}.
-type xorb_meta() :: #{
    hash := xet_hash:hash(),
    %% Blob store namespace the xorb was uploaded under.
    ns => binary(),
    entries := [xet_hash:entry()],
    boundary_offsets := [pos_integer()],
    unpacked_offsets := [pos_integer()],
    bytes_on_disk := pos_integer(),
    %% Registration time (Unix seconds). Additive: absent in records
    %% written before this field; readers default it to 0.
    created_at => non_neg_integer()
}.
-type file_meta() :: #{
    file_hash := xet_hash:hash(),
    total_len := non_neg_integer(),
    terms := [xet_shard:file_term()],
    verification => [xet_hash:hash()],
    sha256 => xet_hash:hash()
}.
-type chunk_entry() :: {xet_hash:hash(), xet_hash:hash(), non_neg_integer()}.
-type key_ring() :: #{
    current := #{
        key := xet_hash:hash(),
        created_at := non_neg_integer(),
        expires_at := non_neg_integer()
    },
    previous => #{
        key := xet_hash:hash(),
        created_at := non_neg_integer(),
        expires_at := non_neg_integer()
    }
}.
-export_type([handle/0, xorb_meta/0, file_meta/0, chunk_entry/0, key_ring/0]).

-callback open(map()) -> {ok, term()} | {error, term()}.
-callback close(term()) -> ok.
-callback register_xorb(term(), xorb_meta()) -> ok | {error, term()}.
-callback xorb_exists(term(), xet_hash:hash()) -> boolean().
-callback get_xorb(term(), xet_hash:hash()) -> {ok, xorb_meta()} | not_found.
-callback register_files(term(), [file_meta()], [chunk_entry()]) -> ok | {error, term()}.
-callback get_file(term(), xet_hash:hash()) -> {ok, file_meta()} | not_found.
-callback file_exists(term(), xet_hash:hash()) -> boolean().
-callback find_chunk(term(), xet_hash:hash()) ->
    {ok, {xet_hash:hash(), non_neg_integer()}} | not_found.
-callback get_key_ring(term()) -> {ok, key_ring()} | not_found.
-callback put_key_ring(term(), key_ring()) -> ok | {error, term()}.
-callback get_url_secret(term()) -> {ok, binary()} | not_found.
-callback put_url_secret(term(), binary()) -> ok | {error, term()}.
-callback fold_files(term(), fun((file_meta(), Acc) -> Acc), Acc) -> Acc.
-callback fold_xorbs(term(), fun((xorb_meta(), Acc) -> Acc), Acc) -> Acc.
-callback delete_file(term(), xet_hash:hash()) -> ok | {error, term()}.
-callback delete_xorb(term(), xet_hash:hash()) -> ok | {error, term()}.
-callback stats(term()) -> map().

-spec open(module(), map()) -> {ok, handle()} | {error, term()}.
open(Mod, Opts) ->
    case Mod:open(Opts) of
        {ok, State} -> {ok, {Mod, State}};
        {error, _} = Error -> Error
    end.

-spec close(handle()) -> ok.
close({Mod, State}) -> Mod:close(State).

-spec register_xorb(handle(), xorb_meta()) -> ok | {error, term()}.
register_xorb({Mod, State}, Meta) -> Mod:register_xorb(State, Meta).

-spec xorb_exists(handle(), xet_hash:hash()) -> boolean().
xorb_exists({Mod, State}, Hash) -> Mod:xorb_exists(State, Hash).

-spec get_xorb(handle(), xet_hash:hash()) -> {ok, xorb_meta()} | not_found.
get_xorb({Mod, State}, Hash) -> Mod:get_xorb(State, Hash).

-spec register_files(handle(), [file_meta()], [chunk_entry()]) -> ok | {error, term()}.
register_files({Mod, State}, Files, Chunks) -> Mod:register_files(State, Files, Chunks).

-spec get_file(handle(), xet_hash:hash()) -> {ok, file_meta()} | not_found.
get_file({Mod, State}, Hash) -> Mod:get_file(State, Hash).

-spec file_exists(handle(), xet_hash:hash()) -> boolean().
file_exists({Mod, State}, Hash) -> Mod:file_exists(State, Hash).

-spec find_chunk(handle(), xet_hash:hash()) ->
    {ok, {xet_hash:hash(), non_neg_integer()}} | not_found.
find_chunk({Mod, State}, Hash) -> Mod:find_chunk(State, Hash).

-spec get_key_ring(handle()) -> {ok, key_ring()} | not_found.
get_key_ring({Mod, State}) -> Mod:get_key_ring(State).

-spec put_key_ring(handle(), key_ring()) -> ok | {error, term()}.
put_key_ring({Mod, State}, Ring) -> Mod:put_key_ring(State, Ring).

%% The signing secret for FS data URLs, persisted so signed URLs survive
%% restarts (same lifecycle as the dedup key ring above).
-spec get_url_secret(handle()) -> {ok, binary()} | not_found.
get_url_secret({Mod, State}) -> Mod:get_url_secret(State).

-spec put_url_secret(handle(), binary()) -> ok | {error, term()}.
put_url_secret({Mod, State}, Secret) -> Mod:put_url_secret(State, Secret).

%% Fold over every file or xorb record. Used by GC (mark phase) and
%% scrub; runs against a consistent iterator snapshot of the backend.
-spec fold_files(handle(), fun((file_meta(), Acc) -> Acc), Acc) -> Acc.
fold_files({Mod, State}, Fun, Acc) -> Mod:fold_files(State, Fun, Acc).

-spec fold_xorbs(handle(), fun((xorb_meta(), Acc) -> Acc), Acc) -> Acc.
fold_xorbs({Mod, State}, Fun, Acc) -> Mod:fold_xorbs(State, Fun, Acc).

%% Delete a file record, or a xorb record with its owned chunk-index
%% entries and counter decrements. Both idempotent.
-spec delete_file(handle(), xet_hash:hash()) -> ok | {error, term()}.
delete_file({Mod, State}, Hash) -> Mod:delete_file(State, Hash).

-spec delete_xorb(handle(), xet_hash:hash()) -> ok | {error, term()}.
delete_xorb({Mod, State}, Hash) -> Mod:delete_xorb(State, Hash).

-spec stats(handle()) -> map().
stats({Mod, State}) -> Mod:stats(State).
