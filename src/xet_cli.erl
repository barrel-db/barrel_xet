%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Command-line client. Built as the `xet` escript (see rebar.config).
%%
%%   xet up <file>                upload a file, print its file hash
%%   xet download <hash> <out>    download a file to <out>
%%   xet info <hash>              print whether the file exists on the server
%%
%% Configuration from the environment:
%%   XET_ENDPOINT  base URL (default http://localhost:8080)
%%   XET_TOKEN     bearer token (optional)
%%
%% run/1 returns an exit code and is what the smoke tests drive; main/1
%% wraps it with halt/1 for the escript.
-module(xet_cli).

-export([main/1, run/1]).

-spec main([string()]) -> no_return().
main(Args) ->
    {ok, _} = application:ensure_all_started(barrel_xet),
    halt(run(Args)).

-spec run([string()]) -> non_neg_integer().
run(["up", File]) ->
    with_client(fun(Client) -> do_upload(Client, File) end);
run(["download", HashStr, Out]) ->
    with_client(fun(Client) -> do_download(Client, HashStr, Out) end);
run(["info", HashStr]) ->
    with_client(fun(Client) -> do_info(Client, HashStr) end);
run(_) ->
    usage(),
    2.

with_client(Fun) ->
    Fun(client()).

client() ->
    Endpoint = list_to_binary(os:getenv("XET_ENDPOINT", "http://localhost:8080")),
    Token = list_to_binary(os:getenv("XET_TOKEN", "")),
    xet_client:new(#{endpoint => Endpoint, token => Token}).

do_upload(Client, File) ->
    case xet_client_upload:upload_file(Client, list_to_binary(File), File) of
        {ok, #{file_hash := FileHash, stats := Stats}} ->
            io:format(standard_io, "~s~n", [xet_hash:to_string(FileHash)]),
            io:format(standard_error, "uploaded ~s (~b new bytes, ~b deduped)~n", [
                File, maps:get(new_bytes, Stats), maps:get(deduped_bytes, Stats)
            ]),
            0;
        {error, Reason} ->
            fail("upload failed: ~p", [Reason])
    end.

do_download(Client, HashStr, Out) ->
    case parse_hash(HashStr) of
        {ok, FileHash} ->
            case xet_client_download:download_file(Client, FileHash, Out) of
                ok ->
                    io:format(standard_error, "wrote ~s~n", [Out]),
                    0;
                {error, Reason} ->
                    fail("download failed: ~p", [Reason])
            end;
        error ->
            fail("bad hash: ~s", [HashStr])
    end.

do_info(Client, HashStr) ->
    case parse_hash(HashStr) of
        {ok, FileHash} ->
            case xet_client:head_file(Client, FileHash) of
                {ok, true} ->
                    io:format(standard_io, "present~n", []),
                    0;
                {ok, false} ->
                    io:format(standard_io, "absent~n", []),
                    1;
                {error, Reason} ->
                    fail("info failed: ~p", [Reason])
            end;
        error ->
            fail("bad hash: ~s", [HashStr])
    end.

parse_hash(HashStr) ->
    Bin = list_to_binary(HashStr),
    case xet_hash:is_hash_string(Bin) of
        true -> {ok, xet_hash:from_string(Bin)};
        false -> error
    end.

fail(Fmt, Args) ->
    io:format(standard_error, Fmt ++ "~n", Args),
    1.

usage() ->
    io:format(standard_error, "usage: xet up <file> | download <hash> <out> | info <hash>~n", []).
