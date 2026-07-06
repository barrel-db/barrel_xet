%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Free-space probe for the data directory, backed by os_mon's disksup
%% (which shells out to df). Results are cached briefly so an upload
%% preflight is a persistent_term read, not a df per request. os_mon is
%% started with only disksup (memsup/cpu_sup add overhead and alarms we
%% do not use) and its own disk-full alarming disabled.
-module(xet_disk).

-export([ensure_started/0, free_bytes/1, has_room/2, is_enospc/1]).

-define(CACHE_TTL_MS, 10000).

-spec ensure_started() -> ok.
ensure_started() ->
    _ = application:load(os_mon),
    ok = application:set_env(os_mon, start_memsup, false),
    ok = application:set_env(os_mon, start_cpu_sup, false),
    %% We decide the thresholds ourselves; silence disksup's alarms.
    ok = application:set_env(os_mon, disk_almost_full_threshold, 1.0),
    {ok, _} = application:ensure_all_started(os_mon),
    ok.

%% Free bytes on the filesystem holding Dir, or undefined when it cannot
%% be determined (callers treat undefined as "do not block").
-spec free_bytes(file:filename_all()) -> non_neg_integer() | undefined.
free_bytes(Dir) ->
    Now = erlang:monotonic_time(millisecond),
    Key = {?MODULE, free, Dir},
    case persistent_term:get(Key, undefined) of
        {At, Bytes} when Now - At < ?CACHE_TTL_MS ->
            Bytes;
        _ ->
            Bytes = query_free(Dir),
            persistent_term:put(Key, {Now, Bytes}),
            Bytes
    end.

%% Whether the data dir has room for NeedBytes. Unknown free space
%% (undefined) does not block: a probe failure must not stall uploads.
-spec has_room(file:filename_all(), non_neg_integer()) -> boolean().
has_room(Dir, Need) ->
    case free_bytes(Dir) of
        Free when is_integer(Free) -> Free >= Need;
        undefined -> true
    end.

query_free(Dir) ->
    try disksup:get_disk_info(unicode_list(Dir)) of
        [{_Id, _TotalKiB, AvailKiB, _Pct} | _] when is_integer(AvailKiB) ->
            AvailKiB * 1024;
        _ ->
            undefined
    catch
        _Class:_Reason -> undefined
    end.

unicode_list(Dir) when is_binary(Dir) -> unicode:characters_to_list(Dir);
unicode_list(Dir) -> Dir.

%% Recognize an out-of-space error from either backend. The FS path
%% surfaces the clean posix atom; rocksdb wraps a status string.
-spec is_enospc(term()) -> boolean().
is_enospc(enospc) ->
    true;
is_enospc({error, Reason}) ->
    is_enospc(Reason);
is_enospc(Reason) when is_tuple(Reason) ->
    Text = string:lowercase(unicode:characters_to_binary(io_lib:format("~p", [Reason]))),
    binary:match(Text, <<"no space">>) =/= nomatch orelse
        binary:match(Text, <<"enospc">>) =/= nomatch;
is_enospc(_Other) ->
    false.
