%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Global dedup endpoint (spec A.4): GET /v1/chunks/{ns}/{chunk_hash}.
%% A hit returns a stored-form shard whose CAS chunk hashes are keyed
%% with the current chunk_hash_key; a miss is 404. Responses are
%% per-user cacheable for an hour (spec 13.6.1).
-module(xet_h_chunks).

-export([get/1]).

get(Req) ->
    Name = livery_req:config(server, Req),
    Env = xet_server:env(Name),
    maybe
        {ok, _Ns, Hash} ?= target(Req, Env),
        {ok, XorbHash, _Index} ?= find(Env, Hash),
        {ok, Xorb} ?= load_xorb(Env, XorbHash),
        respond(Name, XorbHash, Xorb)
    else
        {error, Resp} -> Resp
    end.

target(Req, #{config := Config}) ->
    Ns = livery_req:binding(<<"ns">>, Req),
    HashStr = livery_req:binding(<<"hash">>, Req),
    Allowed = lists:member(Ns, maps:get(namespaces, Config)),
    case {Allowed, xet_hash:is_hash_string(HashStr)} of
        {true, true} -> {ok, Ns, xet_hash:from_string(HashStr)};
        _ -> {error, xet_routes:error_response(400, <<"bad_target">>)}
    end.

find(#{metadata := Metadata}, Hash) ->
    xet_metrics:count(<<"xet.chunks.queries">>, 1),
    case xet_metadata:find_chunk(Metadata, Hash) of
        {ok, {XorbHash, Index}} ->
            xet_metrics:count(<<"xet.chunks.hits">>, 1),
            {ok, XorbHash, Index};
        not_found ->
            {error, xet_routes:error_response(404, <<"not_found">>)}
    end.

load_xorb(#{metadata := Metadata}, XorbHash) ->
    case xet_metadata:get_xorb(Metadata, XorbHash) of
        {ok, Xorb} ->
            {ok, Xorb};
        not_found ->
            logger:error(
                "chunk index references missing xorb ~ts",
                [xet_hash:to_string(XorbHash)]
            ),
            {error, xet_routes:error_response(500, <<"inconsistent_metadata">>)}
    end.

respond(Name, XorbHash, Xorb) ->
    #{key := Key, expires_at := Expiry} = xet_keys:current(Name),
    CasBlock = #{
        cas_hash => XorbHash,
        bytes_on_disk => maps:get(bytes_on_disk, Xorb),
        chunks => [
            #{hash => H, size => S, dedup_eligible => xet_dedup:hash_eligible(H)}
         || {H, S} <- maps:get(entries, Xorb)
        ]
    },
    Shard = xet_dedup:build_response([CasBlock], #{
        chunk_hash_key => Key,
        created_at => erlang:system_time(second),
        key_expiry => Expiry
    }),
    livery_resp:new(
        200,
        [
            {<<"content-type">>, <<"application/octet-stream">>},
            {<<"cache-control">>, <<"private, max-age=3600">>},
            {<<"vary">>, <<"authorization">>}
        ],
        {full, Shard}
    ).
