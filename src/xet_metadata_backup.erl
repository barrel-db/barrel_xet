%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Incremental metadata backups on the rocksdb BackupEngine, kept under
%% <backup_dir>/engine. Each backup shares the SST files it has in common
%% with the previous ones, so only what changed is copied. The engine is
%% opened per call and closed after, so no handle outlives a request.
%%
%% create/3 needs the open database; list/1, verify/2 and restore_latest/2
%% work on the backup directory alone, and restore_latest/2 is for a
%% stopped node.
-module(xet_metadata_backup).

-export([create/3, list/1, verify/2, restore_latest/2]).

-type info() :: #{
    id := non_neg_integer(),
    timestamp := non_neg_integer(),
    size := non_neg_integer(),
    files := non_neg_integer()
}.
-export_type([info/0]).

%% Back up the open database, keep the newest Keep backups, and return
%% the new backup's info.
-spec create(rocksdb:db_handle(), file:filename_all(), pos_integer()) ->
    {ok, info()} | {error, term()}.
create(Db, BackupDir, Keep) ->
    with_engine(BackupDir, fun(Engine) ->
        maybe
            ok ?= rocksdb:create_new_backup(Engine, Db),
            ok ?= rocksdb:purge_old_backup(Engine, Keep),
            {ok, [Latest | _]} ?= infos(Engine),
            {ok, Latest}
        end
    end).

-spec list(file:filename_all()) -> {ok, [info()]} | {error, term()}.
list(BackupDir) ->
    with_engine(BackupDir, fun infos/1).

%% Checks that the backup's files exist with the recorded sizes.
-spec verify(file:filename_all(), non_neg_integer()) -> ok | not_found | {error, term()}.
verify(BackupDir, Id) ->
    with_engine(BackupDir, fun(Engine) -> verify_known(Engine, Id) end).

verify_known(Engine, Id) ->
    maybe
        {ok, Infos} ?= infos(Engine),
        case lists:any(fun(#{id := I}) -> I =:= Id end, Infos) of
            true -> rocksdb:verify_backup(Engine, Id);
            false -> not_found
        end
    end.

%% Restore the newest backup into DbDir. Run on a stopped node; DbDir is
%% the server's <data_dir>/metadata.
-spec restore_latest(file:filename_all(), file:filename_all()) -> ok | {error, term()}.
restore_latest(BackupDir, DbDir) ->
    with_engine(BackupDir, fun(Engine) ->
        rocksdb:restore_db_from_latest_backup(Engine, to_list(DbDir))
    end).

with_engine(BackupDir, Fun) ->
    Dir = to_list(filename:join(BackupDir, "engine")),
    ok = filelib:ensure_path(Dir),
    case rocksdb:open_backup_engine(Dir) of
        {ok, Engine} ->
            try
                Fun(Engine)
            after
                rocksdb:close_backup_engine(Engine)
            end;
        {error, _} = Error ->
            Error
    end.

%% Backups newest first. The engine reports each as backup_id,
%% timestamp, size and number_files.
infos(Engine) ->
    {ok, Infos} = rocksdb:get_backup_info(Engine),
    {ok, lists:sort(fun(#{id := A}, #{id := B}) -> A >= B end, [rename(I) || I <- Infos])}.

%% rocksdb 3.2.1's backup_info() type keys the id as `id`, while the NIF
%% sends `backup_id`; accept either.
rename(#{timestamp := Ts, size := Size, number_files := Files} = Info) ->
    Id = maps:get(backup_id, Info, maps:get(id, Info, 0)),
    #{id => Id, timestamp => Ts, size => Size, files => Files}.

to_list(Path) -> unicode:characters_to_list(Path).
