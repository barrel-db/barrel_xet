%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% File-backed bearer tokens: #{path => TokensFile}. The file holds one
%% "token scope" pair per line (scope is read, write or admin), full-line
%% # comments and blank lines allowed. Tokens are held in memory as
%% SHA-256 digests only, published via persistent_term; verification is
%% constant-time like xet_auth_static.
%%
%% Operations: edit the file, then run
%%   bin/barrel_xet eval 'xet_auth_file:reload().'
%% A reload that fails to parse keeps the previously loaded tokens.
-module(xet_auth_file).

-behaviour(xet_auth).

-export([verify/3, load/1, reload/0, reload/1]).

-define(REGISTRY, {?MODULE, registry}).

verify(undefined, _Scope, _Opts) ->
    {error, unauthorized};
verify(Token, Scope, #{path := Path}) ->
    case entries(absname(Path)) of
        {ok, Entries} ->
            Digest = crypto:hash(sha256, Token),
            case find_token(Entries, Digest) of
                {ok, Held} -> check_scope(Held, Scope);
                error -> {error, unauthorized}
            end;
        error ->
            %% Fail closed: no loaded token set authenticates nobody.
            {error, unauthorized}
    end.

%% Parse Path and publish its token set. Called by xet_config at boot
%% (fail closed on a bad file) and by reload/1.
-spec load(file:name_all()) -> {ok, non_neg_integer()} | {error, [binary()]}.
load(Path) ->
    AbsPath = absname(Path),
    case file:read_file(AbsPath) of
        {ok, Bin} ->
            case parse(Bin) of
                {ok, Entries} ->
                    publish(AbsPath, Entries),
                    {ok, length(Entries)};
                {error, _Reasons} = Error ->
                    Error
            end;
        {error, Reason} ->
            {error, [format("tokens file ~ts: ~tp", [AbsPath, Reason])]}
    end.

%% Re-read every loaded tokens file. A file that fails keeps its old
%% token set; the error is returned so the eval caller sees it.
-spec reload() -> ok | {error, [binary()]}.
reload() ->
    Errors = lists:flatmap(
        fun(Path) ->
            case load(Path) of
                {ok, _Count} -> [];
                {error, Reasons} -> Reasons
            end
        end,
        maps:keys(registry())
    ),
    case Errors of
        [] -> ok;
        _ -> {error, Errors}
    end.

-spec reload(file:name_all()) -> {ok, non_neg_integer()} | {error, [binary()]}.
reload(Path) ->
    load(Path).

%%--------------------------------------------------------------------

registry() ->
    persistent_term:get(?REGISTRY, #{}).

publish(AbsPath, Entries) ->
    persistent_term:put(?REGISTRY, maps:put(AbsPath, Entries, registry())).

entries(AbsPath) ->
    case maps:find(AbsPath, registry()) of
        {ok, Entries} ->
            {ok, Entries};
        error ->
            %% Not loaded yet (embedded use without xet_config): one
            %% lazy attempt, then fail closed.
            case load(AbsPath) of
                {ok, _Count} -> maps:find(AbsPath, registry());
                {error, _} -> error
            end
    end.

absname(Path) ->
    filename:absname(unicode_list(Path)).

unicode_list(Path) when is_binary(Path) -> unicode:characters_to_list(Path);
unicode_list(Path) -> Path.

find_token([], _Digest) ->
    error;
find_token([{TokenDigest, Scope} | Rest], Digest) ->
    case crypto:hash_equals(TokenDigest, Digest) of
        true -> {ok, Scope};
        false -> find_token(Rest, Digest)
    end.

check_scope(Held, Required) ->
    case xet_auth:scope_covers(Held, Required) of
        true -> {ok, Held};
        false -> {error, forbidden}
    end.

%%--------------------------------------------------------------------

parse(Bin) ->
    Lines = binary:split(Bin, [<<"\n">>, <<"\r\n">>], [global]),
    parse_lines(Lines, 1, #{}, []).

parse_lines([], _LineNo, _Seen, Acc) ->
    {ok, lists:reverse(Acc)};
parse_lines([Line | Rest], LineNo, Seen, Acc) ->
    case parse_line(string:trim(Line)) of
        skip ->
            parse_lines(Rest, LineNo + 1, Seen, Acc);
        {ok, Token, Scope} when not is_map_key(Token, Seen) ->
            Entry = {crypto:hash(sha256, Token), Scope},
            parse_lines(Rest, LineNo + 1, Seen#{Token => true}, [Entry | Acc]);
        {ok, _Duplicate, _Scope} ->
            {error, [format("line ~b: duplicate token", [LineNo])]};
        {error, Reason} ->
            {error, [format("line ~b: ~ts", [LineNo, Reason])]}
    end.

parse_line(<<>>) ->
    skip;
parse_line(<<"#", _/binary>>) ->
    skip;
parse_line(Line) ->
    case binary:split(Line, [<<" ">>, <<"\t">>], [global, trim_all]) of
        [Token, ScopeBin] -> with_scope(Token, ScopeBin);
        _ -> {error, <<"expected \"token scope\"">>}
    end.

with_scope(Token, ScopeBin) ->
    case scope(ScopeBin) of
        {ok, Scope} -> {ok, Token, Scope};
        error -> {error, format("scope ~ts is not read, write or admin", [ScopeBin])}
    end.

scope(<<"read">>) -> {ok, read};
scope(<<"write">>) -> {ok, write};
scope(<<"admin">>) -> {ok, admin};
scope(_) -> error.

format(Fmt, Args) ->
    iolist_to_binary(io_lib:format(Fmt, Args)).
