%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Fragmentation-prevention estimator, ported from xet-core's
%% DefragPrevention: a rolling window over the chunk counts of the last N
%% reconstruction ranges. Dedup gets skipped while the mean chunks/range
%% is below the threshold (with hysteresis), unless the candidate run is
%% big enough to improve the estimate.
-module(xet_defrag).

-export([new/0, new/3, add_range/2, increment_last/2, allow/2]).

-record(defrag, {
    window :: pos_integer(),
    ranges = queue:new() :: queue:queue(pos_integer()),
    len = 0 :: non_neg_integer(),
    sum = 0 :: non_neg_integer(),
    low = true :: boolean(),
    min :: float(),
    hysteresis :: float()
}).

-opaque state() :: #defrag{}.
-export_type([state/0]).

-define(DEFAULT_WINDOW, 128).
-define(DEFAULT_MIN_CHUNKS_PER_RANGE, 8.0).
-define(DEFAULT_HYSTERESIS, 0.5).

-spec new() -> state().
new() ->
    new(?DEFAULT_WINDOW, ?DEFAULT_MIN_CHUNKS_PER_RANGE, ?DEFAULT_HYSTERESIS).

-spec new(pos_integer(), float(), float()) -> state().
new(Window, MinChunksPerRange, Hysteresis) ->
    #defrag{window = Window, min = MinChunksPerRange, hysteresis = Hysteresis}.

%% A new range entered the file reconstruction.
-spec add_range(state(), non_neg_integer()) -> state().
add_range(#defrag{ranges = Q0, len = Len, sum = Sum, window = W} = S, N) ->
    Q1 = queue:in(N, Q0),
    case Len + 1 > W of
        true ->
            {{value, Old}, Q2} = queue:out(Q1),
            S#defrag{ranges = Q2, sum = Sum + N - Old};
        false ->
            S#defrag{ranges = Q1, len = Len + 1, sum = Sum + N}
    end.

%% The current (last) range grew by N chunks. No-op before any range.
-spec increment_last(state(), non_neg_integer()) -> state().
increment_last(#defrag{len = 0} = S, _N) ->
    S;
increment_last(#defrag{ranges = Q0, sum = Sum} = S, N) ->
    {{value, Last}, Q1} = queue:out_r(Q0),
    S#defrag{ranges = queue:in(Last + N, Q1), sum = Sum + N}.

%% Should a non-continuing dedup run of RangeSize chunks be accepted?
-spec allow(state(), pos_integer()) -> {boolean(), state()}.
allow(#defrag{len = Len, window = W} = S, _RangeSize) when Len < W ->
    {true, S};
allow(#defrag{sum = Sum, len = Len, low = Low, min = Min, hysteresis = Hyst} = S, RangeSize) ->
    Cpr = Sum / Len,
    Target =
        case Low of
            true -> Min * Hyst;
            false -> Min
        end,
    case Cpr < Target of
        true when RangeSize < Cpr ->
            {false, S#defrag{low = false}};
        true ->
            {true, S};
        false ->
            {true, S#defrag{low = true}}
    end.
