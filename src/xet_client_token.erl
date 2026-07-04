%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Bearer token provider. A static token is returned as-is; a refresh
%% provider caches the token and refreshes it when within 30 s of expiry
%% (the xet-core REFRESH_BUFFER_SEC), honoring the refresh-route contract
%% #{access_token, exp} (Unix seconds).
-module(xet_client_token).

-export([new/1, get/1]).

-define(REFRESH_BUFFER, 30).

-type refresh_fun() :: fun(
    () -> {ok, #{access_token := binary(), exp := integer()}} | {error, term()}
).
-opaque provider() ::
    {static, binary()}
    | {refresh, refresh_fun(), ets:tid()}.
-export_type([provider/0, refresh_fun/0]).

-spec new(binary() | {refresh, refresh_fun()}) -> provider().
new(Token) when is_binary(Token) ->
    {static, Token};
new({refresh, Fun}) when is_function(Fun, 0) ->
    {refresh, Fun, ets:new(xet_client_token, [public, set])}.

-spec get(provider()) -> {ok, binary()} | {error, term()}.
get({static, Token}) ->
    {ok, Token};
get({refresh, Fun, Tab}) ->
    Now = erlang:system_time(second),
    case ets:lookup(Tab, token) of
        [{token, Token, Exp}] when Exp - ?REFRESH_BUFFER > Now ->
            {ok, Token};
        _ ->
            refresh(Fun, Tab, Now)
    end.

refresh(Fun, Tab, Now) ->
    case Fun() of
        {ok, #{access_token := Token, exp := Exp}} ->
            ets:insert(Tab, {token, Token, Exp}),
            {ok, Token};
        {ok, #{access_token := Token}} ->
            ets:insert(Tab, {token, Token, Now + ?REFRESH_BUFFER}),
            {ok, Token};
        {error, _} = Error ->
            Error
    end.
