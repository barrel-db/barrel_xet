%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% S3 blob store on livery_s3: key layout <ns>/<hex>. Works against AWS
%% S3 and compatibles (Garage, MinIO, Ceph). Also provides presigned GET
%% URLs for reconstruction fetch_info.
-module(xet_store_s3).

-behaviour(xet_blob_store).

-export([open/1, close/1, put/4, get_range/5, size/3, exists/3, delete/3, presign/4]).
-export([fold_blobs/4]).

-define(OCTET_STREAM, <<"application/octet-stream">>).
-define(LIST_PAGE, 1000).

open(#{bucket := Bucket} = Opts) ->
    case client(Opts) of
        {ok, Client} ->
            {ok, #{
                client => Client,
                bucket => Bucket,
                list_page => maps:get(list_page, Opts, ?LIST_PAGE)
            }};
        {error, _} = Error ->
            Error
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

%% Fold Fun({Ns, Hash, MtimePosix}, Acc) over the blobs of the given
%% namespaces, one ListObjectsV2 page at a time (prefix <ns>/), so a
%% large bucket is never listed into memory at once. Keys that are not
%% <ns>/<hash> are skipped, which keeps a shared bucket safe. An object
%% whose LastModified does not parse is reported as just written, so the
%% orphan sweep's age gate never treats it as old.
fold_blobs(State, Namespaces, Fun, Acc0) ->
    lists:foldl(
        fun
            (Ns, {ok, Acc}) -> fold_pages(State, Ns, undefined, Fun, Acc);
            (_Ns, Error) -> Error
        end,
        {ok, Acc0},
        [Ns || Ns <- Namespaces, xet_blob_store:valid_namespace(Ns)]
    ).

fold_pages(
    #{client := Client, bucket := Bucket, list_page := PageSize} = State, Ns, Token, Fun, Acc0
) ->
    Opts = page_opts(<<Ns/binary, "/">>, PageSize, Token),
    case livery_s3:list_objects(Client, Bucket, Opts) of
        {ok, #{objects := Objects} = Page} ->
            Acc = lists:foldl(fun(Object, A) -> fold_object(Ns, Object, Fun, A) end, Acc0, Objects),
            next_page(State, Ns, Page, Fun, Acc);
        {error, Reason} ->
            {error, normalize(Reason)}
    end.

page_opts(Prefix, PageSize, undefined) ->
    #{prefix => Prefix, max_keys => PageSize};
page_opts(Prefix, PageSize, Token) ->
    #{prefix => Prefix, max_keys => PageSize, continuation_token => Token}.

next_page(State, Ns, #{is_truncated := true, next_continuation_token := Token}, Fun, Acc) when
    is_binary(Token)
->
    fold_pages(State, Ns, Token, Fun, Acc);
next_page(_State, _Ns, _Page, _Fun, Acc) ->
    {ok, Acc}.

fold_object(Ns, #{key := Key} = Object, Fun, Acc) ->
    Prefix = <<Ns/binary, "/">>,
    case Key of
        <<Prefix:(byte_size(Prefix))/binary, Hex/binary>> ->
            case xet_hash:is_hash_string(Hex) of
                true -> Fun({Ns, xet_hash:from_string(Hex), mtime(Object)}, Acc);
                false -> Acc
            end;
        _ ->
            Acc
    end.

mtime(#{last_modified := LastModified}) when is_binary(LastModified) ->
    try
        calendar:rfc3339_to_system_time(binary_to_list(LastModified), [{unit, second}])
    catch
        _:_ -> erlang:system_time(second)
    end;
mtime(_Object) ->
    erlang:system_time(second).
