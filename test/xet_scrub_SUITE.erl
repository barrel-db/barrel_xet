%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Scrub reads every stored xorb and re-checks its hash: a clean store
%% passes, a flipped byte is reported as corrupt (and left in place,
%% never deleted), and a missing blob is a read error.
-module(xet_scrub_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([clean_pass/1, flipped_byte_is_corrupt/1, missing_blob_is_read_error/1]).

all() ->
    [clean_pass, flipped_byte_is_corrupt, missing_blob_is_read_error].

init_per_testcase(Case, Config) ->
    {ok, _} = application:ensure_all_started([barrel_xet]),
    Name = list_to_atom("xet_scrub_" ++ atom_to_list(Case)),
    DataDir = filename:join(proplists:get_value(priv_dir, Config), atom_to_list(Case)),
    {ok, _} = xet_server:start(#{
        name => Name,
        data_dir => DataDir,
        %% No throttling in tests.
        scrub => #{rate_bytes_per_sec => 1 bsl 40, interval => false},
        auth => {xet_auth_static, #{tokens => #{}}}
    }),
    [{name, Name} | Config].

end_per_testcase(_Case, Config) ->
    ok = xet_server:stop(proplists:get_value(name, Config)).

env(Config) -> xet_server:env(proplists:get_value(name, Config)).

%% Encode a real xorb, store the blob, and register its metadata.
store_xorb(Config, Seeds) ->
    #{blob := Blob, metadata := Meta} = env(Config),
    Chunks = [xet_test_vectors:splitmix64_data(2000 + S, S) || S <- Seeds],
    {ok, Enc} = xet_xorb:encode(Chunks, #{nonce => <<0, 0, 0, 0>>}),
    Hash = maps:get(hash, Enc),
    Bin = maps:get(bin, Enc),
    ok = xet_blob_store:put(Blob, <<"default">>, Hash, Bin),
    ok = xet_metadata:register_xorb(Meta, #{
        hash => Hash,
        ns => <<"default">>,
        entries => lists:zip(maps:get(chunk_hashes, Enc), maps:get(unpacked_sizes, Enc)),
        boundary_offsets => maps:get(boundary_offsets, Enc),
        unpacked_offsets => maps:get(unpacked_offsets, Enc),
        bytes_on_disk => byte_size(Bin)
    }),
    Hash.

blob_path(Config, Hash) ->
    #{blob := Blob} = env(Config),
    {ok, Path} = xet_blob_store:local_path(Blob, <<"default">>, Hash),
    Path.

run_scrub(Config) ->
    Name = proplists:get_value(name, Config),
    {ok, started} = xet_scrub:trigger(Name),
    wait_result(Name, 200).

wait_result(_Name, 0) ->
    error(scrub_timeout);
wait_result(Name, N) ->
    Status = xet_scrub:status(Name),
    case maps:get(running, Status) of
        false ->
            maps:get(last, Status);
        true ->
            timer:sleep(20),
            wait_result(Name, N - 1)
    end.

clean_pass(Config) ->
    _ = store_xorb(Config, [1, 2, 3]),
    _ = store_xorb(Config, [4, 5]),
    Result = run_scrub(Config),
    ?assertEqual(2, maps:get(checked, Result)),
    ?assertEqual(0, maps:get(corrupt, Result)),
    ?assertEqual(0, maps:get(read_errors, Result)),
    ?assertEqual([], maps:get(findings, Result)).

flipped_byte_is_corrupt(Config) ->
    Hash = store_xorb(Config, [10, 11]),
    Path = blob_path(Config, Hash),
    {ok, Bin} = file:read_file(Path),
    %% Flip a byte in the chunk data (well before the footer nonce).
    <<Head:50/binary, Byte, Tail/binary>> = Bin,
    ok = file:write_file(Path, <<Head/binary, (Byte bxor 255), Tail/binary>>),
    Result = run_scrub(Config),
    ?assertEqual(1, maps:get(checked, Result)),
    ?assertEqual(1, maps:get(corrupt, Result)),
    [Finding] = maps:get(findings, Result),
    ?assertEqual(xet_hash:to_string(Hash), maps:get(hash, Finding)),
    ?assertEqual(corrupt, maps:get(kind, Finding)),
    %% Scrub never deletes: the (corrupt) blob is still there.
    #{blob := Blob} = env(Config),
    ?assert(xet_blob_store:exists(Blob, <<"default">>, Hash)).

missing_blob_is_read_error(Config) ->
    Hash = store_xorb(Config, [20]),
    ok = file:delete(blob_path(Config, Hash)),
    Result = run_scrub(Config),
    ?assertEqual(1, maps:get(read_errors, Result)),
    [Finding] = maps:get(findings, Result),
    ?assertEqual(read_error, maps:get(kind, Finding)).
