%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Admin endpoints. These are barrel_xet extensions, NOT part of
%% draft-denis-xet-05: they live under /admin, require the admin scope,
%% and are mounted only when the server is started with
%% admin => #{enabled => true}. GET /admin/stats reports store counts;
%% later tasks extend the response with GC and scrub status.
-module(xet_h_admin).

-export([stats/1, delete_file/1]).

stats(Req) ->
    Name = livery_req:config(server, Req),
    #{metadata := Metadata} = xet_server:env(Name),
    livery_resp:json(200, json:encode(#{metadata => xet_metadata:stats(Metadata)})).

%% DELETE /admin/files/{hash}: drop a file record (its unique xorbs
%% become collectable). 204 on delete, 404 if the file is not present.
%% There is no file delete in the spec; this is an extension.
delete_file(Req) ->
    Name = livery_req:config(server, Req),
    #{metadata := Metadata} = xet_server:env(Name),
    HashStr = livery_req:binding(<<"hash">>, Req),
    case xet_hash:is_hash_string(HashStr) of
        false ->
            xet_routes:error_response(400, <<"bad_hash">>);
        true ->
            Hash = xet_hash:from_string(HashStr),
            case xet_metadata:file_exists(Metadata, Hash) of
                false ->
                    livery_resp:empty(404);
                true ->
                    ok = xet_metadata:delete_file(Metadata, Hash),
                    livery_resp:empty(204)
            end
    end.
