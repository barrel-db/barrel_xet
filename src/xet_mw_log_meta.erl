%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Puts the client's X-Xet-Session-Id into the request process's logger
%% metadata, so the access log and any handler log lines carry it. The
%% header is attacker-controlled: control bytes are stripped and the
%% value is capped. Stacked before livery_access_log; the value is
%% cleared when the header is absent so it cannot leak to the next
%% request served by a reused process.
-module(xet_mw_log_meta).

-behaviour(livery_middleware).

-export([call/3]).

-define(MAX_LEN, 64).

call(Req, Next, _State) ->
    set_session(session_id(Req)),
    Next(Req).

session_id(Req) ->
    case livery_req:header(<<"x-xet-session-id">>, Req) of
        undefined -> undefined;
        <<>> -> undefined;
        Raw -> sanitize(binary:part(Raw, 0, min(byte_size(Raw), ?MAX_LEN)))
    end.

set_session(undefined) ->
    case logger:get_process_metadata() of
        Md when is_map(Md) -> logger:set_process_metadata(maps:remove(session_id, Md));
        _ -> ok
    end;
set_session(SessionId) ->
    logger:update_process_metadata(#{session_id => SessionId}).

sanitize(Bin) ->
    <<<<(control_to_space(B))>> || <<B>> <= Bin>>.

control_to_space(B) when B < 32; B =:= 127 -> $\s;
control_to_space(B) -> B.
