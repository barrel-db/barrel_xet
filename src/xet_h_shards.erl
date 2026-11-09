%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Shard registration (spec Appendix A.6): POST /v1/shards (and bare
%% /shards, which xet-core uses).
%%
%% The upload form is parsed tolerantly: a trailing footer is accepted
%% and ignored (zig-xet always sends one), the body sections are not.
%% Every referenced xorb must already exist; the shard's CAS layout, file
%% hashes and verification hashes are checked against the server's own
%% metadata before anything registers. Already-registered files are kept
%% as they are. result 0 means every file hash was already present, 1
%% that registration happened.
-module(xet_h_shards).

-export([upload/1]).

upload(Req) ->
    Env = xet_server:env(livery_req:config(server, Req)),
    #{config := Config} = Env,
    case xet_h_upload:preflight(Config, max_shard_bytes) of
        ok -> read_and_register(Req, Env, Config);
        {error, Resp} -> Resp
    end.

read_and_register(Req, Env, Config) ->
    SpoolOpts = #{
        cap => maps:get(max_shard_bytes, Config),
        memory_max => maps:get(spool_memory_max, Config),
        spool_dir => filename:join(maps:get(data_dir, Config), "spool")
    },
    case xet_http_body:read_spooled(Req, SpoolOpts) of
        {ok, Spooled} ->
            Result = handle_shard(Env, xet_http_body:binary_of(Spooled)),
            ok = xet_http_body:cleanup(Spooled),
            Result;
        {error, Reason} ->
            xet_routes:error_response(400, Reason)
    end.

handle_shard(Env, Bin) ->
    case xet_shard:decode_prefix(Bin) of
        {ok, Shard, FooterSize, Tail} when Tail =:= <<>>; FooterSize > 0 ->
            validate_shard(Env, Shard);
        {ok, _Shard, 0, _Tail} ->
            xet_routes:error_response(400, <<"trailing_data">>);
        {error, Reason} ->
            xet_routes:error_response(400, atom_to_binary(Reason))
    end.

%% The whole validate-and-register runs in the GC guard's shared
%% section, so GC cannot delete a referenced xorb between the existence
%% check and the file commit. The referenced xorbs are noted AFTER the
%% commit (still inside the section): GC's mark reads a snapshot taken at
%% its start, so any commit it missed happened after that start, and its
%% note is later still, so a concurrent sweep sees the note and skips
%% those xorbs.
validate_shard(#{metadata := Metadata} = Env, #{files := Files, cas := Cas}) ->
    Referenced = referenced_hashes(Files, Cas),
    xet_gc_guard:in_registration(fun() ->
        maybe
            {ok, Xorbs} ?= load_xorbs(Referenced, Metadata, #{}),
            ok ?= check_cas_layout(Cas, Xorbs),
            ok ?= check_files(Files, Xorbs),
            Resp = register_shard(Env, Files, Cas, Xorbs),
            xet_gc_guard:note_referenced(Referenced),
            Resp
        else
            {error, Reason} -> xet_routes:error_response(400, Reason)
        end
    end).

referenced_hashes(Files, Cas) ->
    lists:usort(
        [maps:get(cas_hash, T) || F <- Files, T <- maps:get(terms, F)] ++
            [maps:get(cas_hash, B) || B <- Cas]
    ).

load_xorbs([], _Metadata, Acc) ->
    {ok, Acc};
load_xorbs([Hash | Rest], Metadata, Acc) ->
    case xet_metadata:get_xorb(Metadata, Hash) of
        {ok, Meta} -> load_xorbs(Rest, Metadata, maps:put(Hash, Meta, Acc));
        not_found -> {error, <<"missing_xorb">>}
    end.

%% The shard's CAS blocks are claims about xorbs we already hold; they
%% must agree with the authoritative layout.
check_cas_layout([], _Xorbs) ->
    ok;
check_cas_layout([#{cas_hash := Hash, chunks := Chunks} | Rest], Xorbs) ->
    #{entries := Entries} = maps:get(Hash, Xorbs),
    Claimed = [{maps:get(hash, C), maps:get(size, C)} || C <- Chunks],
    case Claimed =:= Entries of
        true -> check_cas_layout(Rest, Xorbs);
        false -> {error, <<"cas_mismatch">>}
    end.

check_files([], _Xorbs) ->
    ok;
check_files([File | Rest], Xorbs) ->
    maybe
        ok ?= check_term_bounds(maps:get(terms, File), Xorbs),
        ok ?= check_file_hash(File, Xorbs),
        ok ?= check_verification(File, Xorbs),
        check_files(Rest, Xorbs)
    end.

check_term_bounds([], _Xorbs) ->
    ok;
check_term_bounds([#{cas_hash := Hash, chunk_end := End} = T | Rest], Xorbs) ->
    #{entries := Entries} = maps:get(Hash, Xorbs),
    Sizes = term_sizes(T, Entries),
    case End =< length(Entries) andalso lists:sum(Sizes) =:= maps:get(unpacked_len, T) of
        true -> check_term_bounds(Rest, Xorbs);
        false -> {error, <<"bad_term">>}
    end.

check_verification(#{terms := Terms} = File, Xorbs) ->
    case maps:get(verification, File, undefined) of
        undefined ->
            ok;
        Verification ->
            Expected = [
                xet_hash:verification_hash(term_hashes(T, Xorbs))
             || T <- Terms
            ],
            case Expected =:= Verification of
                true -> ok;
                false -> {error, <<"bad_verification">>}
            end
    end.

%% The file hash is derived from the chunks the terms name (spec 6.3); a
%% shard cannot claim a hash its terms do not produce (14.1).
check_file_hash(#{file_hash := FileHash, terms := Terms}, Xorbs) ->
    Entries = lists:append([term_entries(T, Xorbs) || T <- Terms]),
    case xet_hash:file_hash(Entries) of
        FileHash -> ok;
        _ -> {error, <<"file_hash_mismatch">>}
    end.

term_entries(#{cas_hash := Hash, chunk_start := S, chunk_end := E}, Xorbs) ->
    #{entries := Entries} = maps:get(Hash, Xorbs),
    lists:sublist(Entries, S + 1, E - S).

term_hashes(Term, Xorbs) ->
    [H || {H, _} <- term_entries(Term, Xorbs)].

term_sizes(#{chunk_start := S, chunk_end := E}, Entries) ->
    [Size || {_, Size} <- lists:sublist(Entries, S + 1, E - S)].

%% Keep-first: a file hash already registered is never rewritten. Its
%% content is identical by hash, so a new term layout gains nothing.
register_shard(#{metadata := Metadata}, Files, Cas, Xorbs) ->
    New = [F || F <- Files, not xet_metadata:file_exists(Metadata, maps:get(file_hash, F))],
    FileMetas = [file_meta(F) || F <- New],
    Eligible = eligible_chunks(Files, Cas, Xorbs),
    case xet_metadata:register_files(Metadata, FileMetas, Eligible) of
        ok ->
            xet_metrics:count(<<"xet.shards.registered">>, 1),
            xet_metrics:count(<<"xet.files.registered">>, length(FileMetas)),
            Result =
                case New of
                    [] -> 0;
                    _ -> 1
                end,
            livery_resp:json(200, json:encode(#{result => Result}));
        {error, Reason} ->
            logger:error("shard registration failed: ~p", [Reason]),
            xet_h_upload:storage_error(Reason)
    end.

file_meta(File) ->
    Terms = maps:get(terms, File),
    Base = #{
        file_hash => maps:get(file_hash, File),
        total_len => lists:sum([maps:get(unpacked_len, T) || T <- Terms]),
        terms => Terms
    },
    with_optional(sha256, File, with_optional(verification, File, Base)).

with_optional(Key, Source, Map) ->
    case maps:find(Key, Source) of
        {ok, Value} -> maps:put(Key, Value, Map);
        error -> Map
    end.

%% Chunks worth indexing for global dedup: flagged in the shard,
%% selected by the hash rule, or the first chunk of a registered file.
eligible_chunks(Files, Cas, Xorbs) ->
    FromCas = [
        {maps:get(hash, C), maps:get(cas_hash, B), Idx}
     || B <- Cas,
        {Idx, C} <- enumerate(maps:get(chunks, B)),
        maps:get(dedup_eligible, C, false) orelse xet_dedup:hash_eligible(maps:get(hash, C))
    ],
    FirstChunks = [first_chunk_entry(F, Xorbs) || F <- Files, maps:get(terms, F) =/= []],
    lists:usort(FromCas ++ FirstChunks).

first_chunk_entry(#{terms := [First | _]}, Xorbs) ->
    #{cas_hash := CasHash, chunk_start := S} = First,
    #{entries := Entries} = maps:get(CasHash, Xorbs),
    {Hash, _} = lists:nth(S + 1, Entries),
    {Hash, CasHash, S}.

enumerate(List) ->
    lists:zip(lists:seq(0, length(List) - 1), List).
