-module(xet_cli_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([up_download_roundtrip/1, info_present_absent/1, usage_and_bad_args/1]).

-define(TOKEN, <<"cli-token">>).

all() ->
    [up_download_roundtrip, info_present_absent, usage_and_bad_args].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started([barrel_xet, hackney]),
    DataDir = filename:join(proplists:get_value(priv_dir, Config), "clisrv"),
    {ok, _} = xet_server:start(#{
        name => xet_cli_server,
        data_dir => DataDir,
        auth => {xet_auth_static, #{tokens => #{?TOKEN => write}}}
    }),
    Endpoint = "http://127.0.0.1:" ++ integer_to_list(xet_server:port(xet_cli_server)),
    os:putenv("XET_ENDPOINT", Endpoint),
    os:putenv("XET_TOKEN", binary_to_list(?TOKEN)),
    Config.

end_per_suite(_Config) ->
    os:unsetenv("XET_ENDPOINT"),
    os:unsetenv("XET_TOKEN"),
    ok = xet_server:stop(xet_cli_server),
    ok.

up_download_roundtrip(Config) ->
    Priv = proplists:get_value(priv_dir, Config),
    In = filename:join(Priv, "input.bin"),
    Out = filename:join(Priv, "output.bin"),
    Data = xet_test_vectors:splitmix64_data(250000, 7),
    ok = file:write_file(In, Data),
    ?assertEqual(0, xet_cli:run(["up", In])),
    HashStr = binary_to_list(xet_hash:to_string(xet_hash:file_hash(entries(Data)))),
    ?assertEqual(0, xet_cli:run(["download", HashStr, Out])),
    ?assertEqual({ok, Data}, file:read_file(Out)).

info_present_absent(Config) ->
    Priv = proplists:get_value(priv_dir, Config),
    In = filename:join(Priv, "info.bin"),
    Data = xet_test_vectors:splitmix64_data(9000, 8),
    ok = file:write_file(In, Data),
    HashStr = binary_to_list(xet_hash:to_string(xet_hash:file_hash(entries(Data)))),
    %% Absent before upload -> exit code 1.
    ?assertEqual(1, xet_cli:run(["info", HashStr])),
    ?assertEqual(0, xet_cli:run(["up", In])),
    %% Present after -> exit code 0.
    ?assertEqual(0, xet_cli:run(["info", HashStr])).

usage_and_bad_args(_Config) ->
    ?assertEqual(2, xet_cli:run(["bogus"])),
    ?assertEqual(2, xet_cli:run([])),
    ?assertEqual(1, xet_cli:run(["info", "not-a-hash"])),
    ?assertEqual(1, xet_cli:run(["download", "nothex", "/tmp/xet_cli_ignored"])).

entries(Data) ->
    [{xet_hash:chunk_hash(C), byte_size(C)} || C <- xet_chunker:split(Data)].
