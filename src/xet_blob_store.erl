%% Blob store behaviour: where serialized xorbs live. Backends:
%% xet_store_fs (local disk) and xet_store_s3 (livery_s3). The server
%% holds a {Module, State} handle and goes through the wrappers.
%%
%% put/4 accepts iodata or the livery_s3 streaming producer shape
%% ({stream, fun(() -> eof | {ok, binary(), fun()})}) so both backends
%% take the same body. Puts are idempotent: content addressing makes
%% same-hash writes interchangeable.
-module(xet_blob_store).

-export([open/2, close/1, put/4, get_range/5, size/3, exists/3, delete/3]).

-type handle() :: {module(), term()}.
-type body() :: iodata() | {stream, producer()}.
-type producer() :: fun(() -> eof | {ok, binary(), producer()}).
-export_type([handle/0, body/0, producer/0]).

-callback open(map()) -> {ok, term()} | {error, term()}.
-callback close(term()) -> ok.
-callback put(term(), binary(), xet_hash:hash(), body()) -> ok | {error, term()}.
-callback get_range(term(), binary(), xet_hash:hash(), non_neg_integer(), pos_integer()) ->
    {ok, binary()} | {error, term()}.
-callback size(term(), binary(), xet_hash:hash()) -> {ok, non_neg_integer()} | {error, term()}.
-callback exists(term(), binary(), xet_hash:hash()) -> boolean().
-callback delete(term(), binary(), xet_hash:hash()) -> ok | {error, term()}.

-spec open(module(), map()) -> {ok, handle()} | {error, term()}.
open(Mod, Opts) ->
    case Mod:open(Opts) of
        {ok, State} -> {ok, {Mod, State}};
        {error, _} = Error -> Error
    end.

-spec close(handle()) -> ok.
close({Mod, State}) -> Mod:close(State).

-spec put(handle(), binary(), xet_hash:hash(), body()) -> ok | {error, term()}.
put({Mod, State}, Ns, Hash, Body) -> Mod:put(State, Ns, Hash, Body).

-spec get_range(handle(), binary(), xet_hash:hash(), non_neg_integer(), pos_integer()) ->
    {ok, binary()} | {error, term()}.
get_range({Mod, State}, Ns, Hash, Start, Len) -> Mod:get_range(State, Ns, Hash, Start, Len).

-spec size(handle(), binary(), xet_hash:hash()) -> {ok, non_neg_integer()} | {error, term()}.
size({Mod, State}, Ns, Hash) -> Mod:size(State, Ns, Hash).

-spec exists(handle(), binary(), xet_hash:hash()) -> boolean().
exists({Mod, State}, Ns, Hash) -> Mod:exists(State, Ns, Hash).

-spec delete(handle(), binary(), xet_hash:hash()) -> ok | {error, term()}.
delete({Mod, State}, Ns, Hash) -> Mod:delete(State, Ns, Hash).
