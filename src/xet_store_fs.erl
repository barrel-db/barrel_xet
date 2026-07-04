%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Filesystem blob store: <root>/<ns>/<h0h1>/<h2h3>/<hex>.xorb.
%%
%% Writes are crash-safe: bytes go to a unique .tmp sibling, get fsynced,
%% are renamed into place, and the parent directory entry is fsynced too
%% (xet_nif:fsync_dir), so acknowledged blobs survive power loss. Stale
%% .tmp files from crashed writes are swept at open.
-module(xet_store_fs).

-behaviour(xet_blob_store).

-export([open/1, close/1, put/4, get_range/5, size/3, exists/3, delete/3, local_path/3]).

open(#{dir := Root}) ->
    ok = filelib:ensure_path(Root),
    sweep_tmp(Root),
    {ok, #{root => Root}}.

close(_State) ->
    ok.

put(State, Ns, Hash, Body) ->
    maybe
        {ok, Path} ?= blob_path(State, Ns, Hash),
        ok ?= filelib:ensure_dir(Path),
        case filelib:is_regular(Path) of
            true -> ok;
            false -> write_atomic(Path, Body)
        end
    end.

write_atomic(Path, Body) ->
    Tmp = Path ++ ".w" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".tmp",
    maybe
        {ok, Fd} ?= file:open(Tmp, [write, raw, binary]),
        ok ?= write_body(Fd, Body),
        ok ?= file:sync(Fd),
        ok ?= file:close(Fd),
        ok ?= file:rename(Tmp, Path),
        ok ?= xet_nif:fsync_dir(filename:dirname(Path))
    else
        Error ->
            _ = file:delete(Tmp),
            Error
    end.

write_body(Fd, {stream, Producer}) ->
    case Producer() of
        eof ->
            ok;
        {ok, Data, Next} ->
            case file:write(Fd, Data) of
                ok -> write_body(Fd, {stream, Next});
                {error, _} = Error -> Error
            end
    end;
write_body(Fd, IoData) ->
    file:write(Fd, IoData).

get_range(State, Ns, Hash, Start, Len) ->
    maybe
        {ok, Path} ?= blob_path(State, Ns, Hash),
        {ok, Fd} ?= open_read(Path),
        Result = read_exact(Fd, Start, Len),
        ok = file:close(Fd),
        Result
    end.

open_read(Path) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, Fd} -> {ok, Fd};
        {error, enoent} -> {error, not_found};
        {error, _} = Error -> Error
    end.

read_exact(Fd, Start, Len) ->
    case file:pread(Fd, Start, Len) of
        {ok, Bin} when byte_size(Bin) =:= Len -> {ok, Bin};
        {ok, _Short} -> {error, bad_range};
        eof -> {error, bad_range};
        {error, _} = Error -> Error
    end.

size(State, Ns, Hash) ->
    maybe
        {ok, Path} ?= blob_path(State, Ns, Hash),
        case file:read_file_info(Path) of
            {ok, Info} -> {ok, element(2, Info)};
            {error, enoent} -> {error, not_found};
            {error, _} = Error -> Error
        end
    end.

exists(State, Ns, Hash) ->
    case blob_path(State, Ns, Hash) of
        {ok, Path} -> filelib:is_regular(Path);
        {error, _} -> false
    end.

delete(State, Ns, Hash) ->
    maybe
        {ok, Path} ?= blob_path(State, Ns, Hash),
        case file:delete(Path) of
            ok -> ok;
            {error, enoent} -> ok;
            {error, _} = Error -> Error
        end
    end.

local_path(State, Ns, Hash) ->
    blob_path(State, Ns, Hash).

blob_path(#{root := Root}, Ns, Hash) ->
    case xet_blob_store:valid_namespace(Ns) of
        true ->
            Hex = binary_to_list(xet_hash:to_string(Hash)),
            {ok,
                filename:join(
                    [Root, binary_to_list(Ns), lists:sublist(Hex, 2), lists:sublist(Hex, 3, 2)] ++
                        [Hex ++ ".xorb"]
                )};
        false ->
            {error, bad_namespace}
    end.

sweep_tmp(Root) ->
    filelib:fold_files(
        Root,
        "\\.tmp$",
        true,
        fun(Path, ok) ->
            _ = file:delete(Path),
            ok
        end,
        ok
    ).
