%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Admin endpoints. These are barrel_xet extensions, NOT part of
%% draft-denis-xet-05: they live under /admin, require the admin scope,
%% and are mounted only when the server is started with
%% admin => #{enabled => true}. GET /admin/stats reports store counts;
%% later tasks extend the response with GC and scrub status.
-module(xet_h_admin).

-export([
    stats/1,
    delete_file/1,
    gc_trigger/1,
    gc_status/1,
    scrub_trigger/1,
    scrub_status/1,
    backup/1
]).

stats(Req) ->
    Name = livery_req:config(server, Req),
    #{metadata := Metadata} = xet_server:env(Name),
    Body = #{
        metadata => xet_metadata:stats(Metadata),
        gc => gc_json(xet_gc:status(Name))
    },
    livery_resp:json(200, json:encode(Body)).

%% POST /admin/gc[?dry_run=true]: start a single-flight collection.
gc_trigger(Req) ->
    Name = livery_req:config(server, Req),
    {ok, Status} = xet_gc:trigger(Name, #{dry_run => dry_run(Req)}),
    livery_resp:json(202, json:encode(#{status => atom_to_binary(Status)})).

%% GET /admin/gc: running flag and last run summary.
gc_status(Req) ->
    Name = livery_req:config(server, Req),
    livery_resp:json(200, json:encode(gc_json(xet_gc:status(Name)))).

dry_run(Req) ->
    Query = uri_string:dissect_query(livery_req:query(Req)),
    Value = proplists:get_value("dry_run", Query, proplists:get_value(<<"dry_run">>, Query)),
    Value =:= "true" orelse Value =:= <<"true">>.

%% POST /admin/scrub: start a single-flight verify-at-rest pass.
scrub_trigger(Req) ->
    Name = livery_req:config(server, Req),
    {ok, Status} = xet_scrub:trigger(Name),
    livery_resp:json(202, json:encode(#{status => atom_to_binary(Status)})).

%% GET /admin/scrub: running flag and last run summary.
scrub_status(Req) ->
    Name = livery_req:config(server, Req),
    livery_resp:json(200, json:encode(gc_json(xet_scrub:status(Name)))).

%% POST /admin/backup: checkpoint the metadata store into a timestamped
%% directory under backup_dir. 400 if backup_dir is unset, 409 while GC
%% is running (a concurrent delete could strand the blob copy step).
backup(Req) ->
    Name = livery_req:config(server, Req),
    #{metadata := Metadata, config := Config} = xet_server:env(Name),
    case maps:get(backup_dir, Config, undefined) of
        undefined ->
            xet_routes:error_response(400, <<"backup_dir_not_configured">>);
        BackupDir ->
            case maps:get(running, xet_gc:status(Name)) of
                true -> xet_routes:error_response(409, <<"gc_running">>);
                false -> do_backup(Metadata, BackupDir)
            end
    end.

do_backup(Metadata, BackupDir) ->
    Dir = filename:join(BackupDir, utc_stamp()),
    Target = unicode:characters_to_list(filename:join(Dir, "metadata")),
    ok = filelib:ensure_path(Dir),
    case xet_metadata:checkpoint(Metadata, Target) of
        ok ->
            livery_resp:json(200, json:encode(#{path => list_to_binary(Target)}));
        {error, Reason} ->
            logger:error("backup checkpoint failed: ~p", [Reason]),
            xet_routes:error_response(500, <<"backup_failed">>)
    end.

utc_stamp() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:universal_time(),
    iolist_to_binary(
        io_lib:format("~4..0w~2..0w~2..0wT~2..0w~2..0w~2..0wZ", [Y, Mo, D, H, Mi, S])
    ).

gc_json(#{running := Running, last := Last}) ->
    #{
        running => Running,
        last =>
            case Last of
                undefined -> null;
                _ -> Last
            end
    }.

%% DELETE /admin/files/{hash}: drop a file record (its unique xorbs
%% become collectable). 204 on delete, 404 if the file is not present.
%% There is no file delete in the spec; this is an extension.
delete_file(Req) ->
    Name = livery_req:config(server, Req),
    #{metadata := Metadata} = xet_server:env(Name),
    HashStr = livery_req:binding(<<"hash">>, Req),
    case xet_hash:is_hash_string(HashStr) of
        false ->
            xet_routes:error_response(400, <<"bad_hash">>);
        true ->
            Hash = xet_hash:from_string(HashStr),
            case xet_metadata:file_exists(Metadata, Hash) of
                false ->
                    livery_resp:empty(404);
                true ->
                    ok = xet_metadata:delete_file(Metadata, Hash),
                    livery_resp:empty(204)
            end
    end.
