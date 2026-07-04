%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Xorb endpoints (spec Appendix A.5):
%%   POST /v1/xorbs/{ns}/{hash}: spool the body (memory below a
%%   threshold, disk above), validate the WHOLE xorb (footered or bare
%%   chunk stream, recomputed hashes, path hash equality) and only then
%%   commit: blob put first, metadata second. Failed validation deletes
%%   the spool and nothing reaches the blob store.
%%   HEAD /v1/xorbs/{ns}/{hash}: existence check against metadata.
-module(xet_h_xorbs).

-export([upload/1, head/1]).

upload(Req) ->
    Env = xet_server:env(livery_req:config(server, Req)),
    case request_target(Req, Env) of
        {ok, Ns, Hash} -> upload_checked(Req, Env, Ns, Hash);
        {error, Resp} -> Resp
    end.

upload_checked(Req, Env, Ns, Hash) ->
    #{metadata := Metadata, config := Config} = Env,
    case xet_metadata:xorb_exists(Metadata, Hash) of
        true ->
            reply_inserted(false);
        false ->
            SpoolOpts = #{
                cap => maps:get(max_xorb_bytes, Config),
                memory_max => maps:get(spool_memory_max, Config),
                spool_dir => filename:join(maps:get(data_dir, Config), "spool")
            },
            case xet_http_body:read_spooled(Req, SpoolOpts) of
                {ok, Spooled} -> validate_and_commit(Env, Ns, Hash, Spooled);
                {error, Reason} -> xet_routes:error_response(400, Reason)
            end
    end.

validate_and_commit(Env, Ns, Hash, Spooled) ->
    Bin = xet_http_body:binary_of(Spooled),
    Result =
        case xet_xorb:decode_any(Bin) of
            {ok, #{hash := Hash} = Decoded} ->
                commit(Env, Ns, Hash, Bin, Decoded);
            {ok, #{hash := _Other}} ->
                xet_routes:error_response(400, <<"hash_mismatch">>);
            {error, Reason} ->
                xet_routes:error_response(400, reason_to_binary(Reason))
        end,
    ok = xet_http_body:cleanup(Spooled),
    Result.

commit(#{metadata := Metadata, blob := Blob}, Ns, Hash, Bin, Decoded) ->
    Meta = #{
        hash => Hash,
        ns => Ns,
        entries => lists:zip(
            maps:get(chunk_hashes, Decoded),
            [byte_size(C) || C <- maps:get(chunks, Decoded)]
        ),
        boundary_offsets => maps:get(boundary_offsets, Decoded),
        unpacked_offsets => maps:get(unpacked_offsets, Decoded),
        bytes_on_disk => byte_size(Bin)
    },
    maybe
        ok ?= xet_blob_store:put(Blob, Ns, Hash, Bin),
        ok ?= xet_metadata:register_xorb(Metadata, Meta),
        reply_inserted(true)
    else
        {error, _} -> xet_routes:error_response(500, <<"storage_error">>)
    end.

head(Req) ->
    Env = xet_server:env(livery_req:config(server, Req)),
    case request_target(Req, Env) of
        {ok, _Ns, Hash} ->
            #{metadata := Metadata} = Env,
            case xet_metadata:xorb_exists(Metadata, Hash) of
                true -> livery_resp:empty(200);
                false -> livery_resp:empty(404)
            end;
        {error, Resp} ->
            Resp
    end.

%% Shared: namespace allowlist + strict hash string validation.
request_target(Req, #{config := Config}) ->
    Ns = livery_req:binding(<<"ns">>, Req),
    HashStr = livery_req:binding(<<"hash">>, Req),
    Allowed = lists:member(Ns, maps:get(namespaces, Config)),
    case {Allowed, xet_hash:is_hash_string(HashStr)} of
        {true, true} -> {ok, Ns, xet_hash:from_string(HashStr)};
        {false, _} -> {error, xet_routes:error_response(400, <<"unknown_namespace">>)};
        {_, false} -> {error, xet_routes:error_response(400, <<"bad_hash">>)}
    end.

reply_inserted(Inserted) ->
    livery_resp:json(200, json:encode(#{was_inserted => Inserted})).

reason_to_binary(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason);
reason_to_binary(Reason) ->
    iolist_to_binary(io_lib:format("~0p", [Reason])).
