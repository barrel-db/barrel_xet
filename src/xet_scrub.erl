%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Verify-at-rest: read every stored xorb and confirm it still decodes
%% and hashes to its address. It never deletes anything (a stored blob
%% may be the only copy, and a transient read error must not destroy
%% data); a corrupt or unreadable xorb is logged, counted, and listed in
%% the run summary for an operator to act on. Reads are rate-limited so a
%% scrub does not saturate the disk or an S3 bill.
%%
%% Off by default; triggered from /admin/scrub or a configured interval.
-module(xet_scrub).

-behaviour(gen_server).

-export([start_link/1, trigger/1, status/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(MAX_FINDINGS, 100).

-record(state, {
    name :: atom(),
    rate :: non_neg_integer(),
    interval :: false | pos_integer(),
    run :: undefined | #{pid := pid(), mref := reference()},
    last :: undefined | map()
}).
-type state() :: #state{}.

start_link(Config) ->
    gen_server:start_link(?MODULE, Config, []).

-spec trigger(atom()) -> {ok, started | already_running}.
trigger(Name) ->
    gen_server:call(pid(Name), trigger).

-spec status(atom()) -> map().
status(Name) ->
    gen_server:call(pid(Name), status).

pid(Name) ->
    persistent_term:get({?MODULE, Name}).

-spec init(map()) -> {ok, state()}.
init(#{name := Name} = Config) ->
    process_flag(trap_exit, true),
    Scrub = maps:get(scrub, Config, #{}),
    Interval = maps:get(interval, Scrub, false),
    State = #state{
        name = Name,
        rate = maps:get(rate_bytes_per_sec, Scrub, 33554432),
        interval = Interval,
        run = undefined,
        last = undefined
    },
    persistent_term:put({?MODULE, Name}, self()),
    schedule(Interval),
    {ok, State}.

handle_call(trigger, _From, #state{run = Run} = State) when Run =/= undefined ->
    {reply, {ok, already_running}, State};
handle_call(trigger, _From, State) ->
    {reply, {ok, started}, start_run(State)};
handle_call(status, _From, State) ->
    {reply, status_map(State), State};
handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast({done, Result}, State) ->
    {noreply, State#state{run = undefined, last = Result}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(scrub_tick, #state{interval = Interval, run = undefined} = State) ->
    schedule(Interval),
    {noreply, start_run(State)};
handle_info(scrub_tick, #state{interval = Interval} = State) ->
    schedule(Interval),
    {noreply, State};
handle_info({'DOWN', MRef, process, _Pid, Reason}, #state{run = #{mref := MRef}} = State) when
    Reason =/= normal
->
    logger:error("scrub worker crashed: ~p", [Reason]),
    {noreply, State#state{run = undefined, last = #{error => crashed}}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------

start_run(#state{name = Name, rate = Rate} = State) ->
    Gen = self(),
    {Pid, MRef} = spawn_monitor(fun() ->
        gen_server:cast(Gen, {done, run(Name, Rate)})
    end),
    State#state{run = #{pid => Pid, mref => MRef}}.

schedule(false) -> ok;
schedule(Interval) -> erlang:send_after(Interval * 1000, self(), scrub_tick).

status_map(#state{run = Run, last = Last}) ->
    #{running => Run =/= undefined, last => Last}.

%% Worker.
run(Name, Rate) ->
    #{metadata := Metadata, blob := Blob} = xet_server:env(Name),
    Start = erlang:monotonic_time(millisecond),
    Acc = xet_metadata:fold_xorbs(
        Metadata,
        fun(Xorb, A) -> scrub_one(Xorb, Blob, Rate, Start, A) end,
        #{checked => 0, corrupt => 0, read_errors => 0, bytes => 0, findings => []}
    ),
    Result = maps:without([bytes], Acc#{findings := lists:reverse(maps:get(findings, Acc))}),
    xet_metrics:count(<<"xet.scrub.checked">>, maps:get(checked, Result)),
    xet_metrics:count(<<"xet.scrub.corrupt">>, maps:get(corrupt, Result)),
    xet_metrics:gauge(<<"xet.scrub.last_run">>, erlang:system_time(second)),
    Result.

scrub_one(Xorb, Blob, Rate, Start, Acc) ->
    Hash = maps:get(hash, Xorb),
    Ns = maps:get(ns, Xorb, <<"default">>),
    Size = maps:get(bytes_on_disk, Xorb),
    throttle(maps:get(bytes, Acc), Rate, Start),
    Acc1 = bump(checked, add_bytes(Size, Acc)),
    case xet_blob_store:get_range(Blob, Ns, Hash, 0, Size) of
        {ok, Bin} -> verify(Bin, Hash, Acc1);
        {error, Reason} -> read_error(Hash, Reason, Acc1)
    end.

verify(Bin, Hash, Acc) ->
    case xet_xorb:decode_any(Bin) of
        {ok, #{hash := Hash}} ->
            Acc;
        _Mismatch ->
            logger:error("scrub: xorb ~ts is corrupt", [xet_hash:to_string(Hash)]),
            bump(corrupt, add_finding(Hash, corrupt, Acc))
    end.

read_error(Hash, Reason, Acc) ->
    logger:error("scrub: cannot read xorb ~ts: ~p", [xet_hash:to_string(Hash), Reason]),
    bump(read_errors, add_finding(Hash, read_error, Acc)).

add_bytes(N, #{bytes := B} = Acc) -> Acc#{bytes := B + N}.
bump(Key, Acc) -> maps:update_with(Key, fun(V) -> V + 1 end, Acc).

add_finding(Hash, Kind, #{findings := Findings} = Acc) when length(Findings) < ?MAX_FINDINGS ->
    Acc#{findings := [#{hash => xet_hash:to_string(Hash), kind => Kind} | Findings]};
add_finding(_Hash, _Kind, Acc) ->
    Acc.

%% Sleep so the cumulative read rate stays under Rate bytes/sec.
throttle(_Bytes, 0, _Start) ->
    ok;
throttle(Bytes, Rate, Start) ->
    Elapsed = erlang:monotonic_time(millisecond) - Start,
    TargetMs = Bytes * 1000 div Rate,
    case TargetMs > Elapsed of
        true -> timer:sleep(TargetMs - Elapsed);
        false -> ok
    end.
