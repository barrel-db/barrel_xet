-module(prop_xet_xorb).

-include_lib("proper/include/proper.hrl").

-define(NONCE0, <<0, 0, 0, 0>>).

gen_chunk() ->
    oneof([
        ?LET(
            {Seed, Len},
            {integer(0, 1 bsl 40), integer(1, 3000)},
            xet_test_vectors:splitmix64_data(Len, Seed)
        ),
        ?LET({Byte, Len}, {integer(0, 255), integer(1, 3000)}, binary:copy(<<Byte>>, Len))
    ]).

gen_chunks() ->
    non_empty(resize(20, list(gen_chunk()))).

gen_scheme() ->
    oneof([auto, none, lz4, bg4_lz4]).

prop_roundtrip() ->
    ?FORALL(
        {Chunks, Scheme},
        {gen_chunks(), gen_scheme()},
        begin
            {ok, Enc} = xet_xorb:encode(Chunks, #{compression => Scheme, nonce => ?NONCE0}),
            {ok, Dec} = xet_xorb:decode(maps:get(bin, Enc)),
            maps:get(chunks, Dec) =:= Chunks andalso
                maps:get(hash, Dec) =:= maps:get(hash, Enc)
        end
    ).

prop_encode_deterministic() ->
    ?FORALL(
        Chunks,
        gen_chunks(),
        begin
            {ok, E1} = xet_xorb:encode(Chunks, #{nonce => ?NONCE0}),
            {ok, E2} = xet_xorb:encode(Chunks, #{nonce => ?NONCE0}),
            maps:get(bin, E1) =:= maps:get(bin, E2)
        end
    ).

%% Corrupting any single byte outside the 4-byte uniqueness nonce makes
%% decode fail; corrupting the nonce is ignored by design.
prop_corruption_detected() ->
    ?FORALL(
        {Chunks, PosSeed},
        {gen_chunks(), integer(0, 1 bsl 30)},
        begin
            {ok, Enc} = xet_xorb:encode(Chunks, #{nonce => ?NONCE0}),
            Bin = maps:get(bin, Enc),
            Size = byte_size(Bin),
            Pos = PosSeed rem Size,
            Flipped = flip(Bin, Pos),
            NonceStart = Size - 20,
            case Pos >= NonceStart andalso Pos < NonceStart + 4 of
                true ->
                    {ok, Dec} = xet_xorb:decode(Flipped),
                    maps:get(chunks, Dec) =:= Chunks;
                false ->
                    case xet_xorb:decode(Flipped) of
                        {error, _} -> true;
                        {ok, _} -> false
                    end
            end
        end
    ).

flip(Bin, Pos) ->
    <<Before:Pos/binary, Byte, After/binary>> = Bin,
    <<Before/binary, (Byte bxor 16#FF), After/binary>>.
