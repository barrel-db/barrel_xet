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
    {ok, Sup} = barrel_xet_sup:start_link(),
    ok = autostart_server(),
    {ok, Sup}.

stop(_State) ->
    ok.

autostart_server() ->
    case application:get_env(barrel_xet, server) of
        {ok, ServerConfig} when is_map(ServerConfig) ->
            {ok, _} = xet_server:start_instance(ServerConfig),
            ok;
        _ ->
            ok
    end.
