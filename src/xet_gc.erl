%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Garbage collection of unreferenced xorbs. A run marks every xorb a
%% file references, then sweeps xorbs that are unmarked and older than the
%% grace window. Each sweep batch runs inside the GC guard's exclusive
%% section and skips anything a concurrent registration referenced since
%% the mark started, so a live upload never loses a xorb. Metadata is
%% deleted under the lock; blobs after it.
%%
%% Runs are single-flight and executed in a worker process so status
%% stays answerable. Manual by default; a configured interval schedules
%% periodic runs.
-module(xet_gc).

-behaviour(gen_server).

-export([start_link/1, trigger/2, status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(BATCH, 100).
-define(EXCLUSIVE_TIMEOUT, 5000).

-record(state, {
    name :: atom(),
    grace :: pos_integer(),
    interval :: false | pos_integer(),
    run :: undefined | #{pid := pid(), mref := reference(), dry_run := boolean()},
    last :: undefined | map()
}).
-type state() :: #state{}.

start_link(Config) ->
    gen_server:start_link(?MODULE, Config, []).

%% Start a run (single-flight). Opts: #{dry_run => boolean()}.
-spec trigger(atom(), map()) -> {ok, started | already_running}.
trigger(Name, Opts) ->
    gen_server:call(pid(Name), {trigger, Opts}).

-spec status(atom()) -> map().
status(Name) ->
    gen_server:call(pid(Name), status).

pid(Name) ->
    persistent_term:get({?MODULE, Name}).

-spec init(map()) -> {ok, state()}.
init(#{name := Name} = Config) ->
    process_flag(trap_exit, true),
    Gc = maps:get(gc, Config, #{}),
    Interval = maps:get(interval, Gc, false),
    State = #state{
        name = Name,
        grace = maps:get(grace_seconds, Gc, 86400),
        interval = Interval,
        run = undefined,
        last = undefined
    },
    persistent_term:put({?MODULE, Name}, self()),
    schedule(Interval),
    {ok, State}.

handle_call({trigger, _Opts}, _From, #state{run = Run} = State) when Run =/= undefined ->
    {reply, {ok, already_running}, State};
handle_call({trigger, Opts}, _From, State) ->
    {reply, {ok, started}, start_run(Opts, State)};
handle_call(status, _From, State) ->
    {reply, status_map(State), State};
handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast({done, Result}, State) ->
    {noreply, State#state{run = undefined, last = Result}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(gc_tick, #state{interval = Interval, run = undefined} = State) ->
    schedule(Interval),
    {noreply, start_run(#{}, State)};
handle_info(gc_tick, #state{interval = Interval} = State) ->
    schedule(Interval),
    {noreply, State};
handle_info({'DOWN', MRef, process, _Pid, Reason}, #state{run = #{mref := MRef}} = State) when
    Reason =/= normal
->
    logger:error("gc worker crashed: ~p", [Reason]),
    {noreply, State#state{run = undefined, last = #{error => crashed}}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------

start_run(Opts, #state{name = Name, grace = Grace} = State) ->
    DryRun = maps:get(dry_run, Opts, false),
    Gen = self(),
    {Pid, MRef} = spawn_monitor(fun() ->
        Result = run(Name, Grace, DryRun),
        gen_server:cast(Gen, {done, Result})
    end),
    State#state{run = #{pid => Pid, mref => MRef, dry_run => DryRun}}.

schedule(false) -> ok;
schedule(Interval) -> erlang:send_after(Interval * 1000, self(), gc_tick).

status_map(#state{run = Run, last = Last}) ->
    #{running => Run =/= undefined, last => Last}.

%% Worker (runs in the spawned process).
run(Name, Grace, DryRun) ->
    #{metadata := Metadata, blob := Blob, config := Config} = xet_server:env(Name),
    MarkStart = erlang:monotonic_time(),
    Cutoff = erlang:system_time(second) - Grace,
    Marked = mark(Metadata),
    Candidates = collect_candidates(Metadata, Marked, Cutoff),
    {Deleted, Bytes} = sweep(Candidates, Metadata, Blob, MarkStart, DryRun),
    Namespaces = maps:get(namespaces, Config),
    {Orphans, OrphanBytes} = orphan_sweep(Blob, Namespaces, Metadata, Cutoff, DryRun),
    xet_gc_guard:prune(MarkStart),
    record_metrics(Deleted, Bytes),
    record_orphan_metrics(Orphans, OrphanBytes, DryRun),
    #{
        dry_run => DryRun,
        candidates => length(Candidates),
        deleted_xorbs => Deleted,
        deleted_bytes => Bytes,
        orphan_blobs => Orphans,
        orphan_bytes => OrphanBytes
    }.

mark(Metadata) ->
    xet_metadata:fold_files(
        Metadata,
        fun(File, Acc) ->
            lists:foldl(
                fun(Term, A) -> sets:add_element(maps:get(cas_hash, Term), A) end,
                Acc,
                maps:get(terms, File)
            )
        end,
        sets:new([{version, 2}])
    ).

collect_candidates(Metadata, Marked, Cutoff) ->
    xet_metadata:fold_xorbs(
        Metadata,
        fun(Xorb, Acc) ->
            Hash = maps:get(hash, Xorb),
            Old = maps:get(created_at, Xorb, 0) < Cutoff,
            case Old andalso not sets:is_element(Hash, Marked) of
                true -> [Hash | Acc];
                false -> Acc
            end
        end,
        []
    ).

sweep(Candidates, Metadata, Blob, MarkStart, DryRun) ->
    lists:foldl(
        fun(Batch, {DelAcc, BytesAcc}) ->
            {D, B} = sweep_batch(Batch, Metadata, Blob, MarkStart, DryRun),
            {DelAcc + D, BytesAcc + B}
        end,
        {0, 0},
        batches(Candidates, ?BATCH)
    ).

sweep_batch(Batch, Metadata, Blob, MarkStart, DryRun) ->
    Delete = fun() -> delete_metadata(Batch, Metadata, MarkStart, DryRun) end,
    case xet_gc_guard:with_exclusive(?EXCLUSIVE_TIMEOUT, Delete) of
        {ok, Deleted} ->
            delete_blobs(Deleted, Blob, DryRun),
            {length(Deleted), lists:sum([B || {_, _, B} <- Deleted])};
        {error, busy} ->
            logger:warning("gc sweep batch skipped: registrations did not drain"),
            {0, 0}
    end.

%% Under the exclusive lock: skip anything referenced since the mark,
%% delete the rest from metadata, and return them for the blob deletes.
delete_metadata(Batch, Metadata, MarkStart, DryRun) ->
    lists:foldl(
        fun(Hash, Acc) ->
            case xet_gc_guard:referenced_since(Hash, MarkStart) of
                true -> Acc;
                false -> delete_one(Hash, Metadata, DryRun, Acc)
            end
        end,
        [],
        Batch
    ).

delete_one(Hash, Metadata, DryRun, Acc) ->
    case xet_metadata:get_xorb(Metadata, Hash) of
        {ok, Xorb} ->
            DryRun orelse (ok = xet_metadata:delete_xorb(Metadata, Hash)),
            [{Hash, maps:get(ns, Xorb, <<"default">>), maps:get(bytes_on_disk, Xorb, 0)} | Acc];
        not_found ->
            Acc
    end.

delete_blobs(_Deleted, _Blob, true) ->
    ok;
delete_blobs(Deleted, Blob, false) ->
    lists:foreach(fun({Hash, Ns, _}) -> _ = xet_blob_store:delete(Blob, Ns, Hash) end, Deleted).

batches([], _N) ->
    [];
batches(List, N) when length(List) =< N -> [List];
batches(List, N) ->
    {Head, Tail} = lists:split(N, List),
    [Head | batches(Tail, N)].

%% Reclaim blobs with no metadata that are older than the grace window (a
%% put that crashed before register, or a GC crash after the metadata
%% delete), on any backend that can list its blobs (filesystem, S3). Aged
%% blobs are collected without the lock; the metadata check and delete
%% run in bounded exclusive batches, so a concurrent xorb commit (also
%% guarded) cannot lose its just-written blob. A listing error skips the
%% sweep for this run.
orphan_sweep(Blob, Namespaces, Metadata, Cutoff, DryRun) ->
    Aged = fun
        ({Ns, Hash, Mtime}, Acc) when Mtime < Cutoff -> [{Ns, Hash} | Acc];
        (_Entry, Acc) -> Acc
    end,
    case xet_blob_store:fold_blobs(Blob, Namespaces, Aged, []) of
        {ok, Candidates} ->
            sweep_orphans(batches(Candidates, ?BATCH), Blob, Metadata, DryRun, {0, 0});
        {error, not_supported} ->
            {0, 0};
        {error, Reason} ->
            logger:warning("gc orphan sweep skipped: blob listing failed: ~p", [Reason]),
            {0, 0}
    end.

sweep_orphans([], _Blob, _Metadata, _DryRun, Acc) ->
    Acc;
sweep_orphans([Batch | Rest], Blob, Metadata, DryRun, {N, Bytes}) ->
    Delete = fun() -> delete_orphan_batch(Batch, Blob, Metadata, DryRun) end,
    {D, B} =
        case xet_gc_guard:with_exclusive(?EXCLUSIVE_TIMEOUT, Delete) of
            {ok, R} -> R;
            {error, busy} -> {0, 0}
        end,
    sweep_orphans(Rest, Blob, Metadata, DryRun, {N + D, Bytes + B}).

delete_orphan_batch(Batch, Blob, Metadata, DryRun) ->
    lists:foldl(
        fun({Ns, Hash}, {N, Bytes}) ->
            case xet_metadata:xorb_exists(Metadata, Hash) of
                true ->
                    {N, Bytes};
                false ->
                    Size = orphan_size(Blob, Ns, Hash),
                    DryRun orelse (_ = xet_blob_store:delete(Blob, Ns, Hash)),
                    {N + 1, Bytes + Size}
            end
        end,
        {0, 0},
        Batch
    ).

orphan_size(Blob, Ns, Hash) ->
    case xet_blob_store:size(Blob, Ns, Hash) of
        {ok, Size} -> Size;
        _ -> 0
    end.

record_orphan_metrics(_Orphans, _Bytes, true) ->
    ok;
record_orphan_metrics(Orphans, Bytes, false) ->
    xet_metrics:count(<<"xet.gc.orphan_blobs">>, Orphans),
    xet_metrics:count(<<"xet.gc.orphan_bytes">>, Bytes).

record_metrics(Deleted, Bytes) ->
    xet_metrics:count(<<"xet.gc.runs">>, 1),
    xet_metrics:count(<<"xet.gc.deleted_xorbs">>, Deleted),
    xet_metrics:count(<<"xet.gc.deleted_bytes">>, Bytes),
    xet_metrics:gauge(<<"xet.gc.last_run">>, erlang:system_time(second)).
