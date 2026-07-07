%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Mutual exclusion between shard registration and GC sweeping, so GC can
%% never delete a xorb that a concurrent registration is about to
%% reference. It is a read/write lock: registrations take a shared
%% section, a sweep takes an exclusive one. A registration also records
%% the xorb hashes it references (with a timestamp) before it commits, so
%% a sweep that ran its mark before the registration can skip any xorb
%% referenced since the mark started.
%%
%% Node-global (one lock for all instances): conservative but never
%% wrong, and GC is infrequent.
-module(xet_gc_guard).

-export([
    init/0,
    note_referenced/1,
    referenced_since/2,
    prune/1,
    in_registration/1,
    with_exclusive/2
]).

-define(TABLE, xet_gc_guard_refs).
-define(ATOMICS, {?MODULE, atomics}).
-define(SWEEP_IX, 1).
-define(SHARED_IX, 2).
-define(WAIT_MS, 2).

-spec init() -> ok.
init() ->
    case ets:whereis(?TABLE) of
        undefined ->
            _ = ets:new(?TABLE, [named_table, public, set, {write_concurrency, true}]),
            persistent_term:put(?ATOMICS, atomics:new(2, [{signed, false}])),
            ok;
        _ ->
            ok
    end.

%% Record that these xorb hashes are being referenced right now.
-spec note_referenced([xet_hash:hash()]) -> ok.
note_referenced(Hashes) ->
    Now = erlang:monotonic_time(),
    lists:foreach(fun(H) -> ets:insert(?TABLE, {H, Now}) end, Hashes),
    ok.

%% Was Hash referenced at or after the given (monotonic) instant?
-spec referenced_since(xet_hash:hash(), integer()) -> boolean().
referenced_since(Hash, Since) ->
    case ets:lookup(?TABLE, Hash) of
        [{_, When}] -> When >= Since;
        [] -> false
    end.

%% Drop notes older than a monotonic instant (a completed sweep no longer
%% needs them).
-spec prune(integer()) -> ok.
prune(Before) ->
    _ = ets:select_delete(?TABLE, [{{'_', '$1'}, [{'<', '$1', Before}], [true]}]),
    ok.

%% Run Fun in a shared section (concurrent with other registrations, but
%% never with a sweep).
-spec in_registration(fun(() -> T)) -> T.
in_registration(Fun) ->
    Ref = atomics_ref(),
    enter_shared(Ref),
    try
        Fun()
    after
        atomics:sub(Ref, ?SHARED_IX, 1)
    end.

enter_shared(Ref) ->
    wait_not_sweeping(Ref),
    atomics:add(Ref, ?SHARED_IX, 1),
    case atomics:get(Ref, ?SWEEP_IX) of
        0 ->
            ok;
        _ ->
            %% A sweep slipped in; back out and retry.
            atomics:sub(Ref, ?SHARED_IX, 1),
            enter_shared(Ref)
    end.

wait_not_sweeping(Ref) ->
    case atomics:get(Ref, ?SWEEP_IX) of
        0 ->
            ok;
        _ ->
            timer:sleep(?WAIT_MS),
            wait_not_sweeping(Ref)
    end.

%% Run Fun in the exclusive section once in-flight registrations drain,
%% giving up after TimeoutMs. New registrations block until it returns.
-spec with_exclusive(non_neg_integer(), fun(() -> T)) -> {ok, T} | {error, busy}.
with_exclusive(TimeoutMs, Fun) ->
    Ref = atomics_ref(),
    atomics:put(Ref, ?SWEEP_IX, 1),
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    case drain_shared(Ref, Deadline) of
        ok ->
            try
                {ok, Fun()}
            after
                atomics:put(Ref, ?SWEEP_IX, 0)
            end;
        timeout ->
            atomics:put(Ref, ?SWEEP_IX, 0),
            {error, busy}
    end.

drain_shared(Ref, Deadline) ->
    case atomics:get(Ref, ?SHARED_IX) of
        0 ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    timeout;
                false ->
                    timer:sleep(?WAIT_MS),
                    drain_shared(Ref, Deadline)
            end
    end.

atomics_ref() ->
    persistent_term:get(?ATOMICS).
