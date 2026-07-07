%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Garbage collection: unreferenced xorbs older than the grace window are
%% swept from metadata and blob storage; referenced or young xorbs are
%% kept; dry runs report without deleting; and a registration racing a
%% sweep never leaves a file pointing at a deleted xorb.
-module(xet_gc_SUITE).

-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_testcase/2, end_per_testcase/2]).
-export([
    collects_unreferenced_aged/1,
    referenced_survives/1,
    grace_protects_young/1,
    delete_file_then_gc/1,
    dry_run_reports_without_deleting/1,
    registration_race_keeps_files_consistent/1
]).

-define(GRACE, 100).

all() ->
    [
        collects_unreferenced_aged,
        referenced_survives,
        grace_protects_young,
        delete_file_then_gc,
        dry_run_reports_without_deleting,
        registration_race_keeps_files_consistent
    ].

init_per_testcase(Case, Config) ->
    {ok, _} = application:ensure_all_started([barrel_xet]),
    Name = list_to_atom("xet_gc_" ++ atom_to_list(Case)),
    DataDir = filename:join(proplists:get_value(priv_dir, Config), atom_to_list(Case)),
    {ok, _} = xet_server:start(#{
        name => Name,
        data_dir => DataDir,
        gc => #{grace_seconds => ?GRACE, interval => false},
        auth => {xet_auth_static, #{tokens => #{}}}
    }),
    [{name, Name} | Config].

end_per_testcase(_Case, Config) ->
    ok = xet_server:stop(proplists:get_value(name, Config)).

env(Config) -> xet_server:env(proplists:get_value(name, Config)).

%% Register a xorb with a real blob and a chosen created_at.
put_xorb(Config, N, CreatedAt) ->
    #{blob := Blob, metadata := Meta} = env(Config),
    Hash = <<N:256>>,
    ok = xet_blob_store:put(Blob, <<"default">>, Hash, binary:copy(<<"z">>, 100)),
    ok = xet_metadata:register_xorb(Meta, #{
        hash => Hash,
        ns => <<"default">>,
        entries => [{<<(N + 1):256>>, 100}],
        boundary_offsets => [100],
        unpacked_offsets => [100],
        bytes_on_disk => 100,
        created_at => CreatedAt
    }),
    Hash.

register_ref(Config, FileN, XorbHash) ->
    #{metadata := Meta} = env(Config),
    ok = xet_metadata:register_files(
        Meta,
        [
            #{
                file_hash => <<FileN:256>>,
                total_len => 100,
                terms => [
                    #{cas_hash => XorbHash, unpacked_len => 100, chunk_start => 0, chunk_end => 1}
                ]
            }
        ],
        []
    ).

exists(Config, Hash) ->
    #{blob := Blob, metadata := Meta} = env(Config),
    {xet_metadata:xorb_exists(Meta, Hash), xet_blob_store:exists(Blob, <<"default">>, Hash)}.

old() -> erlang:system_time(second) - 10 * ?GRACE.
now_s() -> erlang:system_time(second).

run_gc(Config, Opts) ->
    Name = proplists:get_value(name, Config),
    {ok, started} = xet_gc:trigger(Name, Opts),
    wait_result(Name, 200).

wait_result(_Name, 0) ->
    error(gc_timeout);
wait_result(Name, N) ->
    Status = xet_gc:status(Name),
    case maps:get(running, Status) of
        false ->
            maps:get(last, Status);
        true ->
            timer:sleep(20),
            wait_result(Name, N - 1)
    end.

collects_unreferenced_aged(Config) ->
    Hash = put_xorb(Config, 1, old()),
    ?assertEqual({true, true}, exists(Config, Hash)),
    Result = run_gc(Config, #{}),
    ?assertEqual(1, maps:get(deleted_xorbs, Result)),
    ?assertEqual(100, maps:get(deleted_bytes, Result)),
    ?assertEqual({false, false}, exists(Config, Hash)).

referenced_survives(Config) ->
    Hash = put_xorb(Config, 1, old()),
    ok = register_ref(Config, 500, Hash),
    _ = run_gc(Config, #{}),
    ?assertEqual({true, true}, exists(Config, Hash)).

grace_protects_young(Config) ->
    Hash = put_xorb(Config, 1, now_s()),
    Result = run_gc(Config, #{}),
    ?assertEqual(0, maps:get(deleted_xorbs, Result)),
    ?assertEqual({true, true}, exists(Config, Hash)).

delete_file_then_gc(Config) ->
    Hash = put_xorb(Config, 1, old()),
    ok = register_ref(Config, 500, Hash),
    %% Referenced: survives.
    _ = run_gc(Config, #{}),
    ?assertEqual({true, true}, exists(Config, Hash)),
    %% Delete the only referencing file, then collect.
    #{metadata := Meta} = env(Config),
    ok = xet_metadata:delete_file(Meta, <<500:256>>),
    _ = run_gc(Config, #{}),
    ?assertEqual({false, false}, exists(Config, Hash)).

dry_run_reports_without_deleting(Config) ->
    Hash = put_xorb(Config, 1, old()),
    Result = run_gc(Config, #{dry_run => true}),
    ?assertEqual(true, maps:get(dry_run, Result)),
    ?assertEqual(1, maps:get(candidates, Result)),
    ?assertEqual(1, maps:get(deleted_xorbs, Result)),
    %% Nothing actually removed.
    ?assertEqual({true, true}, exists(Config, Hash)).

%% A registration that references a collectable xorb concurrently with a
%% sweep must never leave a file pointing at a deleted xorb: either the
%% registration wins (xorb kept, file valid) or the sweep wins (xorb
%% gone, and no file references it).
registration_race_keeps_files_consistent(Config) ->
    #{metadata := Meta} = env(Config),
    Hashes = [put_xorb(Config, N, old()) || N <- lists:seq(1, 50)],
    Target = lists:nth(25, Hashes),
    Parent = self(),
    %% Concurrently: register a file referencing Target through the guard.
    spawn(fun() ->
        Ok = xet_gc_guard:in_registration(fun() ->
            case xet_metadata:xorb_exists(Meta, Target) of
                true ->
                    ok = register_ref(Config, 900, Target),
                    xet_gc_guard:note_referenced([Target]),
                    referenced;
                false ->
                    missing
            end
        end),
        Parent ! {reg, Ok}
    end),
    _ = run_gc(Config, #{}),
    Outcome =
        receive
            {reg, O} -> O
        after 5000 -> error(no_reg)
        end,
    case Outcome of
        referenced ->
            %% File committed: its xorb must still be present.
            ?assert(xet_metadata:file_exists(Meta, <<900:256>>)),
            ?assertEqual({true, true}, exists(Config, Target));
        missing ->
            %% Sweep won first: no file was registered.
            ?assertNot(xet_metadata:file_exists(Meta, <<900:256>>))
    end.
