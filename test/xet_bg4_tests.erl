-module(xet_bg4_tests).

-include_lib("eunit/include/eunit.hrl").

%% zig-xet golden vectors (first one is also the spec's 10-byte example).
golden_vectors_test() ->
    lists:foreach(
        fun({Input, Grouped}) ->
            ?assertEqual(Grouped, xet_bg4:group(Input)),
            ?assertEqual(Input, xet_bg4:ungroup(Grouped, byte_size(Input)))
        end,
        xet_test_vectors:bg4_vectors()
    ).

empty_test() ->
    ?assertEqual(<<>>, xet_bg4:group(<<>>)),
    ?assertEqual(<<>>, xet_bg4:ungroup(<<>>, 0)).

ungroup_length_mismatch_test() ->
    ?assertError(function_clause, xet_bg4:ungroup(<<1, 2, 3>>, 4)).

%% Uniform random bytes: the four class distributions match the pooled
%% one, KL stays far below the threshold.
predict_uniform_test() ->
    Data = xet_test_vectors:splitmix64_data(65536, 17),
    ?assertEqual(lz4, xet_bg4:predict(Data)).

%% One heavily skewed class whose histogram still covers every popcount
%% bin (so it is not NaN-skipped) must trip the predictor.
predict_skewed_class_test() ->
    Fillers = <<16#00, 16#01, 16#03, 16#07, 16#0F, 16#1F, 16#3F, 16#7F>>,
    Rnd = xet_test_vectors:splitmix64_data(3 * 8192, 99),
    Words = [
        begin
            C0 =
                case I < 8 of
                    true -> binary:at(Fillers, I);
                    false -> 16#FF
                end,
            <<C0, (binary:at(Rnd, 3 * I)), (binary:at(Rnd, 3 * I + 1)),
                (binary:at(Rnd, 3 * I + 2))>>
        end
     || I <- lists:seq(0, 8191)
    ],
    ?assertEqual(bg4_lz4, xet_bg4:predict(list_to_binary(Words))).

%% Text never covers all popcount bins, so every class is skipped and the
%% recommendation stays lz4 (mirrors the upstream NaN behavior).
predict_text_test() ->
    Text = binary:copy(<<"The quick brown fox jumps over the lazy dog. ">>, 1000),
    ?assertEqual(lz4, xet_bg4:predict(Text)).

predict_empty_test() ->
    ?assertEqual(lz4, xet_bg4:predict(<<>>)).
