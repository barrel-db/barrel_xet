%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Frames every empty response with `content-length: 0`.
%%
%% livery 0.11's HTTP/1.1 adapter sends an empty body as
%% `transfer-encoding: chunked` plus a `0\r\n\r\n` terminator, also for
%% HEAD, 204 and 304, which carry no body (RFC 9110 9.3.2, 15.3.5, 15.4.5).
%% A client that correctly reads no body leaves those five bytes on the
%% connection, and the next response on it fails to parse (a pooled
%% client sees the following request fail). An explicit length makes the
%% adapter write no body at all. Remove once livery frames empty bodies
%% itself.
-module(xet_mw_empty_body).

-behaviour(livery_middleware).

-export([call/3]).

call(Req, Next, _State) ->
    frame(Next(Req)).

frame(Resp) ->
    try
        case needs_length(Resp) of
            true -> livery_resp:with_header(<<"content-length">>, <<"0">>, Resp);
            false -> Resp
        end
    catch
        %% Not a livery_resp (a handler that took the stream over).
        error:_ -> Resp
    end.

needs_length(Resp) ->
    livery_resp:status(Resp) >= 200 andalso
        empty_body(livery_resp:body(Resp)) andalso
        livery_resp:trailers(Resp) =:= undefined andalso
        not lists:keymember(<<"content-length">>, 1, livery_resp:headers(Resp)).

empty_body(empty) -> true;
empty_body({full, IoData}) -> iolist_size(IoData) =:= 0;
empty_body(_) -> false.
