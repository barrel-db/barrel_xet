%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Blob store behaviour: where serialized xorbs live. Backends:
%% xet_store_fs (local disk) and xet_store_s3 (livery_s3). The server
%% holds a {Module, State} handle and goes through the wrappers.
%%
%% put/4 accepts iodata or the livery_s3 streaming producer shape
%% ({stream, fun(() -> eof | {ok, binary(), fun()})}) so both backends
%% take the same body. Puts are idempotent: content addressing makes
%% same-hash writes interchangeable.
-module(xet_blob_store).

-export([open/2, close/1, put/4, get_range/5, size/3, exists/3, delete/3, presign/4]).
-export([local_path/3, valid_namespace/1]).

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
-callback presign(term(), binary(), xet_hash:hash(), pos_integer()) ->
    {ok, binary()} | {error, term()}.
-callback local_path(term(), binary(), xet_hash:hash()) ->
    {ok, file:filename_all()} | {error, term()}.

-optional_callbacks([presign/4, local_path/3]).

-spec open(module(), map()) -> {ok, handle()} | {error, term()}.
open(Mod, Opts) ->
    case Mod:open(Opts) of
        {ok, State} -> {ok, {Mod, State}};
        {error, _} = Error -> Error
    end.

-spec close(handle()) -> ok.
close({Mod, State}) -> Mod:close(State).

-spec put(handle(), binary(), xet_hash:hash(), body()) -> ok | {error, term()}.
put({Mod, State}, Ns, Hash, Body) ->
    Result = timed(Mod, put, fun() -> Mod:put(State, Ns, Hash, Body) end),
    count_write(Mod, Result, Body),
    Result.

-spec get_range(handle(), binary(), xet_hash:hash(), non_neg_integer(), pos_integer()) ->
    {ok, binary()} | {error, term()}.
get_range({Mod, State}, Ns, Hash, Start, Len) ->
    Result = timed(Mod, get_range, fun() -> Mod:get_range(State, Ns, Hash, Start, Len) end),
    count_read(Mod, Result),
    Result.

-spec size(handle(), binary(), xet_hash:hash()) -> {ok, non_neg_integer()} | {error, term()}.
size({Mod, State}, Ns, Hash) -> Mod:size(State, Ns, Hash).

-spec exists(handle(), binary(), xet_hash:hash()) -> boolean().
exists({Mod, State}, Ns, Hash) -> Mod:exists(State, Ns, Hash).

-spec delete(handle(), binary(), xet_hash:hash()) -> ok | {error, term()}.
delete({Mod, State}, Ns, Hash) ->
    timed(Mod, delete, fun() -> Mod:delete(State, Ns, Hash) end).

%% Time a store op and record xet.store.op.duration{backend, op}. The
%% `after' records on both normal return and exception, and passes the
%% result (or the raised error) through unchanged.
timed(Mod, Op, Fun) ->
    Start = erlang:monotonic_time(),
    try
        Fun()
    after
        Micros = erlang:convert_time_unit(erlang:monotonic_time() - Start, native, microsecond),
        xet_metrics:observe(
            <<"xet.store.op.duration">>,
            Micros / 1.0e6,
            #{backend => backend(Mod), op => Op}
        )
    end.

count_write(Mod, ok, Body) ->
    case Body of
        {stream, _Producer} -> ok;
        _ -> xet_metrics:count(<<"xet.store.write.bytes">>, iolist_size(Body), attrs(Mod))
    end;
count_write(_Mod, _Result, _Body) ->
    ok.

count_read(Mod, {ok, Bin}) ->
    xet_metrics:count(<<"xet.store.read.bytes">>, byte_size(Bin), attrs(Mod));
count_read(_Mod, _Result) ->
    ok.

attrs(Mod) ->
    #{backend => backend(Mod)}.

backend(xet_store_fs) -> fs;
backend(xet_store_s3) -> s3;
backend(_Mod) -> other.

%% Presigned fetch URL when the backend supports it (S3); FS-backed
%% deployments serve ranges themselves through the signed data endpoint.
-spec presign(handle(), binary(), xet_hash:hash(), pos_integer()) ->
    {ok, binary()} | {error, not_supported | term()}.
presign({Mod, State}, Ns, Hash, ExpiresSecs) ->
    case erlang:function_exported(Mod, presign, 4) of
        true -> Mod:presign(State, Ns, Hash, ExpiresSecs);
        false -> {error, not_supported}
    end.

%% Local file path of a blob when the backend serves from disk (used by
%% the range-serving data endpoint; livery streams the file directly).
-spec local_path(handle(), binary(), xet_hash:hash()) ->
    {ok, file:filename_all()} | {error, not_supported | term()}.
local_path({Mod, State}, Ns, Hash) ->
    case erlang:function_exported(Mod, local_path, 3) of
        true -> Mod:local_path(State, Ns, Hash);
        false -> {error, not_supported}
    end.

%% Namespaces are single path components from a small safe alphabet,
%% shared by every backend.
-spec valid_namespace(term()) -> boolean().
valid_namespace(Ns) when is_binary(Ns), byte_size(Ns) >= 1, byte_size(Ns) =< 64 ->
    ns_chars(Ns);
valid_namespace(_) ->
    false.

ns_chars(<<C, Rest/binary>>) when C >= $a, C =< $z ->
    ns_chars(Rest);
ns_chars(<<C, Rest/binary>>) when C >= $0, C =< $9 ->
    ns_chars(Rest);
ns_chars(<<C, Rest/binary>>) when C =:= $-; C =:= $_ ->
    ns_chars(Rest);
ns_chars(<<>>) ->
    true;
ns_chars(_) ->
    false.
