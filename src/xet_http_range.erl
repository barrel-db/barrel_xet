%% Range header parsing. livery only emits 206/416 for file bodies; the
%% parsing side is ours. Reconstruction requests accept the strict
%% bytes=A-B form the OpenAPI declares; the data endpoint additionally
%% takes open-ended and suffix forms.
-module(xet_http_range).

-export([parse/1, reconstruction_range/1]).

-type parsed() ::
    all
    | {range, non_neg_integer(), non_neg_integer()}
    | {open, non_neg_integer()}
    | {suffix, pos_integer()}
    | invalid.
-export_type([parsed/0]).

-spec parse(binary() | undefined) -> parsed().
parse(undefined) ->
    all;
parse(<<"bytes=", Spec/binary>>) ->
    case binary:split(Spec, <<"-">>) of
        [<<>>, SuffixBin] -> suffix(SuffixBin);
        [StartBin, <<>>] -> open(StartBin);
        [StartBin, EndBin] -> bounded(StartBin, EndBin);
        _ -> invalid
    end;
parse(_) ->
    invalid.

suffix(Bin) ->
    case int(Bin) of
        {ok, N} when N > 0 -> {suffix, N};
        _ -> invalid
    end.

open(Bin) ->
    case int(Bin) of
        {ok, Start} -> {open, Start};
        error -> invalid
    end.

bounded(StartBin, EndBin) ->
    case {int(StartBin), int(EndBin)} of
        {{ok, Start}, {ok, End}} when Start =< End -> {range, Start, End};
        _ -> invalid
    end.

int(Bin) ->
    try
        {ok, binary_to_integer(Bin)}
    catch
        error:badarg -> error
    end.

%% The reconstruction API takes exactly bytes=A-B (A =< B) or no header.
-spec reconstruction_range(binary() | undefined) ->
    all | {ok, {non_neg_integer(), non_neg_integer()}} | invalid.
reconstruction_range(Header) ->
    case parse(Header) of
        all -> all;
        {range, Start, End} -> {ok, {Start, End}};
        _ -> invalid
    end.
