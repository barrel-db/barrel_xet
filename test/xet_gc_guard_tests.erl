%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(xet_gc_guard_tests).

-include_lib("eunit/include/eunit.hrl").

note_and_referenced_since_test() ->
    ok = xet_gc_guard:init(),
    T0 = erlang:monotonic_time(),
    xet_gc_guard:note_referenced([<<101:256>>]),
    ?assert(xet_gc_guard:referenced_since(<<101:256>>, T0)),
    ?assertNot(xet_gc_guard:referenced_since(<<102:256>>, T0)),
    %% Not referenced since a future instant.
    ?assertNot(xet_gc_guard:referenced_since(<<101:256>>, erlang:monotonic_time() + 1000000000)).

prune_test() ->
    ok = xet_gc_guard:init(),
    T0 = erlang:monotonic_time(),
    xet_gc_guard:note_referenced([<<111:256>>]),
    %% The note is after T0, so pruning before T0 keeps it.
    xet_gc_guard:prune(T0),
    ?assert(xet_gc_guard:referenced_since(<<111:256>>, T0)),
    %% Pruning before a later instant drops it.
    xet_gc_guard:prune(erlang:monotonic_time()),
    ?assertNot(xet_gc_guard:referenced_since(<<111:256>>, T0)).

%% An active registration blocks the exclusive section until it drains.
mutual_exclusion_test() ->
    ok = xet_gc_guard:init(),
    Parent = self(),
    Reg = spawn(fun() ->
        xet_gc_guard:in_registration(fun() ->
            Parent ! reg_in,
            receive
                release -> ok
            end
        end),
        Parent ! reg_out
    end),
    receive
        reg_in -> ok
    after 1000 -> error(no_reg_in)
    end,
    ?assertEqual({error, busy}, xet_gc_guard:with_exclusive(50, fun() -> ok end)),
    Reg ! release,
    receive
        reg_out -> ok
    after 1000 -> error(no_reg_out)
    end,
    ?assertEqual({ok, done}, xet_gc_guard:with_exclusive(1000, fun() -> done end)).

%% Registrations share the section: N enter concurrently.
concurrent_registrations_test() ->
    ok = xet_gc_guard:init(),
    Parent = self(),
    N = 5,
    _ = [
        spawn(fun() ->
            xet_gc_guard:in_registration(fun() ->
                Parent ! {in, self()},
                receive
                    go -> ok
                end
            end)
        end)
     || _ <- lists:seq(1, N)
    ],
    Ins = [
        receive
            {in, P} -> P
        after 1000 -> error(timeout)
        end
     || _ <- lists:seq(1, N)
    ],
    ?assertEqual(N, length(Ins)),
    [P ! go || P <- Ins].
