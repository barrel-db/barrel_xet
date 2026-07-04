%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Reconstruction planner (spec Sections 8 and 12, API Appendix A.3):
%% given a file's terms and per-xorb chunk layout, produce the term
%% subset for an optional byte range, the offset to skip in the first
%% term, and the serialized byte ranges to fetch per xorb.
%%
%% Byte ranges follow HTTP Range semantics (inclusive end), chunk index
%% ranges stay end-exclusive, exactly like the wire format. to_v1/2 and
%% to_v2/2 render the two response shapes; the caller injects URLs.
-module(xet_reconstruction).

-export([plan/4, to_v1/2, to_v2/2]).

-type range() :: all | {non_neg_integer(), non_neg_integer()}.
-type xorb_info_fun() :: fun(
    (xet_hash:hash()) -> #{
        unpacked_offsets := [non_neg_integer()], boundary_offsets := [non_neg_integer()]
    }
).
-type planned_term() :: #{
    cas_hash := xet_hash:hash(),
    chunk_start := non_neg_integer(),
    chunk_end := pos_integer(),
    unpacked_len := non_neg_integer()
}.
-type plan() :: #{
    offset_into_first_range := non_neg_integer(),
    terms := [planned_term()],
    xorb_ranges := [
        {xet_hash:hash(), [
            {{non_neg_integer(), pos_integer()}, {non_neg_integer(), non_neg_integer()}}
        ]}
    ]
}.
-export_type([range/0, plan/0, xorb_info_fun/0]).

%% Range is inclusive (HTTP semantics); the end is clamped to the file
%% size. all means the whole file.
-spec plan([xet_shard:file_term()], non_neg_integer(), range(), xorb_info_fun()) ->
    {ok, plan()} | {error, unsatisfiable | inconsistent_metadata}.
plan(Terms, TotalLen, all, InfoFun) when TotalLen >= 0 ->
    build_plan(Terms, 0, InfoFun, full);
plan(_Terms, TotalLen, {Start, _End}, _InfoFun) when Start >= TotalLen ->
    {error, unsatisfiable};
plan(_Terms, _TotalLen, {Start, End}, _InfoFun) when End < Start ->
    {error, unsatisfiable};
plan(Terms, TotalLen, {Start, End}, InfoFun) ->
    EndExcl = min(End + 1, TotalLen),
    select_terms(Terms, 0, Start, EndExcl, InfoFun, [], undefined).

build_plan(Terms, Offset, InfoFun, full) ->
    try
        Planned = [narrow_full(T, InfoFun) || T <- Terms],
        {ok, finish(Planned, Offset)}
    catch
        error:inconsistent_metadata -> {error, inconsistent_metadata}
    end.

narrow_full(#{cas_hash := Cas, chunk_start := S, chunk_end := E, unpacked_len := Len}, InfoFun) ->
    Sizes = chunk_sizes(Cas, S, E, InfoFun),
    case lists:sum(Sizes) of
        Len -> #{cas_hash => Cas, chunk_start => S, chunk_end => E, unpacked_len => Len};
        _ -> error(inconsistent_metadata)
    end.

select_terms([], _Pos, _Start, _EndExcl, _InfoFun, Acc, Offset) ->
    {ok, finish(lists:reverse(Acc), default_offset(Offset))};
select_terms([T | Rest], Pos, Start, EndExcl, InfoFun, Acc, Offset) ->
    #{unpacked_len := Len} = T,
    TermEnd = Pos + Len,
    case TermEnd =< Start orelse Pos >= EndExcl of
        true ->
            select_terms(Rest, TermEnd, Start, EndExcl, InfoFun, Acc, Offset);
        false ->
            try narrow_range(T, Pos, Start, EndExcl, InfoFun) of
                {Planned, FirstOffset} ->
                    Offset1 = pick_offset(Offset, FirstOffset),
                    select_terms(Rest, TermEnd, Start, EndExcl, InfoFun, [Planned | Acc], Offset1)
            catch
                error:inconsistent_metadata -> {error, inconsistent_metadata}
            end
    end.

default_offset(undefined) -> 0;
default_offset(Offset) -> Offset.

pick_offset(undefined, FirstOffset) -> FirstOffset;
pick_offset(Offset, _) -> Offset.

%% Narrow one overlapping term to the chunks that intersect the byte
%% range, returning the offset into the narrowed data for the first term.
narrow_range(
    #{cas_hash := Cas, chunk_start := S, chunk_end := E} = T, Pos, Start, EndExcl, InfoFun
) ->
    Sizes = chunk_sizes(Cas, S, E, InfoFun),
    Len = maps:get(unpacked_len, T),
    Len =:= lists:sum(Sizes) orelse error(inconsistent_metadata),
    RelStart = max(Start - Pos, 0),
    RelEnd = min(EndExcl - Pos, Len),
    {FirstIdx, SkipBefore} = locate(Sizes, RelStart),
    {LastIdx, _} = locate(Sizes, RelEnd - 1),
    NewStart = S + FirstIdx,
    NewEnd = S + LastIdx + 1,
    NarrowLen = lists:sum(lists:sublist(Sizes, FirstIdx + 1, LastIdx - FirstIdx + 1)),
    Planned = #{
        cas_hash => Cas, chunk_start => NewStart, chunk_end => NewEnd, unpacked_len => NarrowLen
    },
    {Planned, RelStart - SkipBefore}.

%% Index of the chunk containing byte position P, and the bytes before it.
locate(Sizes, P) ->
    locate(Sizes, P, 0, 0).

locate([Size | Rest], P, Idx, Before) when P >= Before + Size ->
    locate(Rest, P, Idx + 1, Before + Size);
locate([_ | _], _P, Idx, Before) ->
    {Idx, Before};
locate([], _P, _Idx, _Before) ->
    error(inconsistent_metadata).

chunk_sizes(Cas, S, E, InfoFun) ->
    #{unpacked_offsets := Offsets} = InfoFun(Cas),
    E =< length(Offsets) orelse error(inconsistent_metadata),
    Ends = lists:sublist(Offsets, S + 1, E - S),
    Starts =
        case S of
            0 -> [0 | lists:droplast(Ends)];
            _ -> [lists:nth(S, Offsets) | lists:droplast(Ends)]
        end,
    [B - A || {A, B} <- lists:zip(Starts, Ends)].

finish(Planned, Offset) ->
    #{
        offset_into_first_range => Offset,
        terms => Planned,
        xorb_ranges => xorb_ranges(Planned)
    }.

%% Unique chunk ranges per xorb, in first-appearance order. Byte ranges
%% resolve lazily in the renderers (they need boundary offsets).
xorb_ranges(Planned) ->
    Pairs = [
        {Cas, {maps:get(chunk_start, T), maps:get(chunk_end, T)}}
     || #{cas_hash := Cas} = T <- Planned
    ],
    group_ranges(Pairs, [], #{}).

group_ranges([], Order, Map) ->
    [{Cas, lists:reverse(maps:get(Cas, Map))} || Cas <- lists:reverse(Order)];
group_ranges([{Cas, Range} | Rest], Order, Map) ->
    case maps:find(Cas, Map) of
        error ->
            group_ranges(Rest, [Cas | Order], maps:put(Cas, [Range], Map));
        {ok, Ranges} ->
            case lists:member(Range, Ranges) of
                true -> group_ranges(Rest, Order, Map);
                false -> group_ranges(Rest, Order, maps:put(Cas, [Range | Ranges], Map))
            end
    end.

%% V1 wire shape (A.3): fetch_info is a map from xorb hash string to one
%% entry per chunk range. Ctx carries url (fun((CasHash, {ByteStart,
%% ByteEndIncl})) -> binary()) and boundaries (fun((CasHash)) -> offsets).
-spec to_v1(plan(), map()) -> map().
to_v1(#{offset_into_first_range := Offset, terms := Terms, xorb_ranges := XorbRanges}, Ctx) ->
    #{
        offset_into_first_range => Offset,
        terms => render_terms(Terms),
        fetch_info => maps:from_list([
            {xet_hash:to_string(Cas), [
                fetch_entry(Cas, Range, Ctx)
             || Range <- Ranges
            ]}
         || {Cas, Ranges} <- XorbRanges
        ])
    }.

render_terms(Terms) ->
    [
        #{
            hash => xet_hash:to_string(maps:get(cas_hash, T)),
            unpacked_length => maps:get(unpacked_len, T),
            range => #{
                start => maps:get(chunk_start, T), 'end' => maps:get(chunk_end, T)
            }
        }
     || T <- Terms
    ].

fetch_entry(Cas, {S, E} = Range, #{url := UrlFun, boundaries := BoundaryFun}) ->
    {ByteS, ByteEExcl} = xet_xorb:chunk_byte_range(BoundaryFun(Cas), Range),
    ByteRange = {ByteS, ByteEExcl - 1},
    #{
        range => #{start => S, 'end' => E},
        url => UrlFun(Cas, ByteRange),
        url_range => #{start => ByteS, 'end' => ByteEExcl - 1}
    }.

%% V2 wire shape: one entry per xorb carrying all its ranges under a
%% single URL (the URL covers the xorb; ranges select the bytes).
-spec to_v2(plan(), map()) -> map().
to_v2(#{offset_into_first_range := Offset, terms := Terms, xorb_ranges := XorbRanges}, Ctx) ->
    #{
        offset_into_first_range => Offset,
        terms => render_terms(Terms),
        xorbs => maps:from_list([
            {xet_hash:to_string(Cas), [
                #{
                    url => whole_url(Cas, Ranges, Ctx),
                    ranges => [range_descriptor(Cas, R, Ctx) || R <- Ranges]
                }
            ]}
         || {Cas, Ranges} <- XorbRanges
        ])
    }.

whole_url(Cas, Ranges, #{url := UrlFun, boundaries := BoundaryFun}) ->
    Boundaries = BoundaryFun(Cas),
    Starts = [element(1, xet_xorb:chunk_byte_range(Boundaries, R)) || R <- Ranges],
    Ends = [element(2, xet_xorb:chunk_byte_range(Boundaries, R)) || R <- Ranges],
    UrlFun(Cas, {lists:min(Starts), lists:max(Ends) - 1}).

range_descriptor(Cas, {S, E} = Range, #{boundaries := BoundaryFun}) ->
    {ByteS, ByteEExcl} = xet_xorb:chunk_byte_range(BoundaryFun(Cas), Range),
    #{
        chunks => #{start => S, 'end' => E},
        bytes => #{start => ByteS, 'end' => ByteEExcl - 1}
    }.
