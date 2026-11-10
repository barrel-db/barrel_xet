%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% S3 blob store on livery_s3: key layout <ns>/<hex>. Works against AWS
%% S3 and compatibles (Garage, MinIO, Ceph). Also provides presigned GET
%% URLs for reconstruction fetch_info.
-module(xet_store_s3).

-behaviour(xet_blob_store).

-export([open/1, close/1, put/4, get_range/5, size/3, exists/3, delete/3, presign/4]).

-define(OCTET_STREAM, <<"application/octet-stream">>).

open(#{bucket := Bucket} = Opts) ->
    case client(Opts) of
        {ok, Client} -> {ok, #{client => Client, bucket => Bucket}};
        {error, _} = Error -> Error
    end.

client(#{client := Client}) ->
    {ok, Client};
client(#{s3 := S3Opts}) ->
    try
        {ok, livery_s3:new(S3Opts)}
    catch
        _:Reason -> {error, {s3_client, Reason}}
    end.

close(_State) ->
    ok.

put(#{client := Client, bucket := Bucket} = State, Ns, Hash, Body) ->
    maybe
        {ok, Key} ?= key(Ns, Hash),
        case exists(State, Ns, Hash) of
            true ->
                ok;
            false ->
                put_new(Client, Bucket, Key, full_body(Body))
        end
    end.

put_new(Client, Bucket, Key, Body) ->
    %% No stored Cache-Control: the presigned URL sets one per URL (see
    %% presign/4). Some backends (Garage) drop that override on ranged
    %% GETs and would serve a stored max-age that outlives the URL instead.
    case livery_s3:put_object(Client, Bucket, Key, Body, #{content_type => ?OCTET_STREAM}) of
        {ok, _} ->
            ok;
        {error, _} = Error ->
            logger:warning("s3 put_object failed for ~ts (retries exhausted): ~p", [Key, Error]),
            Error
    end.

%% Strict S3 implementations (AWS, RustFS) reject a PUT without a
%% Content-Length, which a streamed body cannot carry. A xorb is bounded
%% (max_xorb_bytes), so collect the stream and send it whole.
full_body({stream, Producer}) ->
    collect(Producer, []);
full_body(IoData) ->
    IoData.

collect(Producer, Acc) ->
    case Producer() of
        eof -> iolist_to_binary(lists:reverse(Acc));
        {ok, Part, Next} -> collect(Next, [Part | Acc])
    end.

get_range(#{client := Client, bucket := Bucket}, Ns, Hash, Start, Len) ->
    maybe
        {ok, Key} ?= key(Ns, Hash),
        case livery_s3:get_object(Client, Bucket, Key, #{range => {Start, Start + Len - 1}}) of
            {ok, #{body := Body}} when byte_size(Body) =:= Len -> {ok, Body};
            {ok, _} -> {error, bad_range};
            {error, Reason} -> {error, normalize(Reason)}
        end
    end.

size(#{client := Client, bucket := Bucket}, Ns, Hash) ->
    maybe
        {ok, Key} ?= key(Ns, Hash),
        case livery_s3:head_object(Client, Bucket, Key) of
            {ok, #{content_length := Size}} -> {ok, Size};
            {error, Reason} -> {error, normalize(Reason)}
        end
    end.

exists(State, Ns, Hash) ->
    case size(State, Ns, Hash) of
        {ok, _} -> true;
        {error, _} -> false
    end.

delete(#{client := Client, bucket := Bucket}, Ns, Hash) ->
    maybe
        {ok, Key} ?= key(Ns, Hash),
        case livery_s3:delete_object(Client, Bucket, Key) of
            ok -> ok;
            {error, _} = Error -> Error
        end
    end.

%% Presigned GET for fetch_info URLs; the client applies byte ranges as
%% HTTP Range headers on top. The response Cache-Control is overridden so
%% caches never keep the bytes past the URL's validity (spec 13.6.1).
%% S3 ETags are MD5 digests and cannot carry the xorb hash.
-spec presign(map(), binary(), xet_hash:hash(), pos_integer()) ->
    {ok, binary()} | {error, term()}.
presign(#{client := Client, bucket := Bucket}, Ns, Hash, ExpiresSecs) ->
    maybe
        {ok, Key} ?= key(Ns, Hash),
        CacheControl = <<"public, immutable, max-age=", (integer_to_binary(ExpiresSecs))/binary>>,
        livery_s3:presign(Client, get, Bucket, Key, ExpiresSecs, #{
            response_cache_control => CacheControl
        })
    end.

key(Ns, Hash) ->
    case xet_blob_store:valid_namespace(Ns) of
        true -> {ok, <<Ns/binary, "/", (xet_hash:to_string(Hash))/binary>>};
        false -> {error, bad_namespace}
    end.

normalize(not_found) -> not_found;
normalize({s3, <<"NoSuchKey">>, _, _}) -> not_found;
normalize({s3, <<"InvalidRange">>, _, _}) -> bad_range;
normalize(Other) -> Other.
