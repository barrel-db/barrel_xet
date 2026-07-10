%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Load smoke and observability. Bounded concurrent uploads/downloads
%% exercise the full stack; a NIF stress case checks the primitives stay
%% correct under parallel dirty-scheduler load; an observability case
%% confirms the instrument middleware serves requests without failing.
-module(xet_load_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    concurrent_upload_download/1,
    nif_stress/1,
    observability_enabled/1
]).

-define(TOKEN, <<"load-token">>).

all() ->
    [concurrent_upload_download, nif_stress, observability_enabled].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started([barrel_xet, hackney]),
    DataDir = filename:join(proplists:get_value(priv_dir, Config), "loadsrv"),
    %% Exercise the concurrent path through the full production middleware
    %% stack: observability, access log, and request timeouts all on.
    {ok, _} = xet_server:start(#{
        name => xet_load_server,
        data_dir => DataDir,
        observability => true,
        access_log => true,
        request_timeout => 30000,
        auth => {xet_auth_static, #{tokens => #{?TOKEN => write}}}
    }),
    Endpoint = list_to_binary(
        "http://127.0.0.1:" ++ integer_to_list(xet_server:port(xet_load_server))
    ),
    [{endpoint, Endpoint} | Config].

end_per_suite(_Config) ->
    ok = xet_server:stop(xet_load_server),
    ok.

%% 24 workers each upload a distinct file and download it back, all
%% concurrently. Every roundtrip must be byte-identical.
concurrent_upload_download(Config) ->
    Endpoint = proplists:get_value(endpoint, Config),
    Workers = 24,
    Parent = self(),
    Pids = [
        spawn(fun() ->
            Client = xet_client:new(#{endpoint => Endpoint, token => ?TOKEN}),
            Data = xet_test_vectors:splitmix64_data(150000 + I * 997, I),
            Result =
                case xet_client_upload:upload_data(Client, {w, I}, Data) of
                    {ok, #{file_hash := H}} ->
                        xet_client_download:download_data(Client, H) =:= {ok, Data};
                    _ ->
                        false
                end,
            Parent ! {done, self(), Result}
        end)
     || I <- lists:seq(1, Workers)
    ],
    Results = [
        receive
            {done, Pid, R} -> R
        after 60000 -> timeout
        end
     || Pid <- Pids
    ],
    ?assertEqual(lists:duplicate(Workers, true), Results).

%% Hammer the primitives from many processes at once (large inputs route
%% to dirty schedulers): results must stay correct and identical to the
%% single-threaded reference.
nif_stress(_Config) ->
    Data = xet_test_vectors:splitmix64_data(500000, 42),
    ExpectedBoundaries = xet_chunker:chunk_boundaries(Data),
    ExpectedHash = xet_hash:file_hash([
        {xet_hash:chunk_hash(C), byte_size(C)}
     || C <- xet_chunker:split(Data)
    ]),
    Frame = xet_nif:lz4f_compress(Data),
    Results = xet_par:map(
        fun(_) ->
            Boundaries = xet_chunker:chunk_boundaries(Data),
            Hash = xet_hash:file_hash([
                {xet_hash:chunk_hash(C), byte_size(C)}
             || C <- xet_chunker:split(Data)
            ]),
            {ok, Decompressed} = xet_nif:lz4f_decompress(Frame, byte_size(Data)),
            Boundaries =:= ExpectedBoundaries andalso
                Hash =:= ExpectedHash andalso
                Decompressed =:= Data
        end,
        lists:seq(1, 32),
        16
    ),
    ?assertEqual(lists:duplicate(32, true), Results).

%% A server with observability on serves health and a full upload/
%% download roundtrip: the instrument middleware records without failing
%% requests.
observability_enabled(Config) ->
    DataDir = filename:join(proplists:get_value(priv_dir, Config), "obs"),
    {ok, _} = xet_server:start(#{
        name => xet_obs_server,
        data_dir => DataDir,
        observability => true,
        auth => {xet_auth_static, #{tokens => #{?TOKEN => write}}}
    }),
    try
        Base = "http://127.0.0.1:" ++ integer_to_list(xet_server:port(xet_obs_server)),
        {ok, 200, _, _} = hackney:request(get, Base ++ "/healthz", [], <<>>, [
            with_body, {pool, false}
        ]),
        Client = xet_client:new(#{endpoint => list_to_binary(Base), token => ?TOKEN}),
        Data = xet_test_vectors:splitmix64_data(200000, 7),
        {ok, #{file_hash := Hash}} = xet_client_upload:upload_data(Client, obs, Data),
        ?assertEqual({ok, Data}, xet_client_download:download_data(Client, Hash)),
        %% The roundtrip above was recorded: the scrape proves it.
        {ok, 200, _, Metrics} = hackney:request(
            get,
            Base ++ "/metrics",
            [{<<"authorization">>, <<"Bearer ", ?TOKEN/binary>>}],
            <<>>,
            [with_body, {pool, false}]
        ),
        ?assertNotEqual(nomatch, binary:match(Metrics, <<"http.server.request.duration">>))
    after
        ok = xet_server:stop(xet_obs_server)
    end.
