%% Standalone CAS server instances. start/1 runs an instance under the
%% barrel_xet application supervisor so it outlives the caller; each
%% instance is a rest_for_one tree: storage handles first
%% (xet_server_stores), then the HTTP listener.
-module(xet_server).

-export([start/1, stop/1, port/1, ports/1, env/1]).
-export([start_link/1]).
-export([init/1]).

-behaviour(supervisor).

-define(DEFAULT_MAX_BODY, 83886080).

-spec start(map()) -> {ok, pid()} | {error, term()}.
start(Config0) ->
    {ok, _} = application:ensure_all_started([barrel_xet]),
    Config = normalize(Config0),
    Name = maps:get(name, Config),
    Spec = #{
        id => Name,
        start => {?MODULE, start_link, [Config]},
        restart => transient,
        type => supervisor
    },
    supervisor:start_child(barrel_xet_sup, Spec).

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
    Children = [
        #{
            id => stores,
            start => {xet_server_stores, start_link, [Config]},
            shutdown => 10000
        },
        #{
            id => listener,
            start => {xet_server_listener, start_link, [Config]},
            shutdown => 10000
        }
    ],
    {ok, {SupFlags, Children}}.

normalize(Config) ->
    DataDir = maps:get(data_dir, Config),
    Defaults = #{
        name => xet_server,
        http => #{port => 0},
        blob => {fs, #{dir => filename:join(DataDir, "xorbs")}},
        namespaces => [<<"default">>, <<"default-merkledb">>],
        max_body => ?DEFAULT_MAX_BODY,
        %% Serialized xorb cap: 64 MiB of chunk payload plus headers and
        %% footer headroom.
        max_xorb_bytes => 71303168,
        spool_memory_max => 16777216,
        ratelimit => false,
        concurrency => false
    },
    maps:merge(Defaults, Config).
