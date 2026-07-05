%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% barrel_xet application callback.
%%
%% barrel_xet is a library application: starting it brings up an empty
%% supervisor. A CAS server is started explicitly with xet_server:start/1,
%% or, in a release, autostarted from the `server` application env (set in
%% sys.config) so the standalone node serves on boot.
-module(barrel_xet_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    case barrel_xet_sup:start_link() of
        {ok, Sup} ->
            case autostart_server() of
                ok -> {ok, Sup};
                {error, _Reason} = Error -> Error
            end;
        {error, _Reason} = Error ->
            Error
    end.

stop(_State) ->
    ok.

autostart_server() ->
    case application:get_env(barrel_xet, server) of
        {ok, ServerConfig} when is_map(ServerConfig) ->
            start_configured(ServerConfig);
        _ ->
            ok
    end.

%% A release with a bad `server` env must fail its boot loudly: one log
%% line per problem, then the application start stops.
start_configured(ServerConfig) ->
    case xet_server:start_instance(ServerConfig) of
        {ok, _Pid} ->
            ok;
        {error, {invalid_config, Errors}} = Error ->
            lists:foreach(
                fun(Reason) -> logger:error("barrel_xet server config: ~ts", [Reason]) end,
                Errors
            ),
            Error;
        {error, _Reason} = Error ->
            Error
    end.
