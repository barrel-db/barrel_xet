%% Retry wrapper implementing the xet-core taxonomy. livery_client_retry
%% is not enough (it retries 502/503/504 only and never replays streaming
%% bodies), so the client wraps calls here with replayable bodies.
%%
%% Transient (retried with exponential backoff + jitter): 5xx, 408, 429,
%% and connection-level errors. Fatal (returned as-is): other 4xx and
%% non-transient errors. Per-call overrides tune the transient set, e.g.
%% dedup queries make 429 fatal.
-module(xet_client_retry).

-export([run/2, defaults/0]).

-define(DEFAULTS, #{
    max_attempts => 5,
    base_delay => 3000,
    max_delay => 60000,
    transient_statuses => [408, 429, 500, 502, 503, 504],
    no_retry_statuses => []
}).

-type result() :: {ok, map()} | {error, term()}.
-export_type([result/0]).

-spec defaults() -> map().
defaults() ->
    ?DEFAULTS.

-spec run(fun(() -> result()), map()) -> result().
run(Fun, Opts0) ->
    Opts = maps:merge(?DEFAULTS, Opts0),
    attempt(Fun, Opts, 1).

attempt(Fun, Opts, N) ->
    Result = Fun(),
    case should_retry(Result, Opts) andalso N < maps:get(max_attempts, Opts) of
        true ->
            timer:sleep(backoff(N, Opts)),
            attempt(Fun, Opts, N + 1);
        false ->
            Result
    end.

should_retry({ok, #{status := Status}}, Opts) ->
    lists:member(Status, maps:get(transient_statuses, Opts)) andalso
        not lists:member(Status, maps:get(no_retry_statuses, Opts));
should_retry({error, Reason}, _Opts) ->
    transient_error(Reason);
should_retry(_, _) ->
    false.

transient_error(timeout) -> true;
transient_error(closed) -> true;
transient_error(connect_timeout) -> true;
transient_error(econnrefused) -> true;
transient_error(enetunreach) -> true;
transient_error({closed, _}) -> true;
%% Transport-level failures from a stale pooled connection (a real HTTP
%% 400 comes back as {ok, #{status => 400}}, not this): retry on a fresh
%% connection.
transient_error(bad_request) -> true;
transient_error(checkout_timeout) -> true;
transient_error(checkout_failure) -> true;
transient_error(_) -> false.

backoff(N, Opts) ->
    Base = maps:get(base_delay, Opts),
    Max = maps:get(max_delay, Opts),
    Capped = min(Base * (1 bsl (N - 1)), Max),
    Half = max(1, Capped div 2),
    Half + rand:uniform(Half).
