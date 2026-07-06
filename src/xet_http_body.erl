%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Shared request-body spooling for upload endpoints: bytes accumulate
%% in memory up to a threshold, then spill to a spool file; a hard size
%% cap aborts mid-stream. Nothing here interprets the bytes.
-module(xet_http_body).

-export([read_spooled/2, binary_of/1, cleanup/1]).

-type spooled() :: {memory, binary()} | {file, file:filename_all()}.
-export_type([spooled/0]).

-spec read_spooled(livery_req:req(), #{
    cap := pos_integer(),
    memory_max := pos_integer(),
    spool_dir := file:filename_all()
}) -> {ok, spooled()} | {error, binary()}.
read_spooled(Req, #{cap := Cap} = Opts) ->
    case livery_req:body(Req) of
        empty ->
            {error, <<"empty_body">>};
        {buffered, IoData} ->
            Bin = iolist_to_binary(IoData),
            case byte_size(Bin) =< Cap of
                true -> {ok, {memory, Bin}};
                false -> {error, <<"too_large">>}
            end;
        {stream, Reader} ->
            read_stream(Reader, Opts, 0, [])
    end.

read_stream(Reader, #{cap := Cap, memory_max := MemMax} = Opts, Size, Acc) ->
    case livery_body:read(Reader, 30000) of
        {ok, Chunk, Reader1} ->
            Size1 = Size + byte_size(Chunk),
            case Size1 > Cap of
                true ->
                    {error, <<"too_large">>};
                false when Size1 > MemMax ->
                    to_disk(Reader1, Opts, Size1, [Chunk | Acc]);
                false ->
                    read_stream(Reader1, Opts, Size1, [Chunk | Acc])
            end;
        {done, _Reader1} ->
            {ok, {memory, iolist_to_binary(lists:reverse(Acc))}};
        {error, Reason, _Reader1} ->
            {error, reason_to_binary(Reason)}
    end.

to_disk(Reader, #{spool_dir := SpoolDir} = Opts, Size, Acc) ->
    xet_metrics:count(<<"xet.spool.spilled">>, 1),
    ok = filelib:ensure_path(SpoolDir),
    Path = filename:join(
        SpoolDir, "upload." ++ integer_to_list(erlang:unique_integer([positive])) ++ ".tmp"
    ),
    {ok, Fd} = file:open(Path, [write, raw, binary]),
    ok = file:write(Fd, lists:reverse(Acc)),
    drain_to_disk(Reader, Opts, Size, Fd, Path).

drain_to_disk(Reader, #{cap := Cap} = Opts, Size, Fd, Path) ->
    case livery_body:read(Reader, 30000) of
        {ok, Chunk, Reader1} ->
            Size1 = Size + byte_size(Chunk),
            case Size1 > Cap of
                true ->
                    abort_disk(Fd, Path, <<"too_large">>);
                false ->
                    ok = file:write(Fd, Chunk),
                    drain_to_disk(Reader1, Opts, Size1, Fd, Path)
            end;
        {done, _} ->
            ok = file:close(Fd),
            {ok, {file, Path}};
        {error, Reason, _} ->
            abort_disk(Fd, Path, reason_to_binary(Reason))
    end.

abort_disk(Fd, Path, Reason) ->
    _ = file:close(Fd),
    _ = file:delete(Path),
    {error, Reason}.

-spec binary_of(spooled()) -> binary().
binary_of({memory, Bin}) ->
    Bin;
binary_of({file, Path}) ->
    {ok, Bin} = file:read_file(Path),
    Bin.

-spec cleanup(spooled()) -> ok.
cleanup({memory, _}) ->
    ok;
cleanup({file, Path}) ->
    _ = file:delete(Path),
    ok.

reason_to_binary(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason);
reason_to_binary(Reason) ->
    iolist_to_binary(io_lib:format("~0p", [Reason])).
