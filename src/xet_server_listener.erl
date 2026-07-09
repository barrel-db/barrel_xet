%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Owns the livery service (H1 on TCP, H2 on TLS, H3 on QUIC, any
%% subset) for one server instance and publishes the bound ports. All
%% protocols share the same router and middleware stack; when H3 is
%% enabled the service advertises it via Alt-Svc. Started after the
%% stores under rest_for_one, so a storage restart also refreshes the
%% listeners.
-module(xet_server_listener).

-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, terminate/2]).

-record(state, {
    name :: atom(),
    service :: pid(),
    drain_timeout :: pos_integer()
}).
-type state() :: #state{}.

start_link(Config) ->
    gen_server:start_link(?MODULE, Config, []).

-spec init(map()) -> {ok, state()} | {stop, term()}.
init(#{name := Name} = Config) ->
    process_flag(trap_exit, true),
    Opts = service_opts(Config),
    case livery:start_service(Opts) of
        {ok, Service} ->
            Ports = livery_service:which_listeners(Service),
            persistent_term:put({xet_server_ports, Name}, Ports),
            {ok, #state{
                name = Name,
                service = Service,
                drain_timeout = maps:get(drain_timeout, Config)
            }};
        {error, Reason} ->
            {stop, Reason}
    end.

service_opts(Config) ->
    Base = #{
        router => xet_routes:compile(Config),
        middleware => xet_routes:stack(Config),
        %% Handlers resolve their instance environment through this.
        config => #{server => maps:get(name, Config)}
    },
    MaxBody = maps:get(max_body, Config),
    WithListeners = lists:foldl(
        fun(Proto, Acc) ->
            case maps:find(Proto, Config) of
                {ok, ListenOpts} when is_map(ListenOpts) ->
                    Acc#{Proto => maps:merge(#{max_body => MaxBody}, ListenOpts)};
                %% http => false disables the default cleartext listener.
                _ ->
                    Acc
            end
        end,
        Base,
        [http, https, http3]
    ),
    with_alt_svc(with_host(WithListeners, Config)).

with_host(Opts, #{host := Host}) -> Opts#{host => Host};
with_host(Opts, _Config) -> Opts.

with_alt_svc(#{http3 := _} = Opts) -> Opts#{alt_svc => advertise};
with_alt_svc(Opts) -> Opts.

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Graceful shutdown: stop accepting new connections, let in-flight
%% requests finish (up to drain_timeout), then stop. Covers bin stop,
%% systemd/docker stop, and xet_server:stop/1 alike, since all reach the
%% supervisor's terminate. Note livery's in-flight counter is node-wide,
%% so in an embedded multi-instance node this waits on other instances'
%% requests too (bounded by drain_timeout); the release runs one service
%% per node.
terminate(_Reason, #state{name = Name, service = Service, drain_timeout = Timeout}) ->
    _ = persistent_term:erase({xet_server_ports, Name}),
    _ = livery:drain(Service, #{timeout => Timeout}),
    ok.
