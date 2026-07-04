%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Cross-implementation e2e and durability.
%%
%% The python cases drive the draft's Python reference client against our
%% server (blake3 + lz4 + requests required; skipped otherwise). The
%% restart case proves durability and always runs.
-module(xet_crossimpl_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2]).
-export([
    python_uploads_we_download/1,
    we_upload_python_downloads/1,
    restart_preserves_files/1
]).

-define(TOKEN, <<"cross-token">>).

all() ->
    [
        python_uploads_we_download,
        we_upload_python_downloads,
        restart_preserves_files
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started([barrel_xet, hackney]),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(Case, Config) when
    Case =:= python_uploads_we_download; Case =:= we_upload_python_downloads
->
    case python_ready() of
        true -> start_server(Case, Config);
        false -> {skip, "python3 with blake3/lz4/requests not available"}
    end;
init_per_testcase(Case, Config) ->
    start_server(Case, Config).

start_server(Case, Config) ->
    Name = list_to_atom("xet_cross_" ++ atom_to_list(Case)),
    DataDir = filename:join(proplists:get_value(priv_dir, Config), atom_to_list(Case)),
    {ok, _} = xet_server:start(#{
        name => Name,
        data_dir => DataDir,
        %% Stable secret so signed URLs survive a restart within a case.
        url_secret => crypto:strong_rand_bytes(32),
        auth => {xet_auth_static, #{tokens => #{?TOKEN => write}}}
    }),
    [{server, Name}, {data_dir, DataDir} | Config].

server(Config) -> proplists:get_value(server, Config).

endpoint(Config) ->
    "http://127.0.0.1:" ++ integer_to_list(xet_server:port(server(Config))).

client(Config) ->
    xet_client:new(#{endpoint => list_to_binary(endpoint(Config)), token => ?TOKEN}).

%% Python uploads a file; our client downloads it byte-identical, and the
%% file hash the two implementations agree on matches.
python_uploads_we_download(Config) ->
    Data = xet_test_vectors:splitmix64_data(500000, 3),
    In = write_temp(Config, "py_in.bin", Data),
    HashOut = temp(Config, "py_hash.txt"),
    ?assertEqual(0, run_python(Config, ["upload", In, HashOut])),
    {ok, HashStr} = file:read_file(HashOut),
    FileHash = xet_hash:from_string(strip(HashStr)),
    %% Both implementations derive the same file hash.
    ?assertEqual(xet_hash:file_hash(entries(Data)), FileHash),
    ?assertEqual({ok, Data}, xet_client_download:download_data(client(Config), FileHash)).

%% Our client uploads; the Python reference downloads it byte-identical.
we_upload_python_downloads(Config) ->
    Data = xet_test_vectors:splitmix64_data(450000, 4),
    {ok, #{file_hash := FileHash}} = xet_client_upload:upload_data(client(Config), f, Data),
    HashStr = binary_to_list(xet_hash:to_string(FileHash)),
    Out = temp(Config, "py_out.bin"),
    ?assertEqual(0, run_python(Config, ["download", HashStr, Out])),
    ?assertEqual({ok, Data}, file:read_file(Out)).

%% Upload files, kill the server node process tree, restart on the same
%% data dir, and reconstruct: rocksdb + blob durability.
restart_preserves_files(Config) ->
    Client1 = client(Config),
    Files = [
        {a, xet_test_vectors:splitmix64_data(300000, 10)},
        {b, xet_test_vectors:splitmix64_data(120000, 11)}
    ],
    Hashes = [
        begin
            {ok, #{file_hash := H}} = xet_client_upload:upload_data(Client1, Id, Data),
            {H, Data}
        end
     || {Id, Data} <- Files
    ],
    %% Hard stop and restart on the same data dir.
    ok = xet_server:stop(server(Config)),
    Name = server(Config),
    {ok, _} = xet_server:start(#{
        name => Name,
        data_dir => proplists:get_value(data_dir, Config),
        auth => {xet_auth_static, #{tokens => #{?TOKEN => write}}}
    }),
    Client2 = client(Config),
    lists:foreach(
        fun({Hash, Data}) ->
            ?assertEqual({ok, Data}, xet_client_download:download_data(Client2, Hash))
        end,
        Hashes
    ),
    ok = xet_server:stop(Name).

%%--------------------------------------------------------------------

python_ready() ->
    case os:find_executable("python3") of
        false ->
            false;
        Py ->
            Cmd = Py ++ " -c \"import blake3, lz4.frame, requests\" 2>/dev/null; echo $?",
            string:trim(os:cmd(Cmd)) =:= "0"
    end.

run_python(Config, Args) ->
    Script = filename:join([project_root(), "test", "python", "xet_interop_driver.py"]),
    Full = string:join(
        ["python3", Script, hd(Args), endpoint(Config), binary_to_list(?TOKEN)] ++ tl(Args),
        " "
    ),
    Output = os:cmd(Full ++ "; echo EXIT:$?"),
    parse_exit(Output).

%% The driver lives in the source tree, not the build output.
project_root() ->
    from_dir(filename:dirname(code:which(?MODULE))).

from_dir(Dir) ->
    case filelib:is_regular(filename:join(Dir, "rebar.config")) of
        true ->
            Dir;
        false ->
            Parent = filename:dirname(Dir),
            case Parent of
                Dir -> error(no_project_root);
                _ -> from_dir(Parent)
            end
    end.

parse_exit(Output) ->
    case re:run(Output, "EXIT:([0-9]+)", [{capture, [1], list}]) of
        {match, [Code]} ->
            list_to_integer(Code);
        nomatch ->
            ct:pal("python output: ~s", [Output]),
            -1
    end.

write_temp(Config, Name, Data) ->
    Path = temp(Config, Name),
    ok = file:write_file(Path, Data),
    Path.

temp(Config, Name) ->
    filename:join(proplists:get_value(priv_dir, Config), Name).

strip(Bin) ->
    hd(binary:split(Bin, [<<"\n">>, <<"\r">>, <<" ">>], [global, trim_all])).

entries(Data) ->
    [{xet_hash:chunk_hash(C), byte_size(C)} || C <- xet_chunker:split(Data)].
