%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(xet_upload_pipeline_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    upload_and_download_roundtrip/1,
    reupload_dedups/1,
    cross_file_dedup/1,
    append_uploads_tail_only/1,
    parallel_map/1
]).

-define(TOKEN, <<"pipe-token">>).

all() ->
    [
        upload_and_download_roundtrip,
        reupload_dedups,
        cross_file_dedup,
        append_uploads_tail_only,
        parallel_map
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started([barrel_xet, hackney]),
    DataDir = filename:join(proplists:get_value(priv_dir, Config), "pipe"),
    {ok, _} = xet_server:start(#{
        name => xet_pipe_server,
        data_dir => DataDir,
        auth => {xet_auth_static, #{tokens => #{?TOKEN => write}}}
    }),
    Endpoint = list_to_binary(
        "http://127.0.0.1:" ++ integer_to_list(xet_server:port(xet_pipe_server))
    ),
    [{endpoint, Endpoint} | Config].

end_per_suite(_Config) ->
    ok = xet_server:stop(xet_pipe_server),
    ok.

client(Config) ->
    xet_client:new(#{endpoint => proplists:get_value(endpoint, Config), token => ?TOKEN}).

%% Several chunks worth of deterministic data.
data(Seed, Bytes) ->
    xet_test_vectors:splitmix64_data(Bytes, Seed).

%% Reconstruct a file from a v2 reconstruction response by fetching the
%% signed data URLs and slicing per term.
download(Client, FileHash) ->
    {ok, Recon} = xet_client:get_reconstruction(Client, FileHash),
    Xorbs = maps:get(<<"xorbs">>, Recon),
    Fetched = maps:from_list([
        {CasStr, fetch(Url)}
     || {CasStr, [#{<<"url">> := Url}]} <- maps:to_list(Xorbs)
    ]),
    Assembled = list_to_binary([
        term_bytes(Term, Fetched)
     || Term <- maps:get(<<"terms">>, Recon)
    ]),
    Skip = maps:get(<<"offset_into_first_range">>, Recon),
    binary:part(Assembled, Skip, byte_size(Assembled) - Skip).

fetch(Url) ->
    {ok, 200, _, Body} = hackney:request(get, Url, [], <<>>, [with_body, {pool, false}]),
    {ok, Dec} = xet_xorb:decode(Body),
    maps:get(chunks, Dec).

term_bytes(Term, Fetched) ->
    CasStr = maps:get(<<"hash">>, Term),
    #{<<"start">> := S, <<"end">> := E} = maps:get(<<"range">>, Term),
    Chunks = maps:get(CasStr, Fetched),
    list_to_binary(lists:sublist(Chunks, S + 1, E - S)).

upload_and_download_roundtrip(Config) ->
    Client = client(Config),
    Data = data(1, 300000),
    {ok, #{file_hash := FileHash, stats := Stats}} = xet_client_upload:upload_data(
        Client, f1, Data
    ),
    ?assertEqual(
        xet_hash:to_string(xet_hash:file_hash(chunk_entries(Data))),
        xet_hash:to_string(FileHash)
    ),
    ?assert(maps:get(new_bytes, Stats) > 0),
    ?assertEqual(Data, download(Client, FileHash)).

reupload_dedups(Config) ->
    Client = client(Config),
    Data = data(2, 250000),
    {ok, _} = xet_client_upload:upload_data(Client, f2, Data),
    {ok, #{stats := Stats2}} = xet_client_upload:upload_data(Client, f2b, Data),
    %% Everything is already stored: the second upload sends no new bytes.
    ?assertEqual(0, maps:get(new_bytes, Stats2)),
    ?assert(maps:get(deduped_bytes, Stats2) > 0).

cross_file_dedup(Config) ->
    Client = client(Config),
    Shared = data(3, 200000),
    {ok, _} = xet_client_upload:upload_data(Client, a, Shared),
    %% A file that is the shared block plus a unique tail dedups the head.
    Tail = data(99, 120000),
    Combined = <<Shared/binary, Tail/binary>>,
    {ok, #{file_hash := FileHash, stats := Stats}} =
        xet_client_upload:upload_data(Client, b, Combined),
    ?assert(maps:get(deduped_bytes, Stats) > 0),
    ?assert(maps:get(new_bytes, Stats) > 0),
    ?assertEqual(Combined, download(Client, FileHash)).

append_uploads_tail_only(Config) ->
    Client = client(Config),
    Base = data(4, 400000),
    {ok, _} = xet_client_upload:upload_data(Client, orig, Base),
    Appended = <<Base/binary, (data(5, 80000))/binary>>,
    {ok, #{stats := Stats}} = xet_client_upload:upload_data(Client, appended, Appended),
    %% CDC keeps most boundaries stable: the shared prefix dedups, only
    %% the tail region is new.
    ?assert(maps:get(deduped_bytes, Stats) > byte_size(Base) div 2),
    ?assert(maps:get(new_bytes, Stats) < byte_size(Base)).

parallel_map(_Config) ->
    Doubled = xet_par:map(fun(X) -> X * 2 end, lists:seq(1, 50), 8),
    ?assertEqual([X * 2 || X <- lists:seq(1, 50)], Doubled),
    ?assertEqual([], xet_par:map(fun(X) -> X end, [], 4)),
    %% A crashing worker is isolated to its element.
    Mixed = xet_par:map(
        fun
            (3) -> error(boom);
            (X) -> X
        end,
        [1, 2, 3, 4],
        2
    ),
    ?assertMatch([1, 2, {error, {worker_crash, _}}, 4], Mixed).

chunk_entries(Data) ->
    [{xet_hash:chunk_hash(C), byte_size(C)} || C <- xet_chunker:split(Data)].
