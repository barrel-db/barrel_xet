%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Server configuration checks: each returns a list of readable errors
%% (empty when the setting is valid), so xet_config:load/1 can report every
%% problem at once instead of crashing on the first.
-module(xet_config_check).

-export([validate/1]).

validate(Config) ->
    lists:flatmap(fun(Check) -> Check(Config) end, [
        fun check_data_dir/1,
        fun check_auth/1,
        fun check_listeners/1,
        fun check_sizes/1,
        fun check_ratelimit/1,
        fun check_concurrency/1,
        fun check_request_timeout/1,
        fun check_security_headers/1,
        fun check_blob/1,
        fun check_admin/1,
        fun check_gc/1,
        fun check_scrub/1,
        fun check_backup_dir/1,
        fun check_metadata_opts/1,
        fun check_misc/1
    ]).

check_data_dir(#{data_dir := Dir}) when is_list(Dir), Dir =/= [] -> [];
check_data_dir(#{data_dir := Dir}) when is_binary(Dir), Dir =/= <<>> -> [];
check_data_dir(#{data_dir := _}) -> [<<"data_dir must be a non-empty path">>];
check_data_dir(_Config) -> [<<"data_dir is required">>].

check_auth(#{auth := {Mod, Opts}}) when is_atom(Mod) ->
    case verify_exported(Mod) of
        true -> check_auth_opts(Mod, Opts);
        false -> [format("auth module ~ts does not export verify/3", [Mod])]
    end;
check_auth(#{auth := _}) ->
    [<<"auth must be {Module, Opts}">>];
check_auth(_Config) ->
    [<<"auth is required">>].

verify_exported(Mod) ->
    case code:ensure_loaded(Mod) of
        {module, Mod} -> erlang:function_exported(Mod, verify, 3);
        _ -> false
    end.

check_auth_opts(xet_auth_static, #{tokens := Tokens}) when is_map(Tokens) ->
    lists:flatmap(fun check_token/1, maps:to_list(Tokens));
check_auth_opts(xet_auth_static, _Opts) ->
    [<<"xet_auth_static needs #{tokens => #{Token => read | write | admin}}">>];
%% Fail closed at boot: an unreadable or unparsable tokens file is a
%% config error, not a server that rejects everyone at runtime. Loading
%% here also publishes the token set, so the first request never pays
%% for it.
check_auth_opts(xet_auth_file, #{path := Path}) when is_list(Path); is_binary(Path) ->
    case xet_auth_file:load(Path) of
        {ok, 0} ->
            logger:warning("xet_server config: tokens file ~ts has no tokens", [Path]),
            [];
        {ok, _Count} ->
            [];
        {error, Reasons} ->
            Reasons
    end;
check_auth_opts(xet_auth_file, _Opts) ->
    [<<"xet_auth_file needs #{path => TokensFile}">>];
check_auth_opts(_Mod, _Opts) ->
    [].

check_token({Token, Scope}) ->
    token_error(Token) ++ scope_error(Scope).

token_error(<<>>) -> [<<"auth tokens must not be empty">>];
token_error(Token) when is_binary(Token) -> [];
token_error(Token) -> [format("auth token ~tp must be a binary", [Token])].

scope_error(read) -> [];
scope_error(write) -> [];
scope_error(admin) -> [];
scope_error(Scope) -> [format("auth scope ~tp is not read | write | admin", [Scope])].

check_listeners(Config) ->
    lists:flatmap(
        fun(Proto) -> check_listener(Proto, maps:get(Proto, Config, undefined)) end,
        [http, https, http3]
    ).

check_listener(_Proto, undefined) -> [];
check_listener(http, false) -> [];
check_listener(Proto, Listener) when is_map(Listener) -> check_port(Proto, Listener);
check_listener(Proto, _Other) -> [format("~ts listener must be a map", [Proto])].

check_port(Proto, Listener) ->
    case maps:get(port, Listener, 0) of
        Port when is_integer(Port), Port >= 0, Port =< 65535 -> [];
        Port -> [format("~ts port ~tp is not 0..65535", [Proto, Port])]
    end.

check_sizes(Config) ->
    Positive = [
        max_body,
        max_xorb_bytes,
        max_shard_bytes,
        url_ttl,
        key_rotation_interval,
        drain_timeout,
        backup_keep
    ],
    NonNeg = [spool_memory_max, min_free_bytes],
    lists:flatmap(fun(Key) -> check_pos(Key, maps:get(Key, Config, undefined)) end, Positive) ++
        lists:flatmap(fun(Key) -> check_non_neg(Key, maps:get(Key, Config, undefined)) end, NonNeg).

check_pos(_Key, undefined) -> [];
check_pos(_Key, N) when is_integer(N), N > 0 -> [];
check_pos(Key, V) -> [format("~ts must be a positive integer, got ~tp", [Key, V])].

check_non_neg(_Key, undefined) -> [];
check_non_neg(_Key, N) when is_integer(N), N >= 0 -> [];
check_non_neg(Key, V) -> [format("~ts must be a non-negative integer, got ~tp", [Key, V])].

check_ratelimit(Config) ->
    check_bucket(ratelimit, maps:get(ratelimit, Config, undefined)) ++
        check_bucket(data_ratelimit, maps:get(data_ratelimit, Config, undefined)).

check_bucket(_Key, undefined) ->
    [];
check_bucket(_Key, false) ->
    [];
check_bucket(_Key, #{capacity := C, per_second := R}) when
    is_integer(C), C > 0, is_number(R), R > 0
->
    [];
check_bucket(Key, _V) ->
    [format("~ts must be false or #{capacity => N, per_second => Rate}", [Key])].

check_concurrency(#{concurrency := false}) ->
    [];
check_concurrency(#{concurrency := Max}) when is_integer(Max), Max > 0 -> [];
check_concurrency(#{concurrency := V}) ->
    [format("concurrency must be false or a positive integer, got ~tp", [V])];
check_concurrency(_Config) ->
    [].

check_request_timeout(#{request_timeout := false}) ->
    [];
check_request_timeout(#{request_timeout := Ms}) when is_integer(Ms), Ms > 0 ->
    [];
check_request_timeout(#{request_timeout := V}) ->
    [format("request_timeout must be false or milliseconds, got ~tp", [V])];
check_request_timeout(_Config) ->
    [].

check_security_headers(#{security_headers := false}) ->
    [];
check_security_headers(#{security_headers := Opts}) when is_map(Opts) ->
    [];
check_security_headers(#{security_headers := V}) ->
    [format("security_headers must be false or an options map, got ~tp", [V])];
check_security_headers(_Config) ->
    [].

check_blob(#{blob := {fs, #{dir := Dir}}}) when is_list(Dir); is_binary(Dir) -> [];
check_blob(#{blob := {s3, Opts}}) when is_map(Opts) -> [];
check_blob(#{blob := _}) -> [<<"blob must be {fs, #{dir => Path}} or {s3, Opts}">>];
check_blob(_Config) -> [].

check_admin(#{admin := false}) -> [];
check_admin(#{admin := #{enabled := E}}) when is_boolean(E) -> [];
check_admin(#{admin := #{} = M}) when map_size(M) =:= 0 -> [];
check_admin(#{admin := _}) -> [<<"admin must be false or #{enabled => boolean()}">>];
check_admin(_Config) -> [].

check_gc(#{gc := #{} = Gc}) ->
    check_pos(<<"gc grace_seconds">>, maps:get(grace_seconds, Gc, 1)) ++
        check_interval(<<"gc">>, maps:get(interval, Gc, false));
check_gc(#{gc := _}) ->
    [<<"gc must be a map, e.g. #{grace_seconds => 86400, interval => false}">>];
check_gc(_Config) ->
    [].

check_scrub(#{scrub := #{} = Scrub}) ->
    check_pos(<<"scrub rate_bytes_per_sec">>, maps:get(rate_bytes_per_sec, Scrub, 1)) ++
        check_interval(<<"scrub">>, maps:get(interval, Scrub, false));
check_scrub(#{scrub := _}) ->
    [<<"scrub must be a map, e.g. #{rate_bytes_per_sec => 33554432, interval => false}">>];
check_scrub(_Config) ->
    [].

check_backup_dir(#{backup_dir := Dir}) when is_list(Dir), Dir =/= [] -> [];
check_backup_dir(#{backup_dir := Dir}) when is_binary(Dir), Dir =/= <<>> -> [];
check_backup_dir(#{backup_dir := _}) -> [<<"backup_dir must be a non-empty path">>];
check_backup_dir(_Config) -> [].

check_metadata_opts(#{metadata_opts := M}) when is_map(M) -> [];
check_metadata_opts(#{metadata_opts := _}) -> [<<"metadata_opts must be a map">>];
check_metadata_opts(_Config) -> [].

check_interval(_Label, false) ->
    [];
check_interval(_Label, N) when is_integer(N), N > 0 -> [];
check_interval(Label, V) ->
    [format("~ts interval must be false or a positive integer, got ~tp", [Label, V])].

check_misc(Config) ->
    check_name(maps:get(name, Config, undefined)) ++
        check_secret(maps:get(url_secret, Config, undefined)) ++
        check_namespaces(maps:get(namespaces, Config, undefined)) ++
        check_flag(observability, maps:get(observability, Config, undefined)) ++
        check_flag(metrics, maps:get(metrics, Config, undefined)) ++
        check_flag(access_log, maps:get(access_log, Config, undefined)).

check_name(undefined) -> [];
check_name(Name) when is_atom(Name) -> [];
check_name(V) -> [format("name must be an atom, got ~tp", [V])].

check_secret(undefined) -> [];
check_secret(Secret) when is_binary(Secret) -> [];
check_secret(_V) -> [<<"url_secret must be a binary">>].

check_namespaces(undefined) ->
    [];
check_namespaces(Namespaces) when is_list(Namespaces), Namespaces =/= [] ->
    case lists:all(fun(Ns) -> is_binary(Ns) andalso Ns =/= <<>> end, Namespaces) of
        true -> [];
        false -> [<<"namespaces must be non-empty binaries">>]
    end;
check_namespaces(_V) ->
    [<<"namespaces must be a non-empty list of binaries">>].

check_flag(_Key, undefined) -> [];
check_flag(_Key, Flag) when is_boolean(Flag) -> [];
check_flag(Key, V) -> [format("~ts must be a boolean, got ~tp", [Key, V])].

format(Fmt, Args) ->
    iolist_to_binary(io_lib:format(Fmt, Args)).
