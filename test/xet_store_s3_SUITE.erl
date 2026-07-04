-module(xet_store_s3_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0]).
-export([init_per_group/2, end_per_group/2]).
-export([roundtrip/1, stream_put/1, missing_blob/1, idempotent_and_delete/1, presign/1]).

-define(NS, <<"default">>).

all() ->
    [{group, fake}, {group, garage}].

groups() ->
    Cases = [roundtrip, stream_put, missing_blob, idempotent_and_delete, presign],
    [{fake, [], Cases}, {garage, [], Cases}].

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
            secret_access_key => <<"testsecret">>
        }
    }),
    [{store, Store}, {fake, Fake} | Config];
init_per_group(garage, Config) ->
    case os:getenv("XET_S3_ENDPOINT") of
        false ->
            {skip, "XET_S3_ENDPOINT not set; run test/docker/garage-up.sh"};
        Endpoint ->
            {ok, _} = application:ensure_all_started(livery_s3),
            {ok, Store} = xet_blob_store:open(xet_store_s3, #{
                bucket => list_to_binary(os:getenv("XET_S3_BUCKET", "barrel-xet-test")),
                s3 => #{
                    endpoint => list_to_binary(Endpoint),
                    region => list_to_binary(os:getenv("XET_S3_REGION", "garage")),
                    access_key_id => list_to_binary(os:getenv("XET_S3_ACCESS_KEY", "")),
                    secret_access_key => list_to_binary(os:getenv("XET_S3_SECRET_KEY", ""))
                }
            }),
            [{store, Store} | Config]
    end.

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
    {ok, 200, _Headers, Body} = hackney:request(get, Url, [], <<>>, [with_body]),
    ?assertEqual(Data, Body).
