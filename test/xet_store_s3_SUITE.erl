%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(xet_store_s3_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0]).
-export([init_per_group/2, end_per_group/2]).
-export([
    roundtrip/1,
    stream_put/1,
    missing_blob/1,
    idempotent_and_delete/1,
    presign/1,
    store_metrics_labeled/1,
    put_survives_transient/1,
    put_exhausts_retries/1,
    server_roundtrip/1
]).

-define(NS, <<"default">>).
-define(TOKEN, <<"s3-live-token">>).

all() ->
    [{group, fake}, {group, live}].

%% live runs against whatever XET_S3_ENDPOINT points at: Garage
%% (test/docker/garage-up.sh) or RustFS (test/docker/rustfs-up.sh).
groups() ->
    Common = [
        roundtrip, stream_put, missing_blob, idempotent_and_delete, presign, store_metrics_labeled
    ],
    %% Failure injection is a fake-server feature; a real S3 runs the
    %% rest, plus the server end to end over presigned URLs.
    FakeOnly = [put_survives_transient, put_exhausts_retries],
    [{fake, [], Common ++ FakeOnly}, {live, [], Common ++ [server_roundtrip]}].

init_per_group(fake, Config) ->
    {ok, _} = application:ensure_all_started(livery),
    {ok, Fake} = xet_fake_s3:start(),
    Port = maps:get(port, Fake),
    {ok, Store} = xet_blob_store:open(xet_store_s3, #{
        bucket => <<"xet-test">>,
        s3 => #{
            endpoint => list_to_binary("http://127.0.0.1:" ++ integer_to_list(Port)),
            region => <<"garage">>,
            access_key_id => <<"test">>,
            secret_access_key => <<"testsecret">>,
            %% No connection pool: the fake server is single-use, and a
            %% pooled keep-alive it has recycled surfaces as {error,
            %% bad_request} on the next (streamed, non-replayable) request.
            adapter_opts => #{hackney => [{pool, false}]}
        }
    }),
    [{store, Store}, {fake, Fake} | Config];
init_per_group(live, Config) ->
    case os:getenv("XET_S3_ENDPOINT") of
        false ->
            {skip,
                "XET_S3_ENDPOINT not set; run test/docker/garage-up.sh or test/docker/rustfs-up.sh"};
        _ ->
            {ok, _} = application:ensure_all_started(livery_s3),
            {ok, Store} = xet_blob_store:open(xet_store_s3, s3_opts()),
            [{store, Store} | Config]
    end.

%% Blob-store options for the live S3 named by the XET_S3_* variables.
s3_opts() ->
    #{
        bucket => list_to_binary(os:getenv("XET_S3_BUCKET", "barrel-xet-test")),
        s3 => #{
            endpoint => list_to_binary(os:getenv("XET_S3_ENDPOINT")),
            region => list_to_binary(os:getenv("XET_S3_REGION", "garage")),
            access_key_id => list_to_binary(os:getenv("XET_S3_ACCESS_KEY", "")),
            secret_access_key => list_to_binary(os:getenv("XET_S3_SECRET_KEY", ""))
        }
    }.

end_per_group(fake, Config) ->
    ok = xet_fake_s3:stop(proplists:get_value(fake, Config)),
    ok;
end_per_group(_, _Config) ->
    ok.

store(Config) -> proplists:get_value(store, Config).

roundtrip(Config) ->
    Store = store(Config),
    Data = xet_test_vectors:splitmix64_data(120000, 3),
    Hash = <<21:256>>,
    ok = xet_blob_store:put(Store, ?NS, Hash, Data),
    ?assert(xet_blob_store:exists(Store, ?NS, Hash)),
    ?assertEqual({ok, 120000}, xet_blob_store:size(Store, ?NS, Hash)),
    ?assertEqual(
        {ok, binary:part(Data, 40000, 1234)},
        xet_blob_store:get_range(Store, ?NS, Hash, 40000, 1234)
    ),
    ?assertEqual(
        {ok, binary:part(Data, 119999, 1)},
        xet_blob_store:get_range(Store, ?NS, Hash, 119999, 1)
    ).

stream_put(Config) ->
    Store = store(Config),
    Parts = [xet_test_vectors:splitmix64_data(50000, I) || I <- [7, 8]],
    ok = xet_blob_store:put(Store, ?NS, <<22:256>>, {stream, producer(Parts)}),
    ?assertEqual(
        {ok, list_to_binary(Parts)},
        xet_blob_store:get_range(Store, ?NS, <<22:256>>, 0, 100000)
    ).

producer([]) ->
    fun() -> eof end;
producer([Part | Rest]) ->
    fun() -> {ok, Part, producer(Rest)} end.

missing_blob(Config) ->
    Store = store(Config),
    ?assertEqual({error, not_found}, xet_blob_store:size(Store, ?NS, <<23:256>>)),
    ?assertEqual({error, not_found}, xet_blob_store:get_range(Store, ?NS, <<23:256>>, 0, 10)),
    ?assertNot(xet_blob_store:exists(Store, ?NS, <<23:256>>)).

idempotent_and_delete(Config) ->
    Store = store(Config),
    ok = xet_blob_store:put(Store, ?NS, <<24:256>>, <<"body">>),
    ok = xet_blob_store:put(Store, ?NS, <<24:256>>, <<"body">>),
    ok = xet_blob_store:delete(Store, ?NS, <<24:256>>),
    ok = xet_blob_store:delete(Store, ?NS, <<24:256>>),
    ?assertNot(xet_blob_store:exists(Store, ?NS, <<24:256>>)).

presign(Config) ->
    Store = store(Config),
    Data = <<"presigned payload">>,
    ok = xet_blob_store:put(Store, ?NS, <<25:256>>, Data),
    {ok, Url} = xet_blob_store:presign(Store, ?NS, <<25:256>>, 900),
    ?assert(is_binary(Url)),
    %% Spec 13.6.1: cacheable as immutable, never past the URL's life.
    #{query := Query} = uri_string:parse(Url),
    Params = uri_string:dissect_query(Query),
    Expected = <<"public, immutable, max-age=900">>,
    ?assertEqual(Expected, proplists:get_value(<<"response-cache-control">>, Params)),
    {ok, 200, Headers, Body} = hackney:request(get, Url, [], <<>>, [with_body]),
    ?assertEqual(Data, Body),
    %% Whatever a backend serves, full or ranged (clients always send
    %% Range), it is the override or nothing: never a longer max-age.
    %% The fake ignores the override; Garage drops it on ranged GETs.
    ?assert(lists:member(cache_control(Headers), [undefined, Expected])),
    {ok, 206, Ranged, <<"pre">>} = hackney:request(
        get, Url, [{<<"range">>, <<"bytes=0-2">>}], <<>>, [with_body]
    ),
    ?assert(lists:member(cache_control(Ranged), [undefined, Expected])).

cache_control(Headers) ->
    proplists:get_value(<<"cache-control">>, [{string:lowercase(K), V} || {K, V} <- Headers]).

%% The livery_s3 client retries transient 5xx on an idempotent PUT with
%% a full-binary body (xorb uploads always are): two 503s then success.
put_survives_transient(Config) ->
    Store = store(Config),
    ok = xet_fake_s3:fail_next(proplists:get_value(fake, Config), 2, 503),
    ok = xet_blob_store:put(Store, ?NS, <<30:256>>, <<"survives">>),
    ?assertEqual({ok, <<"survives">>}, xet_blob_store:get_range(Store, ?NS, <<30:256>>, 0, 8)).

%% When the transient failures outlast the retry budget, the put errors
%% and the blob is not stored. (xet_store_s3 logs a warning; see T9.5.)
put_exhausts_retries(Config) ->
    Store = store(Config),
    Fake = proplists:get_value(fake, Config),
    ok = xet_fake_s3:fail_next(Fake, 10, 503),
    try
        ?assertMatch({error, _}, xet_blob_store:put(Store, ?NS, <<31:256>>, <<"nope">>)),
        ?assertNot(xet_blob_store:exists(Store, ?NS, <<31:256>>))
    after
        %% Clear the leftover failure budget for any later case.
        ok = xet_fake_s3:fail_next(Fake, 0, 503)
    end.

%% Store ops through the behaviour wrapper record duration and byte
%% metrics labeled with the s3 backend.
store_metrics_labeled(Config) ->
    {ok, _} = application:ensure_all_started(instrument),
    Store = store(Config),
    Data = binary:copy(<<"m">>, 777),
    ok = xet_blob_store:put(Store, ?NS, <<26:256>>, Data),
    {ok, _} = xet_blob_store:get_range(Store, ?NS, <<26:256>>, 0, 777),
    Body = iolist_to_binary(instrument_prometheus:format()),
    Present = fun(Sub) -> ?assertNotEqual(nomatch, binary:match(Body, Sub)) end,
    Present(<<"xet.store.op.duration">>),
    Present(<<"xet.store.write.bytes">>),
    Present(<<"xet.store.read.bytes">>),
    Present(<<"backend=\"s3\"">>).

%% The server on a real S3, end to end: the client uploads through the
%% API, then downloads through the bucket's presigned URLs (SigV4 query
%% signing, the Cache-Control override, and a client Range header).
server_roundtrip(Config) ->
    {ok, _} = application:ensure_all_started([barrel_xet, hackney]),
    {ok, _} = xet_server:start(#{
        name => xet_s3_live_server,
        data_dir => filename:join(proplists:get_value(priv_dir, Config), "live"),
        blob => {s3, s3_opts()},
        auth => {xet_auth_static, #{tokens => #{?TOKEN => write}}}
    }),
    try
        Endpoint =
            <<"http://127.0.0.1:",
                (integer_to_binary(xet_server:port(xet_s3_live_server)))/binary>>,
        Client = xet_client:new(#{endpoint => Endpoint, token => ?TOKEN}),
        Data = xet_test_vectors:splitmix64_data(300000, erlang:unique_integer([positive])),
        {ok, #{file_hash := Hash}} = xet_client_upload:upload_data(Client, live, Data),
        {ok, Recon} = xet_client:get_reconstruction(Client, Hash),
        [[#{<<"url">> := Url} | _] | _] = maps:values(maps:get(<<"xorbs">>, Recon)),
        %% Fetch URLs point at the bucket, not at the server's data route.
        ?assertEqual(nomatch, binary:match(Url, <<"/data?">>)),
        ?assertEqual({ok, Data}, xet_client_download:download_data(Client, Hash)),
        ?assertEqual(
            {ok, binary:part(Data, 100000, 50001)},
            xet_client_download:download_range(Client, Hash, {100000, 150000})
        )
    after
        ok = xet_server:stop(xet_s3_live_server)
    end.
