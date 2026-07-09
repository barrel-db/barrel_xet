%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Standalone CAS server instances. start/1 runs an instance under the
%% barrel_xet application supervisor so it outlives the caller; each
%% instance is a rest_for_one tree: storage handles first
%% (xet_server_stores), then the HTTP listener.
-module(xet_server).

-export([start/1, start_instance/1, stop/1, port/1, ports/1, env/1]).
-export([start_link/1]).
-export([init/1]).

-behaviour(supervisor).

%% Public entry: ensure the app is running, then start an instance.
-spec start(map()) -> {ok, pid()} | {error, term()}.
start(Config0) ->
    {ok, _} = application:ensure_all_started([barrel_xet]),
    start_instance(Config0).

%% Add a server instance under the (already running) app supervisor. Also
%% used by barrel_xet_app to autostart a configured server on boot, where
%% ensuring the app would deadlock. A config that fails validation is
%% reported as {error, {invalid_config, [Reason]}} instead of a crash.
-spec start_instance(map()) -> {ok, pid()} | {error, term()}.
start_instance(Config0) ->
    case xet_config:load(Config0) of
        {ok, Config} ->
            maybe_start_instrument(Config),
            Name = maps:get(name, Config),
            Spec = #{
                id => Name,
                start => {?MODULE, start_link, [Config]},
                restart => transient,
                type => supervisor
            },
            supervisor:start_child(barrel_xet_sup, Spec);
        {error, _Reason} = Error ->
            Error
    end.

-spec stop(atom()) -> ok | {error, term()}.
stop(Name) ->
    case supervisor:terminate_child(barrel_xet_sup, Name) of
        ok -> supervisor:delete_child(barrel_xet_sup, Name);
        {error, _} = Error -> Error
    end.

%% Bound port of the HTTP/1 listener (the interop baseline).
-spec port(atom()) -> pos_integer().
port(Name) ->
    maps:get(h1, ports(Name)).

%% All bound ports by protocol: #{h1 | h2 | h3 => Port}.
-spec ports(atom()) -> #{h1 | h2 | h3 => pos_integer()}.
ports(Name) ->
    persistent_term:get({xet_server_ports, Name}).

-spec env(atom()) -> map().
env(Name) ->
    persistent_term:get({xet_server_env, Name}).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Config) ->
    supervisor:start_link(?MODULE, Config).

init(Config) ->
    SupFlags = #{strategy => rest_for_one, intensity => 5, period => 30},
    {ok, {SupFlags, children(Config)}}.

children(Config) ->
    %% The listener drains in-flight requests on terminate, so give it a
    %% shutdown budget past the drain window.
    ListenerShutdown = maps:get(drain_timeout, Config) + 5000,
    [
        #{
            id => stores,
            start => {xet_server_stores, start_link, [Config]},
            shutdown => 10000
        },
        #{
            id => keys,
            start => {xet_keys, start_link, [Config]},
            shutdown => 5000
        },
        #{
            id => listener,
            start => {xet_server_listener, start_link, [Config]},
            shutdown => ListenerShutdown
        },
        %% After the listener: a GC or scrub crash must not bounce request
        %% serving.
        #{
            id => gc,
            start => {xet_gc, start_link, [Config]},
            shutdown => 5000
        },
        #{
            id => scrub,
            start => {xet_scrub, start_link, [Config]},
            shutdown => 5000
        }
    ].

%% Observability needs the instrument registry running; start it on
%% demand so metrics/trace middleware have somewhere to record.
maybe_start_instrument(#{observability := true}) ->
    {ok, _} = application:ensure_all_started(instrument),
    %% Enrich log events emitted inside a request span with trace_id and
    %% span_id, so the access log correlates with traces. Idempotent.
    _ = livery_instrument_trace:install_logger(),
    ok;
maybe_start_instrument(_Config) ->
    ok.
