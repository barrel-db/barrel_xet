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
    stats/1
]).

-type handle() :: {module(), term()}.
-type xorb_meta() :: #{
    hash := xet_hash:hash(),
    entries := [xet_hash:entry()],
    boundary_offsets := [pos_integer()],
    unpacked_offsets := [pos_integer()],
    bytes_on_disk := pos_integer()
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

-spec stats(handle()) -> map().
stats({Mod, State}) -> Mod:stats(State).
