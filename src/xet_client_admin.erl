%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Client for the server's admin endpoints (barrel_xet extensions under
%% /admin; the token needs the admin scope and the server must run with
%% admin => #{enabled => true}). Each call returns the HTTP status and the
%% decoded JSON body (undefined when there is none), or a transport error.
-module(xet_client_admin).

-export([
    stats/1,
    gc/2,
    gc_status/1,
    scrub/1,
    scrub_status/1,
    backup/2,
    backups/1,
    verify_backup/2,
    delete_file/2
]).

-type result() :: {ok, 100..599, term()} | {error, term()}.
-export_type([result/0]).

-spec stats(xet_client:client()) -> result().
stats(Client) -> call(Client, get, <<"/admin/stats">>).

%% Opts: dry_run => boolean().
-spec gc(xet_client:client(), map()) -> result().
gc(Client, #{dry_run := true}) -> call(Client, post, <<"/admin/gc?dry_run=true">>);
gc(Client, _Opts) -> call(Client, post, <<"/admin/gc">>).

-spec gc_status(xet_client:client()) -> result().
gc_status(Client) -> call(Client, get, <<"/admin/gc">>).

-spec scrub(xet_client:client()) -> result().
scrub(Client) -> call(Client, post, <<"/admin/scrub">>).

-spec scrub_status(xet_client:client()) -> result().
scrub_status(Client) -> call(Client, get, <<"/admin/scrub">>).

%% Mode: incremental (the server's default) or checkpoint.
-spec backup(xet_client:client(), incremental | checkpoint) -> result().
backup(Client, checkpoint) -> call(Client, post, <<"/admin/backup?mode=checkpoint">>);
backup(Client, incremental) -> call(Client, post, <<"/admin/backup">>).

-spec backups(xet_client:client()) -> result().
backups(Client) -> call(Client, get, <<"/admin/backups">>).

-spec verify_backup(xet_client:client(), non_neg_integer()) -> result().
verify_backup(Client, Id) ->
    call(Client, post, <<"/admin/backups/", (integer_to_binary(Id))/binary, "/verify">>).

-spec delete_file(xet_client:client(), xet_hash:hash()) -> result().
delete_file(Client, FileHash) ->
    call(Client, delete, <<"/admin/files/", (xet_hash:to_string(FileHash))/binary>>).

call(Client, Method, Path) ->
    case xet_client:request(Client, Method, Path, #{}) of
        {ok, #{status := Status, body := {full, Body}}} -> {ok, Status, decode(Body)};
        {error, _} = Error -> Error
    end.

decode(<<>>) ->
    undefined;
decode(Body) ->
    try
        json:decode(Body)
    catch
        error:_ -> Body
    end.
