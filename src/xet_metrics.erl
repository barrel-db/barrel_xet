%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Domain metrics for the CAS server, recorded into the instrument
%% registry that /metrics exposes. Every operation is best-effort: if
%% the registry is unavailable (observability off, or restarting), the
%% call degrades to a no-op instead of failing the request, exactly like
%% livery's HTTP metrics middleware. create_* is idempotent
%% (persistent_term-backed by name), so these are a couple of registry
%% reads on the hot path.
%%
%% Attribute maps are kept tiny on purpose: no per-namespace or per-hash
%% labels, which would blow up cardinality.
-module(xet_metrics).

-export([count/2, count/3, observe/3, gauge/2]).

-define(METER, <<"barrel_xet">>).

-spec count(binary(), number()) -> ok.
count(Name, N) ->
    count(Name, N, #{}).

-spec count(binary(), number(), map()) -> ok.
count(Name, N, Attrs) ->
    track(fun(Meter) ->
        Counter = instrument_meter:create_counter(Meter, Name),
        instrument_meter:add(Counter, N, Attrs)
    end).

-spec observe(binary(), number(), map()) -> ok.
observe(Name, Value, Attrs) ->
    track(fun(Meter) ->
        Hist = instrument_meter:create_histogram(Meter, Name),
        instrument_meter:record(Hist, Value, Attrs)
    end).

-spec gauge(binary(), number()) -> ok.
gauge(Name, Value) ->
    track(fun(Meter) ->
        G = instrument_meter:create_gauge(Meter, Name),
        instrument_meter:set(G, Value, #{})
    end).

track(Fun) ->
    try
        _ = Fun(instrument_meter:get_meter(?METER)),
        ok
    catch
        _Class:_Reason -> ok
    end.
