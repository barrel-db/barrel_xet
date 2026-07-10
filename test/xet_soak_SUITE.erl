%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Soak: run garbage collection, scrub, and a backup checkpoint against a
%% server under live upload/download traffic, on both the filesystem and
%% (fake) S3 backends. Nothing referenced is lost, corruption is not
%% reported on clean data, and the server keeps serving throughout.
-module(xet_soak_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([maintenance_under_traffic/1]).

-define(TOKEN, <<"soak-token">>).

all() ->
    [{group, fs}, {group, s3}].

groups() ->
    [
        {fs, [], [maintenance_under_traffic]},
        {s3, [], [maintenance_under_traffic]}
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started([barrel_xet, hackney]),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(fs, Config) ->
    [{backend, fs}, {blob, undefined} | Config];
init_per_group(s3, Config) ->
    {ok, Fake} = xet_fake_s3:start(),
    Endpoint = list_to_binary("http://127.0.0.1:" ++ integer_to_list(maps:get(port, Fake))),
    Blob =
        {s3, #{
            bucket => <<"soak">>,
            s3 => #{
                endpoint => Endpoint,
                region => <<"garage">>,
                access_key_id => <<"test">>,
                secret_access_key => <<"testsecret">>
            }
        }},
    [{backend, s3}, {fake, Fake}, {blob, Blob} | Config].

end_per_group(s3, Config) ->
    ok = xet_fake_s3:stop(proplists:get_value(fake, Config));
end_per_group(_Group, _Config) ->
    ok.

%% Start a server with observability, access log, timeouts, GC, and scrub
%% all on. Upload a baseline, then run scrub + GC + backup concurrently
%% with a background trickle of new uploads. Every file, baseline and
%% trickle, must still download byte-identical afterwards.
maintenance_under_traffic(Config) ->
    Name = list_to_atom("xet_soak_" ++ atom_to_list(proplists:get_value(backend, Config))),
    Priv = proplists:get_value(priv_dir, Config),
    DataDir = filename:join(Priv, atom_to_list(Name)),
    {ok, _} = xet_server:start(server_config(Name, DataDir, proplists:get_value(blob, Config))),
    try
        Base = list_to_binary(
            "http://127.0.0.1:" ++ integer_to_list(xet_server:port(Name))
        ),
        Client = xet_client:new(#{endpoint => Base, token => ?TOKEN}),
        Baseline = upload_batch(Client, 100, 16),
        assert_all_download(Client, Baseline),

        %% Background trickle: keep uploading while maintenance runs.
        Parent = self(),
        Trickle = spawn_link(fun() -> Parent ! {trickle, upload_batch(Client, 900, 8)} end),

        ScrubResult = run_scrub(Name),
        ?assertEqual(0, maps:get(corrupt, ScrubResult)),
        ?assertEqual(0, maps:get(read_errors, ScrubResult)),
        ?assert(maps:get(checked, ScrubResult) >= 1),

        %% Aged past the 1s grace, but everything is referenced, so a real
        %% sweep deletes nothing and finds no orphans.
        timer:sleep(1500),
        GcResult = run_gc(Name),
        ?assertEqual(0, maps:get(deleted_xorbs, GcResult)),
        ?assertEqual(0, maps:get(orphan_blobs, GcResult, 0)),

        assert_backup_reopens(Name, filename:join(Priv, atom_to_list(Name) ++ "_bak")),

        TrickleFiles =
            receive
                {trickle, Fs} -> Fs
            after 60000 -> error(trickle_timeout)
            end,
        unlink(Trickle),

        %% No data loss across the maintenance window.
        assert_all_download(Client, Baseline),
        assert_all_download(Client, TrickleFiles),

        {ok, 200, _, _} = hackney:request(
            get, <<Base/binary, "/healthz">>, [], <<>>, [with_body, {pool, false}]
        )
    after
        ok = xet_server:stop(Name)
    end.

server_config(Name, DataDir, Blob) ->
    Base = #{
        name => Name,
        data_dir => DataDir,
        observability => true,
        access_log => true,
        request_timeout => 30000,
        gc => #{grace_seconds => 1, interval => false},
        scrub => #{rate_bytes_per_sec => 1 bsl 40, interval => false},
        auth => {xet_auth_static, #{tokens => #{?TOKEN => write}}}
    },
    case Blob of
        undefined -> Base;
        _ -> Base#{blob => Blob}
    end.

%% Upload Count distinct files concurrently; return [{FileHash, Data}].
upload_batch(Client, Seed, Count) ->
    Parent = self(),
    Pids = [
        spawn(fun() ->
            Data = xet_test_vectors:splitmix64_data(120000 + (Seed + I) * 131, Seed + I),
            {ok, #{file_hash := H}} = xet_client_upload:upload_data(
                Client, {soak, Seed + I}, Data
            ),
            Parent ! {uploaded, self(), {H, Data}}
        end)
     || I <- lists:seq(1, Count)
    ],
    [
        receive
            {uploaded, Pid, Pair} -> Pair
        after 60000 -> error(upload_timeout)
        end
     || Pid <- Pids
    ].

assert_all_download(Client, Files) ->
    lists:foreach(
        fun({Hash, Data}) ->
            ?assertEqual({ok, Data}, xet_client_download:download_data(Client, Hash))
        end,
        Files
    ).

assert_backup_reopens(Name, BackupDir) ->
    #{metadata := Meta} = xet_server:env(Name),
    Target = filename:join(BackupDir, "metadata"),
    ok = filelib:ensure_path(BackupDir),
    ok = xet_metadata:checkpoint(Meta, Target),
    {ok, Copy} = xet_metadata:open(xet_metadata_rocksdb, #{dir => Target}),
    try
        ?assert(maps:get(files, xet_metadata:stats(Copy)) >= 16)
    after
        ok = xet_metadata:close(Copy)
    end.

run_scrub(Name) ->
    {ok, started} = xet_scrub:trigger(Name),
    wait_done(fun() -> xet_scrub:status(Name) end, 500).

run_gc(Name) ->
    {ok, started} = xet_gc:trigger(Name, #{}),
    wait_done(fun() -> xet_gc:status(Name) end, 500).

wait_done(_StatusFun, 0) ->
    error(maintenance_timeout);
wait_done(StatusFun, N) ->
    Status = StatusFun(),
    case maps:get(running, Status) of
        false ->
            maps:get(last, Status);
        true ->
            timer:sleep(20),
            wait_done(StatusFun, N - 1)
    end.
