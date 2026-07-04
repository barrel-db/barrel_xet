%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Byte grouping 4 (spec Section 7.4.3) and the BG4 compression predictor.
%%
%% group/1 reorders bytes by position within 4-byte groups; ungroup/2
%% restores the original order given the original length. When the length
%% is not a multiple of 4, the first (length rem 4) groups hold one extra
%% byte.
%%
%% predict/1 ports xet-core's BG4Predictor: four popcount histograms keyed
%% by byte position mod 4, compared to the pooled distribution by KL
%% divergence; above 0.02 the data looks like structured numeric content
%% and BG4+LZ4 is recommended.
-module(xet_bg4).

-export([group/1, ungroup/2, predict/1]).

-define(KL_THRESHOLD, 0.02).

-spec group(binary()) -> binary().
group(Data) ->
    group(Data, [], [], [], []).

group(<<A, B, C, D, Rest/binary>>, G0, G1, G2, G3) ->
    group(Rest, [A | G0], [B | G1], [C | G2], [D | G3]);
group(<<A, B, C>>, G0, G1, G2, G3) ->
    finish([A | G0], [B | G1], [C | G2], G3);
group(<<A, B>>, G0, G1, G2, G3) ->
    finish([A | G0], [B | G1], G2, G3);
group(<<A>>, G0, G1, G2, G3) ->
    finish([A | G0], G1, G2, G3);
group(<<>>, G0, G1, G2, G3) ->
    finish(G0, G1, G2, G3).

finish(G0, G1, G2, G3) ->
    list_to_binary([lists:reverse(G) || G <- [G0, G1, G2, G3]]).

-spec ungroup(binary(), non_neg_integer()) -> binary().
ungroup(Grouped, OrigLen) when byte_size(Grouped) =:= OrigLen ->
    Base = OrigLen div 4,
    Rem = OrigLen rem 4,
    S0 = Base + extra(0, Rem),
    S1 = Base + extra(1, Rem),
    S2 = Base + extra(2, Rem),
    <<G0:S0/binary, G1:S1/binary, G2:S2/binary, G3/binary>> = Grouped,
    list_to_binary(interleave(G0, G1, G2, G3)).

extra(I, Rem) when I < Rem -> 1;
extra(_, _) -> 0.

interleave(<<A, R0/binary>>, <<B, R1/binary>>, <<C, R2/binary>>, <<D, R3/binary>>) ->
    [A, B, C, D | interleave(R0, R1, R2, R3)];
interleave(<<A>>, <<B>>, <<C>>, <<>>) ->
    [A, B, C];
interleave(<<A>>, <<B>>, <<>>, <<>>) ->
    [A, B];
interleave(<<A>>, <<>>, <<>>, <<>>) ->
    [A];
interleave(<<>>, <<>>, <<>>, <<>>) ->
    [].

%% Recommend bg4_lz4 when the maximum KL divergence between a byte-class
%% popcount distribution and the pooled one exceeds the threshold.
%%
%% Upstream quirk mirrored on purpose: a class whose histogram has any
%% empty bin yields NaN in the Rust sum (0 * ln 0) and f64::max drops NaN,
%% so such classes simply do not vote. We skip them explicitly.
-spec predict(binary()) -> lz4 | bg4_lz4.
predict(Data) ->
    Hists = histograms(Data),
    Pooled = pooled(Hists),
    BaseTotal = lists:sum([lists:sum(H) || H <- Hists]),
    Divs = [kl(H, Pooled, BaseTotal) || H <- Hists, not lists:member(0, H)],
    case lists:max([0.0 | Divs]) > ?KL_THRESHOLD of
        true -> bg4_lz4;
        false -> lz4
    end.

%% Pooled counts start at 1 per bin (upstream's zero-probability guard).
pooled(Hists) ->
    lists:foldl(
        fun(H, Acc) -> lists:zipwith(fun erlang:'+'/2, H, Acc) end, lists:duplicate(9, 1), Hists
    ).

kl(Hist, Pooled, BaseTotal) ->
    Total = lists:sum(Hist),
    lists:foldl(
        fun({C, Q}, Acc) ->
            P = C / Total,
            Acc + P * math:log(P / (Q / BaseTotal))
        end,
        0.0,
        lists:zip(Hist, Pooled)
    ).

histograms(Data) ->
    {H0, H1, H2, H3} = hist_loop(Data, empty_hist(), empty_hist(), empty_hist(), empty_hist()),
    [tuple_to_list(H0), tuple_to_list(H1), tuple_to_list(H2), tuple_to_list(H3)].

empty_hist() ->
    {0, 0, 0, 0, 0, 0, 0, 0, 0}.

hist_loop(<<A, B, C, D, Rest/binary>>, H0, H1, H2, H3) ->
    hist_loop(Rest, bump(H0, A), bump(H1, B), bump(H2, C), bump(H3, D));
hist_loop(<<A, B, C>>, H0, H1, H2, H3) ->
    {bump(H0, A), bump(H1, B), bump(H2, C), H3};
hist_loop(<<A, B>>, H0, H1, H2, H3) ->
    {bump(H0, A), bump(H1, B), H2, H3};
hist_loop(<<A>>, H0, H1, H2, H3) ->
    {bump(H0, A), H1, H2, H3};
hist_loop(<<>>, H0, H1, H2, H3) ->
    {H0, H1, H2, H3}.

bump(Hist, Byte) ->
    I = popcnt8(Byte) + 1,
    setelement(I, Hist, element(I, Hist) + 1).

popcnt8(B) ->
    C1 = B - ((B bsr 1) band 16#55),
    C2 = (C1 band 16#33) + ((C1 bsr 2) band 16#33),
    (C2 + (C2 bsr 4)) band 16#0F.
