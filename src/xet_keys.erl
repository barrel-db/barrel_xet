%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Dedup key ring owner: keeps the chunk_hash_key used to protect global
%% dedup responses (spec 10.3.3), rotates it on schedule, persists the
%% ring in metadata so restarts keep the current key, and publishes it
%% via persistent_term for the chunks handler.
%%
%% The previous key stays in the ring for observability; expiry embedded
%% in responses tells clients when their cached dedupe shards die.
-module(xet_keys).

-behaviour(gen_server).

-export([start_link/1, current/1, rotate/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    name :: atom(),
    interval :: pos_integer()
}).
-type state() :: #state{}.

start_link(Config) ->
    gen_server:start_link(?MODULE, Config, []).

%% Current key and the expiry stamped into responses.
-spec current(atom()) -> #{key := xet_hash:hash(), expires_at := non_neg_integer()}.
current(Name) ->
    #{current := Current} = persistent_term:get({xet_server_keys, Name}),
    maps:with([key, expires_at], Current).

%% Force a rotation (tests, operational key burn).
-spec rotate(atom()) -> ok.
rotate(Name) ->
    gen_server:call(persistent_term:get({xet_server_keys_pid, Name}), rotate).

-spec init(map()) -> {ok, state()}.
init(#{name := Name} = Config) ->
    process_flag(trap_exit, true),
    Interval = maps:get(key_rotation_interval, Config),
    State = #state{name = Name, interval = Interval},
    ok = ensure_ring(State),
    persistent_term:put({xet_server_keys_pid, Name}, self()),
    schedule_check(Interval),
    {ok, State}.

handle_call(rotate, _From, State) ->
    ok = rotate_ring(State),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(rotate_check, #state{name = Name, interval = Interval} = State) ->
    #{current := #{created_at := Created}} = persistent_term:get({xet_server_keys, Name}),
    Now = erlang:system_time(second),
    case Now >= Created + Interval of
        true -> ok = rotate_ring(State);
        false -> ok
    end,
    schedule_check(Interval),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{name = Name}) ->
    _ = persistent_term:erase({xet_server_keys, Name}),
    _ = persistent_term:erase({xet_server_keys_pid, Name}),
    ok.

ensure_ring(#state{name = Name, interval = Interval} = State) ->
    Metadata = metadata(Name),
    Now = erlang:system_time(second),
    case xet_metadata:get_key_ring(Metadata) of
        {ok, #{current := #{created_at := Created}} = Ring} when Now < Created + Interval ->
            persistent_term:put({xet_server_keys, Name}, Ring),
            ok;
        _ ->
            rotate_ring(State)
    end.

rotate_ring(#state{name = Name, interval = Interval}) ->
    Metadata = metadata(Name),
    Now = erlang:system_time(second),
    New = #{
        key => crypto:strong_rand_bytes(32),
        created_at => Now,
        %% Twice the rotation interval: cached dedupe shards from just
        %% before a rotation stay matchable for a full interval.
        expires_at => Now + 2 * Interval
    },
    Ring =
        case persistent_term:get({xet_server_keys, Name}, undefined) of
            #{current := Old} -> #{current => New, previous => Old};
            _ -> #{current => New}
        end,
    ok = xet_metadata:put_key_ring(Metadata, Ring),
    persistent_term:put({xet_server_keys, Name}, Ring),
    ok.

metadata(Name) ->
    maps:get(metadata, xet_server:env(Name)).

schedule_check(Interval) ->
    CheckMs = max(1, min(Interval div 4, 3600)) * 1000,
    erlang:send_after(CheckMs, self(), rotate_check).
