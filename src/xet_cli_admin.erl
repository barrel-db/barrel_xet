%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% `xet admin <command>`: the server's admin endpoints from the shell.
%%
%%   xet admin stats                  store counts and GC status
%%   xet admin gc [--dry-run]         start a garbage collection
%%   xet admin gc-status              the running flag and the last run
%%   xet admin scrub                  start a verify-at-rest pass
%%   xet admin scrub-status           the running flag and the last run
%%   xet admin backup [--checkpoint]  incremental backup (or a checkpoint)
%%   xet admin backups                backups, newest first
%%   xet admin verify-backup <id>     check one backup's files
%%   xet admin delete-file <hash>     drop a file record
%%
%% The response JSON goes to stdout. Exit 0 on success, 1 on an error
%% (with a one-line reason on stderr), 2 on usage.
-module(xet_cli_admin).

-export([run/2, usage/0]).

-spec run(xet_client:client(), [string()]) -> non_neg_integer().
run(Client, Args) ->
    case request(Client, Args) of
        usage ->
            usage(),
            2;
        {bad_arg, Message} ->
            fail(Message, []);
        Result ->
            report(Result)
    end.

request(C, ["stats"]) ->
    xet_client_admin:stats(C);
request(C, ["gc"]) ->
    xet_client_admin:gc(C, #{});
request(C, ["gc", "--dry-run"]) ->
    xet_client_admin:gc(C, #{dry_run => true});
request(C, ["gc-status"]) ->
    xet_client_admin:gc_status(C);
request(C, ["scrub"]) ->
    xet_client_admin:scrub(C);
request(C, ["scrub-status"]) ->
    xet_client_admin:scrub_status(C);
request(C, ["backup"]) ->
    xet_client_admin:backup(C, incremental);
request(C, ["backup", "--checkpoint"]) ->
    xet_client_admin:backup(C, checkpoint);
request(C, ["backups"]) ->
    xet_client_admin:backups(C);
request(C, ["verify-backup", Id]) ->
    with_id(Id, fun(N) -> xet_client_admin:verify_backup(C, N) end);
request(C, ["delete-file", Hash]) ->
    with_hash(Hash, fun(H) -> xet_client_admin:delete_file(C, H) end);
request(_C, _Args) ->
    usage.

with_id(Arg, Fun) ->
    case string:to_integer(Arg) of
        {N, ""} when N >= 0 -> Fun(N);
        _ -> {bad_arg, "bad backup id: " ++ Arg}
    end.

with_hash(Arg, Fun) ->
    Bin = list_to_binary(Arg),
    case xet_hash:is_hash_string(Bin) of
        true -> Fun(xet_hash:from_string(Bin));
        false -> {bad_arg, "bad hash: " ++ Arg}
    end.

report({ok, Status, Body}) when Status >= 200, Status < 300 ->
    print(Body),
    0;
report({ok, Status, Body}) ->
    fail("admin request failed: ~b ~ts", [Status, reason(Status, Body)]);
report({error, Reason}) ->
    fail("admin request failed: ~p", [Reason]).

print(undefined) -> io:format(standard_io, "ok~n", []);
print(Body) when is_binary(Body) -> io:format(standard_io, "~ts~n", [Body]);
print(Body) -> io:format(standard_io, "~ts~n", [json:format(Body)]).

reason(401, _Body) -> "the token was not accepted";
reason(403, _Body) -> "the token lacks the admin scope";
reason(404, undefined) -> "not found (is the admin surface enabled on the server?)";
reason(_Status, #{<<"error">> := Error}) -> Error;
reason(_Status, _Body) -> "".

fail(Fmt, Args) ->
    io:format(standard_error, Fmt ++ "~n", Args),
    1.

-spec usage() -> ok.
usage() ->
    io:format(
        standard_error,
        "usage: xet admin stats | gc [--dry-run] | gc-status | scrub | scrub-status~n"
        "                 | backup [--checkpoint] | backups | verify-backup <id>~n"
        "                 | delete-file <hash>~n",
        []
    ).
