%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Streaming content-defined chunker (spec Section 5), NIF-backed.
%%
%% Feed arbitrary buffers with update/2 and close with finalize/1; the
%% returned boundaries are absolute end offsets into the full stream.
%% Boundary rules: cuts only at or above MIN_CHUNK_SIZE, forced at
%% MAX_CHUNK_SIZE, otherwise where the rolling hash matches the mask; the
%% final chunk may be shorter than MIN_CHUNK_SIZE.
-module(xet_chunker).

-export([new/0, update/2, finalize/1, chunk_boundaries/1, split/1]).
-export([min_chunk_size/0, max_chunk_size/0, target_chunk_size/0]).

-record(state, {
    h = 0 :: non_neg_integer(),
    len = 0 :: non_neg_integer(),
    offset = 0 :: non_neg_integer()
}).

-opaque state() :: #state{}.
-export_type([state/0]).

-define(MIN_CHUNK_SIZE, 8192).
-define(MAX_CHUNK_SIZE, 131072).
-define(TARGET_CHUNK_SIZE, 65536).

-spec new() -> state().
new() ->
    #state{}.

-spec update(state(), iodata()) -> {[non_neg_integer()], state()}.
update(#state{h = H0, len = L0, offset = Off} = State, Data) ->
    {Cuts, H1, L1} = xet_nif:gearhash_scan(H0, L0, Data),
    Abs = [Off + Cut || Cut <- Cuts],
    {Abs, State#state{h = H1, len = L1, offset = Off + iolist_size(Data)}}.

%% The trailing partial chunk (if any) ends at the stream's end.
-spec finalize(state()) -> [non_neg_integer()].
finalize(#state{len = 0}) ->
    [];
finalize(#state{offset = Off}) ->
    [Off].

-spec chunk_boundaries(iodata()) -> [non_neg_integer()].
chunk_boundaries(Data) ->
    {Cuts, State} = update(new(), Data),
    Cuts ++ finalize(State).

%% Convenience for tests and small inputs: the actual chunk binaries.
-spec split(binary()) -> [binary()].
split(Data) ->
    slices(chunk_boundaries(Data), 0, Data).

slices([], _Start, _Data) ->
    [];
slices([End | Rest], Start, Data) ->
    [binary:part(Data, Start, End - Start) | slices(Rest, End, Data)].

-spec min_chunk_size() -> pos_integer().
min_chunk_size() -> ?MIN_CHUNK_SIZE.

-spec max_chunk_size() -> pos_integer().
max_chunk_size() -> ?MAX_CHUNK_SIZE.

-spec target_chunk_size() -> pos_integer().
target_chunk_size() -> ?TARGET_CHUNK_SIZE.
