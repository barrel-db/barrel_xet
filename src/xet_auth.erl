%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Authentication behaviour (spec Appendix A.1, OpenAPI scopes): a
%% bearer token is checked against a required scope. read covers the
%% GET/HEAD surface, write the mutating one, admin the /admin extension
%% endpoints. Scopes are totally ordered: admin covers write covers
%% read.
-module(xet_auth).

-export([verify/3, scope_covers/2]).

-type scope() :: read | write | admin.
-type config() :: {module(), term()}.
-export_type([scope/0, config/0]).

-callback verify(binary() | undefined, scope(), term()) ->
    {ok, term()} | {error, unauthorized | forbidden}.

-spec verify(config(), binary() | undefined, scope()) ->
    {ok, term()} | {error, unauthorized | forbidden}.
verify({Mod, Opts}, Token, Scope) ->
    Mod:verify(Token, Scope, Opts).

%% Does a token holding Held satisfy a route requiring Required?
-spec scope_covers(Held :: scope(), Required :: scope()) -> boolean().
scope_covers(Held, Required) ->
    rank(Held) >= rank(Required).

rank(read) -> 0;
rank(write) -> 1;
rank(admin) -> 2.
