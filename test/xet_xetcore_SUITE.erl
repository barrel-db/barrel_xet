%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Shards written by barrel_xet, read back through xet-core's own shard
%% reader (test/xetcore, on the published xet-core-structures crate). Its
%% lookups seek through the footer's lookup tables, so this checks their
%% index semantics against the reference, with several files and CAS
%% blocks (with a single block both readings of the index give 0).
%% Skipped when cargo is not installed.
-module(xet_xetcore_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([stored_shard_lookups/1, dedup_shard_lookups/1]).

-define(TOKEN, <<"xetcore-token">>).

all() ->
    [stored_shard_lookups, dedup_shard_lookups].

init_per_suite(Config) ->
    case os:find_executable("cargo") of
        false -> {skip, "cargo not available for the xet-core harness"};
        Cargo -> [{harness, build_harness(Cargo)} | Config]
    end.

end_per_suite(_Config) ->
    ok.

build_harness(Cargo) ->
    Dir = filename:join([project_root(), "test", "xetcore"]),
    Cmd = Cargo ++ " build --release --quiet --manifest-path " ++ filename:join(Dir, "Cargo.toml"),
    Out = os:cmd(Cmd ++ " 2>&1; echo EXIT:$?"),
    ?assertMatch({match, _}, re:run(Out, "EXIT:0"), Out),
    filename:join([Dir, "target", "release", "xetcore-check"]).

%% Three files (with and without verification and metadata ext) over
%% three CAS blocks of 2, 3 and 1 chunks: every file, xorb and chunk
%% must resolve to the right entry.
stored_shard_lookups(Config) ->
    [X1, X2, X3] = Xorbs = [rand_hash() || _ <- lists:seq(1, 3)],
    Cas = [cas_block(X, N) || {X, N} <- lists:zip(Xorbs, [2, 3, 1])],
    Files = [
        file(rand_hash(), [term(X1, 0, 2), term(X2, 1, 3)], #{verification => 2, sha256 => true}),
        file(rand_hash(), [term(X3, 0, 1)], #{}),
        file(rand_hash(), [term(X2, 0, 3)], #{verification => 1})
    ],
    Path = write_shard(Config, "stored.shard", #{files => Files, cas => Cas}, xet_hash:zero_hash()),
    lists:foreach(fun(F) -> assert_file(Config, Path, F) end, Files),
    lists:foreach(fun(B) -> assert_xorb(Config, Path, B) end, Cas),
    lists:foreach(fun(B) -> assert_chunks(Config, Path, B) end, Cas).

%% The keyed dedup shard served by GET /v1/chunks, read by xet-core with
%% the unkeyed chunk hash, finds the uploaded xorb at chunk 0.
dedup_shard_lookups(Config) ->
    {ok, _} = application:ensure_all_started([barrel_xet, hackney]),
    {ok, _} = xet_server:start(#{
        name => xet_xetcore_server,
        data_dir => filename:join(proplists:get_value(priv_dir, Config), "server"),
        auth => {xet_auth_static, #{tokens => #{?TOKEN => write}}}
    }),
    try
        Base = "http://127.0.0.1:" ++ integer_to_list(xet_server:port(xet_xetcore_server)),
        Client = xet_client:new(#{endpoint => list_to_binary(Base), token => ?TOKEN}),
        Data = xet_test_vectors:splitmix64_data(400000, 42),
        {ok, #{file_hash := FileHash}} = xet_client_upload:upload_data(Client, f, Data),
        First = xet_hash:chunk_hash(hd(xet_chunker:split(Data))),
        {ok, #{terms := [#{cas_hash := Xorb} | _]}} =
            xet_metadata:get_file(maps:get(metadata, xet_server:env(xet_xetcore_server)), FileHash),
        Path = filename:join(proplists:get_value(priv_dir, Config), "dedup.shard"),
        ok = file:write_file(Path, fetch_dedup_shard(Base, First)),
        [Answer] = query(Config, Path, ["chunk:" ++ hex(First)]),
        ?assertMatch(#{<<"xorb">> := _, <<"start">> := 0}, Answer),
        ?assertEqual(xet_hash:to_string(Xorb), maps:get(<<"xorb">>, Answer))
    after
        ok = xet_server:stop(xet_xetcore_server)
    end.

fetch_dedup_shard(Base, ChunkHash) ->
    Url = Base ++ "/api/v1/chunks/default/" ++ hex(ChunkHash),
    Auth = [{<<"authorization">>, <<"Bearer ", ?TOKEN/binary>>}],
    {ok, 200, _, Body} = hackney:request(get, Url, Auth, <<>>, [with_body]),
    Body.

%%--------------------------------------------------------------------
%% Assertions
%%--------------------------------------------------------------------

assert_file(Config, Path, #{file_hash := Hash, terms := Terms}) ->
    [Answer] = query(Config, Path, ["file:" ++ hex(Hash)]),
    Expected = [
        [xet_hash:to_string(X), S, E, Len]
     || #{cas_hash := X, chunk_start := S, chunk_end := E, unpacked_len := Len} <- Terms
    ],
    ?assertEqual(Expected, maps:get(<<"terms">>, Answer)).

assert_xorb(Config, Path, #{cas_hash := Hash, chunks := Chunks}) ->
    [Answer] = query(Config, Path, ["xorb:" ++ hex(Hash)]),
    ?assertEqual(xet_hash:to_string(Hash), maps:get(<<"found">>, Answer)),
    ?assertEqual(length(Chunks), maps:get(<<"chunks">>, Answer)).

assert_chunks(Config, Path, #{cas_hash := Xorb, chunks := Chunks}) ->
    Indexed = lists:zip(lists:seq(0, length(Chunks) - 1), Chunks),
    Answers = query(Config, Path, ["chunk:" ++ hex(H) || #{hash := H} <- Chunks]),
    lists:foreach(
        fun({{I, _}, Answer}) ->
            ?assertEqual(
                {xet_hash:to_string(Xorb), I, I + 1},
                {
                    maps:get(<<"xorb">>, Answer),
                    maps:get(<<"start">>, Answer),
                    maps:get(<<"end">>, Answer)
                }
            )
        end,
        lists:zip(Indexed, Answers)
    ).

query(Config, Path, Queries) ->
    Cmd = string:join([proplists:get_value(harness, Config), Path | Queries], " "),
    Out = os:cmd(Cmd),
    [json:decode(list_to_binary(L)) || L <- string:lexemes(Out, "\n")].

%%--------------------------------------------------------------------
%% Shard building
%%--------------------------------------------------------------------

write_shard(Config, Name, Shard, Key) ->
    Bin = xet_shard:encode_stored(Shard, #{chunk_hash_key => Key, created_at => 1, key_expiry => 0}),
    {ok, _} = xet_shard:decode(Bin),
    Path = filename:join(proplists:get_value(priv_dir, Config), Name),
    ok = file:write_file(Path, Bin),
    Path.

cas_block(Xorb, N) ->
    #{
        cas_hash => Xorb,
        bytes_on_disk => 100 * N,
        chunks => [
            #{hash => rand_hash(), size => 1000 + I, dedup_eligible => false}
         || I <- lists:seq(1, N)
        ]
    }.

term(Xorb, Start, End) ->
    #{
        cas_hash => Xorb,
        chunk_start => Start,
        chunk_end => End,
        unpacked_len => 1000 * (End - Start)
    }.

file(Hash, Terms, Opts) ->
    Base = #{file_hash => Hash, terms => Terms},
    WithVer =
        case maps:get(verification, Opts, 0) of
            0 -> Base;
            N -> Base#{verification => [rand_hash() || _ <- lists:seq(1, N)]}
        end,
    case maps:get(sha256, Opts, false) of
        true -> WithVer#{sha256 => rand_hash()};
        false -> WithVer
    end.

rand_hash() -> crypto:strong_rand_bytes(32).

hex(Hash) -> binary_to_list(xet_hash:to_string(Hash)).

project_root() ->
    from_dir(filename:dirname(code:which(?MODULE))).

from_dir(Dir) ->
    case filelib:is_regular(filename:join(Dir, "rebar.config")) of
        true -> Dir;
        false -> from_dir(filename:dirname(Dir))
    end.
