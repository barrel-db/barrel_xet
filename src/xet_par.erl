%% Bounded-concurrency parallel map. Results come back in input order.
%% A worker that raises yields {error, {worker_crash, Reason}} for its
%% element; the map itself never crashes. Runs in batches of at most
%% Limit, so at most Limit workers are live at once.
-module(xet_par).

-export([map/3]).

-define(WORKER_TIMEOUT, 600000).

-spec map(fun((A) -> B), [A], pos_integer()) -> [B].
map(_Fun, [], _Limit) ->
    [];
map(Fun, Items, Limit) ->
    lists:append([run_batch(Fun, Batch) || Batch <- batches(Items, Limit)]).

batches([], _Limit) ->
    [];
batches(Items, Limit) when length(Items) =< Limit ->
    [Items];
batches(Items, Limit) ->
    {Head, Tail} = lists:split(Limit, Items),
    [Head | batches(Tail, Limit)].

run_batch(Fun, Batch) ->
    Parent = self(),
    Ref = make_ref(),
    Indexed = lists:zip(lists:seq(1, length(Batch)), Batch),
    _ = [
        spawn_monitor(fun() -> Parent ! {Ref, I, safe_apply(Fun, Item)} end)
     || {I, Item} <- Indexed
    ],
    Results = collect(Ref, length(Batch), #{}),
    [maps:get(I, Results) || {I, _} <- Indexed].

safe_apply(Fun, Item) ->
    try
        Fun(Item)
    catch
        Class:Reason -> {error, {worker_crash, {Class, Reason}}}
    end.

collect(_Ref, 0, Acc) ->
    Acc;
collect(Ref, Remaining, Acc) ->
    receive
        {Ref, Index, Result} ->
            collect(Ref, Remaining - 1, maps:put(Index, Result, Acc));
        {'DOWN', _MRef, process, _Pid, _Reason} ->
            collect(Ref, Remaining, Acc)
    after ?WORKER_TIMEOUT ->
        error(xet_par_timeout)
    end.
