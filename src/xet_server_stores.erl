%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Owns the server's storage handles: opens the rocksdb metadata store
%% (with lock-retry, since a brutally killed predecessor releases the
%% LOCK file only when its NIF resource is destructed) and the blob
%% store, publishes both through persistent_term, closes them cleanly in
%% terminate. Handlers read the environment lock-free via
%% xet_server:env/1; this process is never in the data path.
-module(xet_server_stores).

-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-define(OPEN_RETRIES, 20).
-define(OPEN_RETRY_WAIT, 250).

-record(state, {
    name :: atom(),
    metadata :: xet_metadata:handle(),
    blob :: xet_blob_store:handle()
}).
-type state() :: #state{}.

start_link(Config) ->
    gen_server:start_link(?MODULE, Config, []).

-spec init(map()) -> {ok, state()} | {stop, term()}.
init(#{name := Name} = Config0) ->
    process_flag(trap_exit, true),
    DataDir = maps:get(data_dir, Config0),
    MetaDir = filename:join(DataDir, "metadata"),
    maybe
        ok ?= filelib:ensure_path(MetaDir),
        sweep_spool(filename:join(DataDir, "spool")),
        {ok, Metadata} ?= open_metadata(MetaDir, ?OPEN_RETRIES),
        {ok, Blob} ?= open_blob(Config0),
        {ok, Config} ?= resolve_url_secret(Config0, Metadata),
        Env = #{metadata => Metadata, blob => Blob, config => Config},
        persistent_term:put({xet_server_env, Name}, Env),
        {ok, #state{name = Name, metadata = Metadata, blob = Blob}}
    else
        {error, Reason} ->
            logger:error("barrel_xet stores failed to open under ~ts: ~p", [MetaDir, Reason]),
            {stop, Reason}
    end.

%% A crash between spool-file creation and its per-request cleanup
%% leaves an orphan upload.*.tmp. The listener starts after this process
%% (rest_for_one: stores -> keys -> listener), so no upload is in flight
%% and stale spool files can be reclaimed. Best-effort: a delete failure
%% does not block boot.
sweep_spool(SpoolDir) ->
    case filelib:wildcard(filename:join(SpoolDir, "upload.*.tmp")) of
        [] ->
            ok;
        Stale ->
            lists:foreach(fun(F) -> _ = file:delete(F) end, Stale),
            logger:info("swept ~b stale spool file(s) from ~ts", [length(Stale), SpoolDir])
    end.

%% Only lock contention is worth retrying: a predecessor's LOCK file is
%% released when its NIF resource is destructed, shortly after a crash.
open_metadata(Dir, Retries) ->
    case xet_metadata:open(xet_metadata_rocksdb, #{dir => Dir}) of
        {ok, Handle} ->
            {ok, Handle};
        {error, Reason} when Retries > 0 ->
            case lock_error(Reason) of
                true ->
                    timer:sleep(?OPEN_RETRY_WAIT),
                    open_metadata(Dir, Retries - 1);
                false ->
                    {error, Reason}
            end;
        {error, _} = Error ->
            Error
    end.

lock_error({db_open, Message}) ->
    string:find(Message, "lock") =/= nomatch;
lock_error(_) ->
    false.

open_blob(#{blob := {fs, Opts}}) ->
    xet_blob_store:open(xet_store_fs, Opts);
open_blob(#{blob := {s3, Opts}}) ->
    xet_blob_store:open(xet_store_s3, Opts).

%% Signed data URLs must survive restarts: an explicit config secret
%% wins (and is never copied into the store, so rotating it stays a pure
%% config change), otherwise reuse the persisted one, otherwise generate
%% and persist. Same lifecycle as the dedup key ring in xet_keys.
resolve_url_secret(#{url_secret := _} = Config, _Metadata) ->
    {ok, Config};
resolve_url_secret(Config, Metadata) ->
    case xet_metadata:get_url_secret(Metadata) of
        {ok, Secret} ->
            {ok, Config#{url_secret => Secret}};
        not_found ->
            Secret = crypto:strong_rand_bytes(32),
            case xet_metadata:put_url_secret(Metadata, Secret) of
                ok -> {ok, Config#{url_secret => Secret}};
                {error, _} = Error -> Error
            end
    end.

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #state{name = Name, metadata = Metadata, blob = Blob}) ->
    _ = persistent_term:erase({xet_server_env, Name}),
    _ = xet_blob_store:close(Blob),
    _ = xet_metadata:close(Metadata),
    ok.
