%% Pure Erlang reference chunker, written straight from the Section 5.3
%% pseudocode. Test-only: the production path is the NIF scanner in
%% xet_chunker; equivalence between the two is property-tested.
-module(xet_chunker_ref).

-include("xet_gear_table.hrl").

-export([chunk_boundaries/1]).

-define(MIN_CHUNK_SIZE, 8192).
-define(MAX_CHUNK_SIZE, 131072).
-define(GEAR_MASK, 16#FFFF000000000000).
-define(M64, 16#FFFFFFFFFFFFFFFF).

-spec chunk_boundaries(binary()) -> [non_neg_integer()].
chunk_boundaries(Data) ->
    scan(Data, 0, 0, 0, []).

scan(<<B, Rest/binary>>, H0, Len0, Pos0, Acc) ->
    H = ((H0 bsl 1) + element(B + 1, ?XET_GEAR_TABLE)) band ?M64,
    decide(Rest, H, Len0 + 1, Pos0 + 1, Acc);
scan(<<>>, _H, 0, _Pos, Acc) ->
    lists:reverse(Acc);
scan(<<>>, _H, _Len, Pos, Acc) ->
    lists:reverse([Pos | Acc]).

decide(Rest, H, Len, Pos, Acc) when Len < ?MIN_CHUNK_SIZE ->
    scan(Rest, H, Len, Pos, Acc);
decide(Rest, _H, Len, Pos, Acc) when Len >= ?MAX_CHUNK_SIZE ->
    scan(Rest, 0, 0, Pos, [Pos | Acc]);
decide(Rest, H, _Len, Pos, Acc) when H band ?GEAR_MASK =:= 0 ->
    scan(Rest, 0, 0, Pos, [Pos | Acc]);
decide(Rest, H, Len, Pos, Acc) ->
    scan(Rest, H, Len, Pos, Acc).
