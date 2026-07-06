%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Readiness checks for /readyz. Unlike /healthz (a static liveness
%% ping), these probe that the instance can actually serve: the metadata
%% store answers, the blob store is reachable, and the dedup key ring is
%% present. livery_health:ready/1 returns 200 when all pass, else 503
%% listing the failed checks. Checks run in the request process, so each
%% is O(ms).
-module(xet_health).

-export([readyz/1]).

-spec readyz(map()) -> livery_middleware:handler().
readyz(Config) ->
    Name = maps:get(name, Config),
    livery_health:ready([
        {<<"metadata">>, fun() -> metadata(Name) end},
        {<<"blob">>, fun() -> blob(Name) end},
        {<<"disk">>, fun() -> disk(Name) end},
        {<<"keys">>, fun() -> keys(Name) end}
    ]).

%% A cheap rocksdb property read; raises if the handle is dead.
metadata(Name) ->
    #{metadata := Meta} = xet_server:env(Name),
    _ = xet_metadata:stats(Meta),
    ok.

%% A size probe surfaces an S3 outage (a non-not_found error), and for
%% the FS backend the store's own not_found cannot tell a healthy miss
%% from a vanished root, so the root directory is stat'd directly.
blob(Name) ->
    #{blob := Blob, config := Config} = xet_server:env(Name),
    case xet_blob_store:size(Blob, <<"default">>, xet_hash:zero_hash()) of
        {error, not_found} -> fs_root(Config);
        {ok, _Size} -> fs_root(Config);
        {error, _Other} -> {error, unreachable}
    end.

fs_root(#{blob := {fs, #{dir := Root}}}) ->
    case filelib:is_dir(Root) of
        true -> ok;
        false -> {error, missing_root}
    end;
fs_root(_Config) ->
    ok.

%% Unavailable once free space on the data dir falls below the same
%% margin that gates uploads, so a full node is drained before it starts
%% rejecting writes.
disk(Name) ->
    #{config := Config} = xet_server:env(Name),
    DataDir = maps:get(data_dir, Config),
    MinFree = maps:get(min_free_bytes, Config),
    case xet_disk:has_room(DataDir, MinFree) of
        true -> ok;
        false -> {error, low_disk}
    end.

keys(Name) ->
    _ = xet_keys:current(Name),
    ok.
