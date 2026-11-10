%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Metadata backup endpoints (barrel_xet extensions under /admin, admin
%% scope, mounted with admin => #{enabled => true}):
%%
%%   POST /admin/backup                 incremental backup (BackupEngine)
%%   POST /admin/backup?mode=checkpoint full checkpoint, as in 0.2
%%   GET  /admin/backups                backups, newest first
%%   POST /admin/backups/:id/verify     check a backup's files
%%
%% A backup is refused with 409 while GC runs (a concurrent delete could
%% strand the blob copy that follows) or while another backup runs, and
%% with 400 when backup_dir is not configured.
-module(xet_h_admin_backup).

-export([backup/1, list/1, verify/1]).

backup(Req) ->
    Name = livery_req:config(server, Req),
    #{metadata := Metadata, config := Config} = xet_server:env(Name),
    with_backup_dir(Config, fun(Dir) ->
        case maps:get(running, xet_gc:status(Name)) of
            true -> xet_routes:error_response(409, <<"gc_running">>);
            false -> single_flight(Name, fun() -> run(mode(Req), Metadata, Dir, Config) end)
        end
    end).

list(Req) ->
    #{config := Config} = xet_server:env(livery_req:config(server, Req)),
    with_backup_dir(Config, fun(Dir) ->
        case xet_metadata_backup:list(Dir) of
            {ok, Backups} -> livery_resp:json(200, json:encode(#{backups => Backups}));
            {error, Reason} -> failed("backup list", Reason)
        end
    end).

verify(Req) ->
    #{config := Config} = xet_server:env(livery_req:config(server, Req)),
    with_backup_dir(Config, fun(Dir) ->
        case parse_id(livery_req:binding(<<"id">>, Req)) of
            {ok, Id} -> verify_id(Dir, Id);
            error -> xet_routes:error_response(400, <<"bad_backup_id">>)
        end
    end).

verify_id(Dir, Id) ->
    case xet_metadata_backup:verify(Dir, Id) of
        ok -> livery_resp:json(200, json:encode(#{id => Id, verified => true}));
        not_found -> xet_routes:error_response(404, <<"no_such_backup">>);
        {error, Reason} -> failed("backup verify", Reason)
    end.

with_backup_dir(Config, Fun) ->
    case maps:get(backup_dir, Config, undefined) of
        undefined -> xet_routes:error_response(400, <<"backup_dir_not_configured">>);
        Dir -> Fun(Dir)
    end.

%% One backup at a time per server: the BackupEngine directory is not
%% safe to share between concurrent writers.
single_flight(Name, Fun) ->
    Lock = {{xet_backup, Name}, self()},
    case global:set_lock(Lock, [node()], 0) of
        true ->
            try
                Fun()
            after
                global:del_lock(Lock, [node()])
            end;
        false ->
            xet_routes:error_response(409, <<"backup_running">>)
    end.

run(checkpoint, Metadata, Dir, _Config) ->
    checkpoint(Metadata, Dir);
run(incremental, Metadata, Dir, Config) ->
    case xet_metadata:backup(Metadata, Dir, maps:get(backup_keep, Config)) of
        {ok, Info} -> livery_resp:json(200, json:encode(Info#{mode => incremental}));
        {error, Reason} -> failed("incremental backup", Reason)
    end.

checkpoint(Metadata, BackupDir) ->
    Dir = filename:join(BackupDir, utc_stamp()),
    Target = unicode:characters_to_list(filename:join(Dir, "metadata")),
    ok = filelib:ensure_path(Dir),
    case xet_metadata:checkpoint(Metadata, Target) of
        ok ->
            livery_resp:json(
                200, json:encode(#{mode => checkpoint, path => list_to_binary(Target)})
            );
        {error, Reason} ->
            failed("backup checkpoint", Reason)
    end.

mode(Req) ->
    Query = uri_string:dissect_query(livery_req:query(Req)),
    case proplists:get_value(<<"mode">>, Query, proplists:get_value("mode", Query)) of
        M when M =:= <<"checkpoint">>; M =:= "checkpoint" -> checkpoint;
        _ -> incremental
    end.

parse_id(Bin) when is_binary(Bin) ->
    try binary_to_integer(Bin) of
        Id when Id >= 0 -> {ok, Id};
        _ -> error
    catch
        error:badarg -> error
    end;
parse_id(_) ->
    error.

failed(What, Reason) ->
    logger:error("~ts failed: ~p", [What, Reason]),
    xet_routes:error_response(500, <<"backup_failed">>).

utc_stamp() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:universal_time(),
    iolist_to_binary(
        io_lib:format("~4..0w~2..0w~2..0wT~2..0w~2..0w~2..0wZ", [Y, Mo, D, H, Mi, S])
    ).
