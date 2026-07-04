%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Upload planner (spec Sections 10 and 11): turns per-file chunk streams
%% into xorbs to upload plus file reconstruction metadata, deduplicating
%% at chunk level along the way.
%%
%% Dedup sources, in order: the session map (chunks already seen in this
%% session, open or cut xorbs), the cache callback (local shard cache),
%% then the global query callback, gated by eligibility and minimum
%% spacing. Non-continuing dedup runs pass through the xet_defrag
%% estimator, exactly like xet-core's FileDeduper.
%%
%% Xorbs are cut when the next chunk would exceed the size or count
%% limits and handed back as soon as they close; terms referencing a
%% still-open xorb stay symbolic until finalize/1 resolves them.
-module(xet_upload_plan).

-export([new/0, new/1, add_file/3, finalize/1]).

-define(MAX_XORB_SIZE, 67108864).
-define(MAX_XORB_CHUNKS, 8192).
-define(MIN_QUERY_SPACING, 256).

-record(plan, {
    opts :: map(),
    seq = 0 :: non_neg_integer(),
    open = [] :: [{binary(), xet_hash:hash(), pos_integer()}],
    open_count = 0 :: non_neg_integer(),
    open_size = 0 :: non_neg_integer(),
    session_map = #{} :: #{xet_hash:hash() => {location(), non_neg_integer()}},
    resolved = #{} :: #{non_neg_integer() => xet_hash:hash()},
    files = [] :: [map()],
    stats = #{} :: map()
}).

-record(f, {
    id :: term(),
    terms = [] :: [map()],
    entries = [] :: [xet_hash:entry()],
    defrag :: xet_defrag:state(),
    sha :: undefined | crypto:hash_state(),
    idx = 0 :: non_neg_integer(),
    next_query = 0 :: non_neg_integer(),
    emitted = [] :: [xorb_out()],
    stats :: map()
}).

-type location() :: {cas, xet_hash:hash()} | {pending, non_neg_integer()}.
-type xorb_out() :: #{
    seq := non_neg_integer(),
    hash := xet_hash:hash(),
    chunks := [binary()],
    entries := [xet_hash:entry()]
}.
-opaque session() :: #plan{}.
-export_type([session/0, xorb_out/0]).

-spec new() -> session().
new() ->
    new(#{}).

-spec new(map()) -> session().
new(Opts) ->
    Defaults = #{
        query => fun(_Hash) -> not_found end,
        cache => fun(_Hash) -> not_found end,
        min_spacing => ?MIN_QUERY_SPACING,
        cut_bytes => ?MAX_XORB_SIZE,
        cut_chunks => ?MAX_XORB_CHUNKS,
        sha256 => true,
        defrag => {128, 8.0, 0.5}
    },
    #plan{opts = maps:merge(Defaults, Opts), stats = zero_stats()}.

zero_stats() ->
    #{
        total_chunks => 0,
        total_bytes => 0,
        new_chunks => 0,
        new_bytes => 0,
        deduped_chunks => 0,
        deduped_bytes => 0,
        defrag_prevented_chunks => 0
    }.

%% Feed one whole file as a list of chunk binaries (from xet_chunker).
%% Returns the xorbs that were cut while processing it.
-spec add_file(session(), term(), [binary()]) -> {[xorb_out()], session()}.
add_file(#plan{opts = Opts} = S0, FileId, Chunks) ->
    {W, Min, Hyst} = maps:get(defrag, Opts),
    F0 = #f{
        id = FileId,
        defrag = xet_defrag:new(W, Min, Hyst),
        sha = sha_init(maps:get(sha256, Opts)),
        stats = zero_stats()
    },
    Enriched = [{Data, xet_hash:chunk_hash(Data), byte_size(Data)} || Data <- Chunks],
    {S1, F1} = process(Enriched, S0, F0),
    S2 = finish_file(S1, F1),
    {lists:reverse(F1#f.emitted), S2}.

process([], S, F) ->
    {S, F};
process([{Data, Hash, Size} | Rest] = All, S0, F0) ->
    case find_location(S0, F0, Hash) of
        {found, Loc, Idx, S1, F1} ->
            dedup_chunk(All, Loc, Idx, Rest, S1, F1);
        {miss, S1, F1} ->
            store_new(Rest, Data, Hash, Size, S1, F1)
    end.

store_new(Rest, Data, Hash, Size, S, F) ->
    {S1, F1} = new_chunk(Data, Hash, Size, S, F),
    process(Rest, S1, F1).

%% A dedup candidate: continuation of the current term is always allowed;
%% a new range consults the defrag estimator with the full run length.
dedup_chunk([{Data, Hash, Size} | _], Loc, Idx, Rest, S, #f{terms = Terms} = F0) ->
    case continues(Terms, Loc, Idx) of
        true ->
            accept_dedup(
                Rest, S, extend_term(F0, Hash, Size, Idx), increment_last, Data, Hash, Size
            );
        false ->
            RunLen = 1 + lookahead(Rest, S, Loc, Idx + 1),
            {Allow, D1} = xet_defrag:allow(F0#f.defrag, RunLen),
            F1 = F0#f{defrag = D1},
            case Allow of
                true ->
                    accept_dedup(
                        Rest, S, push_term(F1, Loc, Idx, Hash, Size), add_range, Data, Hash, Size
                    );
                false ->
                    store_new(Rest, Data, Hash, Size, S, count_prevented(F1, RunLen))
            end
    end.

accept_dedup(Rest, S, F0, DefragOp, Data, Hash, Size) ->
    Defrag =
        case DefragOp of
            increment_last -> xet_defrag:increment_last(F0#f.defrag, 1);
            add_range -> xet_defrag:add_range(F0#f.defrag, 1)
        end,
    F1 = count_dedup(bump_common(F0#f{defrag = Defrag}, Data, Hash, Size), 1, Size),
    process(Rest, S, F1).

%% How many upcoming chunks continue this run, using cheap lookups only.
lookahead([], _S, _Loc, _NextIdx) ->
    0;
lookahead([{_, Hash, _} | Rest], S, Loc, NextIdx) ->
    case cheap_location(S, Hash) of
        {ok, Loc, NextIdx} -> 1 + lookahead(Rest, S, Loc, NextIdx + 1);
        _ -> 0
    end.

new_chunk(Data, Hash, Size, S0, F0) ->
    {Cut, S1} = maybe_cut(S0, Size),
    F1 =
        case Cut of
            none -> F0;
            Out -> F0#f{emitted = [Out | F0#f.emitted]}
        end,
    Loc = {pending, S1#plan.seq},
    Idx = S1#plan.open_count,
    F2 =
        case continues(F1#f.terms, Loc, Idx) of
            true ->
                G = extend_term(F1, Hash, Size, Idx),
                G#f{defrag = xet_defrag:increment_last(G#f.defrag, 1)};
            false ->
                G = push_term(F1, Loc, Idx, Hash, Size),
                G#f{defrag = xet_defrag:add_range(G#f.defrag, 1)}
        end,
    F3 = count_new(bump_common(F2, Data, Hash, Size), Size),
    S2 = S1#plan{
        open = [{Data, Hash, Size} | S1#plan.open],
        open_count = Idx + 1,
        open_size = S1#plan.open_size + Size,
        session_map = maps:put(Hash, {Loc, Idx}, S1#plan.session_map)
    },
    {S2, F3}.

maybe_cut(#plan{open_count = Count, open_size = OpenSize, opts = Opts} = S, Size) ->
    case
        Count + 1 > maps:get(cut_chunks, Opts) orelse
            OpenSize + Size > maps:get(cut_bytes, Opts)
    of
        true -> cut_xorb(S);
        false -> {none, S}
    end.

cut_xorb(#plan{open = []} = S) ->
    {none, S};
cut_xorb(#plan{seq = Seq, open = Open} = S) ->
    Ordered = lists:reverse(Open),
    Entries = [{Hash, Size} || {_, Hash, Size} <- Ordered],
    XorbHash = xet_hash:xorb_hash(Entries),
    Out = #{
        seq => Seq,
        hash => XorbHash,
        chunks => [Data || {Data, _, _} <- Ordered],
        entries => Entries
    },
    S1 = S#plan{
        seq = Seq + 1,
        open = [],
        open_count = 0,
        open_size = 0,
        resolved = maps:put(Seq, XorbHash, S#plan.resolved)
    },
    {Out, S1}.

continues([#{target := Loc, stop := Stop} | _], Loc, Idx) when Stop =:= Idx ->
    true;
continues(_, _, _) ->
    false.

extend_term(#f{terms = [Term | Rest]} = F, Hash, Size, Idx) ->
    #{stop := Idx, len := Len, hashes := Hashes} = Term,
    F#f{terms = [Term#{stop := Idx + 1, len := Len + Size, hashes := [Hash | Hashes]} | Rest]}.

push_term(#f{terms = Terms} = F, Loc, Idx, Hash, Size) ->
    Term = #{target => Loc, start => Idx, stop => Idx + 1, len => Size, hashes => [Hash]},
    F#f{terms = [Term | Terms]}.

find_location(S, F, Hash) ->
    case cheap_location(S, Hash) of
        {ok, Loc, Idx} ->
            {found, Loc, Idx, S, F};
        miss ->
            global_query(S, F, Hash)
    end.

cheap_location(#plan{session_map = Map, opts = Opts}, Hash) ->
    case maps:find(Hash, Map) of
        {ok, {Loc, Idx}} ->
            {ok, Loc, Idx};
        error ->
            Cache = maps:get(cache, Opts),
            case Cache(Hash) of
                {ok, {CasHash, Idx}} -> {ok, {cas, CasHash}, Idx};
                not_found -> miss
            end
    end.

global_query(#plan{opts = Opts} = S, #f{idx = Idx, next_query = Next} = F, Hash) ->
    Gated =
        xet_dedup:eligible(Hash, Idx =:= 0) andalso Idx >= Next,
    case Gated of
        false ->
            {miss, S, F};
        true ->
            F1 = F#f{next_query = Idx + maps:get(min_spacing, Opts)},
            Query = maps:get(query, Opts),
            case Query(Hash) of
                not_found ->
                    {miss, S, F1};
                {ok, Mappings} ->
                    S1 = merge_mappings(S, Mappings),
                    case maps:find(Hash, S1#plan.session_map) of
                        {ok, {Loc, At}} -> {found, Loc, At, S1, F1};
                        error -> {miss, S1, F1}
                    end
            end
    end.

merge_mappings(#plan{session_map = Map0} = S, Mappings) ->
    Map1 = lists:foldl(
        fun({Hash, CasHash, Idx}, Acc) ->
            maps:put(Hash, {{cas, CasHash}, Idx}, Acc)
        end,
        Map0,
        Mappings
    ),
    S#plan{session_map = Map1}.

bump_common(#f{idx = Idx, entries = Entries, sha = Sha, stats = Stats} = F, Data, Hash, Size) ->
    F#f{
        idx = Idx + 1,
        entries = [{Hash, Size} | Entries],
        sha = sha_update(Sha, Data),
        stats = Stats#{
            total_chunks := maps:get(total_chunks, Stats) + 1,
            total_bytes := maps:get(total_bytes, Stats) + Size
        }
    }.

count_dedup(#f{stats = Stats} = F, N, Bytes) ->
    F#f{
        stats = Stats#{
            deduped_chunks := maps:get(deduped_chunks, Stats) + N,
            deduped_bytes := maps:get(deduped_bytes, Stats) + Bytes
        }
    }.

count_new(#f{stats = Stats} = F, Bytes) ->
    F#f{
        stats = Stats#{
            new_chunks := maps:get(new_chunks, Stats) + 1,
            new_bytes := maps:get(new_bytes, Stats) + Bytes
        }
    }.

count_prevented(#f{stats = Stats} = F, N) ->
    F#f{
        stats = Stats#{
            defrag_prevented_chunks := maps:get(defrag_prevented_chunks, Stats) + N
        }
    }.

finish_file(S, #f{id = Id, terms = Terms0, entries = Entries0, sha = Sha, stats = FStats}) ->
    Terms = lists:reverse(Terms0),
    Entries = lists:reverse(Entries0),
    File = #{
        file_id => Id,
        file_hash => xet_hash:file_hash(Entries),
        sha256 => sha_final(Sha),
        total_len => lists:sum([Sz || {_, Sz} <- Entries]),
        terms => [maps:with([target, start, stop, len], T) || T <- Terms],
        verification => [
            xet_hash:verification_hash(lists:reverse(maps:get(hashes, T)))
         || T <- Terms
        ]
    },
    S#plan{
        files = [File | S#plan.files],
        stats = merge_stats(S#plan.stats, FStats)
    }.

merge_stats(A, B) ->
    maps:map(fun(Key, V) -> V + maps:get(Key, B) end, A).

%% Cut the open xorb (if any) and resolve every symbolic term.
-spec finalize(session()) ->
    #{xorbs := [xorb_out()], files := [map()], stats := map()}.
finalize(S0) ->
    {Cut, S1} = cut_xorb(S0),
    Last =
        case Cut of
            none -> [];
            Out -> [Out]
        end,
    Files = [resolve_file(F, S1#plan.resolved) || F <- lists:reverse(S1#plan.files)],
    #{xorbs => Last, files => Files, stats => S1#plan.stats}.

resolve_file(#{terms := Terms} = File, Resolved) ->
    File#{
        terms := [
            #{
                cas_hash => resolve(maps:get(target, T), Resolved),
                unpacked_len => maps:get(len, T),
                chunk_start => maps:get(start, T),
                chunk_end => maps:get(stop, T)
            }
         || T <- Terms
        ]
    }.

resolve({cas, Hash}, _Resolved) -> Hash;
resolve({pending, Seq}, Resolved) -> maps:get(Seq, Resolved).

sha_init(true) -> crypto:hash_init(sha256);
sha_init(false) -> undefined.

sha_update(undefined, _Data) -> undefined;
sha_update(Ctx, Data) -> crypto:hash_update(Ctx, Data).

sha_final(undefined) -> undefined;
sha_final(Ctx) -> crypto:hash_final(Ctx).
