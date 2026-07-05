%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(xet_auth_file_tests).

-include_lib("eunit/include/eunit.hrl").

with_file(Content, Fun) ->
    Path = filename:join(
        os:getenv("TMPDIR", "/tmp"),
        "xet_auth_file_" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = file:write_file(Path, Content),
    try
        Fun(Path)
    after
        file:delete(Path)
    end.

verify(Token, Scope, Path) ->
    xet_auth_file:verify(Token, Scope, #{path => Path}).

load_and_verify_test() ->
    with_file(
        <<
            "# operator tokens\n"
            "reader-token read\n"
            "writer-token write\n"
            "\n"
            "root-token admin\n"
        >>,
        fun(Path) ->
            ?assertEqual({ok, 3}, xet_auth_file:load(Path)),
            ?assertEqual({ok, read}, verify(<<"reader-token">>, read, Path)),
            ?assertEqual({error, forbidden}, verify(<<"reader-token">>, write, Path)),
            ?assertEqual({ok, write}, verify(<<"writer-token">>, read, Path)),
            ?assertEqual({ok, write}, verify(<<"writer-token">>, write, Path)),
            ?assertEqual({error, forbidden}, verify(<<"writer-token">>, admin, Path)),
            ?assertEqual({ok, admin}, verify(<<"root-token">>, admin, Path)),
            ?assertEqual({ok, admin}, verify(<<"root-token">>, write, Path)),
            ?assertEqual({error, unauthorized}, verify(<<"nope">>, read, Path)),
            ?assertEqual({error, unauthorized}, verify(undefined, read, Path))
        end
    ).

lazy_load_on_first_verify_test() ->
    %% No explicit load: the first verify loads the file itself.
    with_file(<<"lazy-token read\n">>, fun(Path) ->
        ?assertEqual({ok, read}, verify(<<"lazy-token">>, read, Path))
    end).

duplicate_token_test() ->
    with_file(<<"same read\nsame write\n">>, fun(Path) ->
        ?assertEqual({error, [<<"line 2: duplicate token">>]}, xet_auth_file:load(Path))
    end).

bad_line_test() ->
    with_file(<<"justatoken\n">>, fun(Path) ->
        {error, [Error]} = xet_auth_file:load(Path),
        ?assertEqual(<<"line 1: expected \"token scope\"">>, Error)
    end).

bad_scope_test() ->
    with_file(<<"t root\n">>, fun(Path) ->
        {error, [Error]} = xet_auth_file:load(Path),
        ?assertEqual(<<"line 1: scope root is not read, write or admin">>, Error)
    end).

missing_file_test() ->
    {error, [Error]} = xet_auth_file:load("/nonexistent/xet-tokens"),
    ?assertNotEqual(nomatch, binary:match(Error, <<"enoent">>)).

empty_file_fails_closed_test() ->
    with_file(<<"# nothing yet\n">>, fun(Path) ->
        ?assertEqual({ok, 0}, xet_auth_file:load(Path)),
        ?assertEqual({error, unauthorized}, verify(<<"any">>, read, Path))
    end).

reload_keeps_old_set_on_parse_error_test() ->
    with_file(<<"stable-token write\n">>, fun(Path) ->
        ?assertEqual({ok, 1}, xet_auth_file:load(Path)),
        ok = file:write_file(Path, <<"garbage line without scope\n">>),
        {error, [_Reason]} = xet_auth_file:reload(Path),
        %% The pre-reload token set still authenticates.
        ?assertEqual({ok, write}, verify(<<"stable-token">>, write, Path))
    end).

reload_all_test() ->
    %% Drop registrations left by the earlier cases (their temp files are
    %% deleted, so reload/0 would report them).
    persistent_term:erase({xet_auth_file, registry}),
    with_file(<<"a read\n">>, fun(Path) ->
        ?assertEqual({ok, 1}, xet_auth_file:load(Path)),
        ok = file:write_file(Path, <<"a read\nb write\n">>),
        ?assertEqual(ok, xet_auth_file:reload()),
        ?assertEqual({ok, write}, verify(<<"b">>, write, Path))
    end).
