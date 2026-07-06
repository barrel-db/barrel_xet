%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Admin endpoints. These are barrel_xet extensions, NOT part of
%% draft-denis-xet-05: they live under /admin, require the admin scope,
%% and are mounted only when the server is started with
%% admin => #{enabled => true}. GET /admin/stats reports store counts;
%% later tasks extend the response with GC and scrub status.
-module(xet_h_admin).

-export([stats/1]).

stats(Req) ->
    Name = livery_req:config(server, Req),
    #{metadata := Metadata} = xet_server:env(Name),
    livery_resp:json(200, json:encode(#{metadata => xet_metadata:stats(Metadata)})).
