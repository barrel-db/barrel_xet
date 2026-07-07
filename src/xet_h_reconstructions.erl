%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Reconstruction endpoints (spec A.3 and the V2 evolution):
%%   GET /v1/reconstructions/{file_hash}: terms + fetch_info
%%   GET /v2/reconstructions/{file_hash}: terms + per-xorb multi-ranges
%%   HEAD /v1/files/{file_hash}: existence
%%
%% Range headers narrow the plan (strict bytes=A-B form, 416 otherwise).
%% Fetch URLs come from the blob backend: S3 presigns, the FS backend
%% gets signed self URLs onto the data endpoint. Responses are
%% private/no-store: they embed expiring URLs (spec 13.6.1).
-module(xet_h_reconstructions).

-export([get_v1/1, get_v2/1, head_file/1]).

get_v1(Req) ->
    serve(Req, fun xet_reconstruction:to_v1/2).

get_v2(Req) ->
    serve(Req, fun xet_reconstruction:to_v2/2).

serve(Req, Render) ->
    Env = xet_server:env(livery_req:config(server, Req)),
    try
        maybe
            {ok, Hash} ?= file_hash(Req),
            {ok, FileMeta} ?= lookup(Env, Hash),
            {ok, Range} ?= parse_range(Req),
            {ok, Plan} ?= plan(Env, FileMeta, Range),
            Rendered = Render(Plan, render_ctx(Req, Env)),
            respond(Rendered)
        else
            {error, Resp} -> Resp
        end
    catch
        %% A file references a xorb the metadata no longer has: log
        %% loudly (a data inconsistency) and answer 500 instead of
        %% crashing the request process on a badmatch.
        error:{missing_xorb, MissingHash} ->
            logger:error(
                "reconstruction references missing xorb ~ts (data inconsistency)",
                [xet_hash:to_string(MissingHash)]
            ),
            xet_routes:error_response(500, <<"inconsistent_metadata">>)
    end.

%% Load a xorb the plan depends on, or signal the inconsistency to
%% serve/2's handler.
fetch_xorb(Metadata, CasHash) ->
    case xet_metadata:get_xorb(Metadata, CasHash) of
        {ok, Xorb} -> Xorb;
        not_found -> error({missing_xorb, CasHash})
    end.

head_file(Req) ->
    Env = xet_server:env(livery_req:config(server, Req)),
    case file_hash(Req) of
        {ok, Hash} ->
            #{metadata := Metadata} = Env,
            case xet_metadata:file_exists(Metadata, Hash) of
                true -> livery_resp:empty(200);
                false -> livery_resp:empty(404)
            end;
        {error, Resp} ->
            Resp
    end.

file_hash(Req) ->
    HashStr = livery_req:binding(<<"hash">>, Req),
    case xet_hash:is_hash_string(HashStr) of
        true -> {ok, xet_hash:from_string(HashStr)};
        false -> {error, xet_routes:error_response(400, <<"bad_hash">>)}
    end.

lookup(#{metadata := Metadata}, Hash) ->
    case xet_metadata:get_file(Metadata, Hash) of
        {ok, FileMeta} -> {ok, FileMeta};
        not_found -> {error, xet_routes:error_response(404, <<"not_found">>)}
    end.

parse_range(Req) ->
    case xet_http_range:reconstruction_range(livery_req:header(<<"range">>, Req)) of
        all -> {ok, all};
        {ok, Range} -> {ok, Range};
        invalid -> {error, xet_routes:error_response(416, <<"bad_range">>)}
    end.

plan(#{metadata := Metadata}, FileMeta, Range) ->
    InfoFun = fun(CasHash) ->
        Xorb = fetch_xorb(Metadata, CasHash),
        maps:with([unpacked_offsets, boundary_offsets], Xorb)
    end,
    Terms = maps:get(terms, FileMeta),
    Total = maps:get(total_len, FileMeta),
    case xet_reconstruction:plan(Terms, Total, Range, InfoFun) of
        {ok, Plan} ->
            {ok, Plan};
        {error, unsatisfiable} ->
            {error, xet_routes:error_response(416, <<"unsatisfiable">>)};
        {error, inconsistent_metadata} ->
            {error, xet_routes:error_response(500, <<"inconsistent_metadata">>)}
    end.

%% URL construction: one URL per xorb, byte selection stays in Range
%% headers, so both response shapes share it.
render_ctx(Req, #{metadata := Metadata, blob := Blob, config := Config} = _Env) ->
    Ttl = maps:get(url_ttl, Config),
    UrlFun = fun(CasHash, _ByteRange) ->
        Xorb = fetch_xorb(Metadata, CasHash),
        Ns = maps:get(ns, Xorb, <<"default">>),
        case xet_blob_store:presign(Blob, Ns, CasHash, Ttl) of
            {ok, Url} -> Url;
            {error, not_supported} -> signed_self_url(Req, Config, Ns, CasHash, Ttl)
        end
    end,
    BoundaryFun = fun(CasHash) ->
        Xorb = fetch_xorb(Metadata, CasHash),
        maps:get(boundary_offsets, Xorb)
    end,
    #{url => UrlFun, boundaries => BoundaryFun}.

signed_self_url(Req, Config, Ns, CasHash, Ttl) ->
    HashStr = xet_hash:to_string(CasHash),
    Expiry = erlang:system_time(second) + Ttl,
    Sig = xet_url_signer:sign(maps:get(url_secret, Config), Ns, HashStr, Expiry),
    Base = external_base(Req, Config),
    <<Base/binary, "/api/v1/xorbs/", Ns/binary, "/", HashStr/binary, "/data?exp=",
        (integer_to_binary(Expiry))/binary, "&sig=", Sig/binary>>.

external_base(Req, Config) ->
    case maps:get(external_url, Config, undefined) of
        undefined ->
            Host = livery_req:header(<<"host">>, Req, <<"localhost">>),
            <<"http://", Host/binary>>;
        Url ->
            Url
    end.

respond(Rendered) ->
    livery_resp:json(
        200,
        [{<<"cache-control">>, <<"private, no-store">>}],
        json:encode(Rendered)
    ).
