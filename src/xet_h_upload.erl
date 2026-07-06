%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Shared upload guards for the xorb and shard endpoints: a disk-space
%% preflight and the mapping of a storage failure to its HTTP response.
-module(xet_h_upload).

-export([preflight/2, storage_error/1]).

%% Reject with 507 when the data dir lacks room for a spool copy plus
%% the eventual blob write (2x the cap) and the configured free-space
%% margin. Unknown free space does not block the upload.
-spec preflight(map(), atom()) -> ok | {error, term()}.
preflight(Config, CapKey) ->
    DataDir = maps:get(data_dir, Config),
    Need = 2 * maps:get(CapKey, Config) + maps:get(min_free_bytes, Config),
    case xet_disk:has_room(DataDir, Need) of
        true ->
            ok;
        false ->
            xet_metrics:count(<<"xet.storage.errors">>, 1, #{kind => insufficient_storage}),
            {error, xet_routes:error_response(507, <<"insufficient_storage">>)}
    end.

%% Out-of-space becomes 507, every other storage failure 500. The kind
%% is recorded either way.
-spec storage_error(term()) -> term().
storage_error(Reason) ->
    case xet_disk:is_enospc(Reason) of
        true ->
            xet_metrics:count(<<"xet.storage.errors">>, 1, #{kind => insufficient_storage}),
            xet_routes:error_response(507, <<"insufficient_storage">>);
        false ->
            xet_metrics:count(<<"xet.storage.errors">>, 1, #{kind => storage_error}),
            xet_routes:error_response(500, <<"storage_error">>)
    end.
