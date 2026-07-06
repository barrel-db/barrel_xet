%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(xet_disk_tests).

-include_lib("eunit/include/eunit.hrl").

is_enospc_test() ->
    ?assert(xet_disk:is_enospc(enospc)),
    ?assert(xet_disk:is_enospc({error, enospc})),
    ?assert(xet_disk:is_enospc({db_write, "IO error: No space left on device"})),
    ?assertNot(xet_disk:is_enospc(closed)),
    ?assertNot(xet_disk:is_enospc({error, not_found})).

has_room_test() ->
    ok = xet_disk:ensure_started(),
    Dir = os:getenv("TMPDIR", "/tmp"),
    ?assert(xet_disk:has_room(Dir, 0)),
    ?assertNot(xet_disk:has_room(Dir, 1 bsl 60)),
    ?assert(is_integer(xet_disk:free_bytes(Dir))).

undefined_free_does_not_block_test() ->
    %% When free space cannot be determined (probe failure), has_room
    %% must not block. Seed the cache with a fresh undefined entry.
    Dir = "/xet-fake-" ++ integer_to_list(erlang:unique_integer([positive])),
    persistent_term:put({xet_disk, free, Dir}, {erlang:monotonic_time(millisecond), undefined}),
    ?assert(xet_disk:has_room(Dir, 1 bsl 60)).
