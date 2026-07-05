%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Static bearer tokens: #{tokens => #{TokenBinary => read | write |
%% admin}}. admin implies write implies read. Comparison is
%% constant-time over token digests.
-module(xet_auth_static).

-behaviour(xet_auth).

-export([verify/3]).

verify(undefined, _Scope, _Opts) ->
    {error, unauthorized};
verify(Token, Scope, #{tokens := Tokens}) ->
    Digest = crypto:hash(sha256, Token),
    case find_token(maps:to_list(Tokens), Digest) of
        {ok, TokenScope} -> check_scope(TokenScope, Scope);
        error -> {error, unauthorized}
    end.

find_token([], _Digest) ->
    error;
find_token([{Token, Scope} | Rest], Digest) ->
    case crypto:hash_equals(crypto:hash(sha256, Token), Digest) of
        true -> {ok, Scope};
        false -> find_token(Rest, Digest)
    end.

check_scope(Held, Required) ->
    case xet_auth:scope_covers(Held, Required) of
        true -> {ok, Held};
        false -> {error, forbidden}
    end.
