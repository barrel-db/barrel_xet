%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% S3 blob store on livery_s3: key layout <ns>/<hex>. Works against AWS
%% S3 and compatibles (Garage, MinIO, Ceph). Also provides presigned GET
%% URLs for reconstruction fetch_info.
-module(xet_store_s3).

-behaviour(xet_blob_store).

-export([open/1, close/1, put/4, get_range/5, size/3, exists/3, delete/3, presign/4]).

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
                case
                    livery_s3:put_object(Client, Bucket, Key, Body, #{
                        content_type => <<"application/octet-stream">>
                    })
                of
                    {ok, _} -> ok;
                    {error, _} = Error -> Error
                end
        end
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
%% HTTP Range headers on top.
-spec presign(map(), binary(), xet_hash:hash(), pos_integer()) ->
    {ok, binary()} | {error, term()}.
presign(#{client := Client, bucket := Bucket}, Ns, Hash, ExpiresSecs) ->
    maybe
        {ok, Key} ?= key(Ns, Hash),
        livery_s3:presign(Client, get, Bucket, Key, ExpiresSecs)
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
