%% barrel_xet application callback.
%%
%% barrel_xet is a library application: starting it only brings up an
%% empty supervisor. The CAS server is started explicitly with
%% xet_server:start/1.
-module(barrel_xet_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    barrel_xet_sup:start_link().

stop(_State) ->
    ok.
