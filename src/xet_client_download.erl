%% Download pipeline (spec Section 12): query reconstruction, fetch the
%% needed xorb byte ranges in parallel, extract chunks, reassemble.
%%
%% One (xorb, chunk index) -> binary map covers every fetched chunk, so a
%% term whose range spans several fetch entries stitches automatically.
%% Fetch URLs need no auth (they carry their own signature); a 403 means
%% an expired URL, so the whole reconstruction is re-queried once. Full
%% downloads recompute and verify the file hash; every term's assembled
%% length is checked against its unpacked_length.
-module(xet_client_download).

-export([download_data/2, download_range/3, download_file/3]).

-define(FETCH_CONCURRENCY, 8).

-spec download_data(xet_client:client(), xet_hash:hash()) ->
    {ok, binary()} | {error, term()}.
download_data(Client, FileHash) ->
    download_range(Client, FileHash, all).

-spec download_file(xet_client:client(), xet_hash:hash(), file:filename_all()) ->
    ok | {error, term()}.
download_file(Client, FileHash, Path) ->
    case download_data(Client, FileHash) of
        {ok, Data} -> file:write_file(Path, Data);
        {error, _} = Error -> Error
    end.

-spec download_range(xet_client:client(), xet_hash:hash(), xet_reconstruction:range()) ->
    {ok, binary()} | {error, term()}.
download_range(Client, FileHash, Range) ->
    with_reconstruction(Client, FileHash, Range, 1).

%% RetriesLeft bounds the expired-URL re-query (single-flight per call).
with_reconstruction(Client, FileHash, Range, RetriesLeft) ->
    case xet_client:get_reconstruction(Client, FileHash, Range) of
        {ok, Recon} ->
            case assemble(Client, FileHash, Recon, Range) of
                {error, url_expired} when RetriesLeft > 0 ->
                    with_reconstruction(Client, FileHash, Range, RetriesLeft - 1);
                Result ->
                    Result
            end;
        {error, _} = Error ->
            Error
    end.

assemble(Client, FileHash, Recon, Range) ->
    Offset = maps:get(<<"offset_into_first_range">>, Recon),
    Terms = terms(Recon),
    Fetches = fetches(Recon),
    Concurrency = maps:get(concurrency, Client, ?FETCH_CONCURRENCY),
    maybe
        {ok, ChunkMap} ?= fetch_all(Fetches, Concurrency),
        {ok, TermChunks} ?= extract_terms(Terms, ChunkMap),
        ok ?= verify_file_hash(FileHash, Range, Offset, TermChunks),
        {ok, output(Range, TermChunks, Offset)}
    end.

%%--------------------------------------------------------------------
%% Response normalization (V1 fetch_info or V2 xorbs)
%%--------------------------------------------------------------------

terms(Recon) ->
    [
        {
            maps:get(<<"hash">>, T),
            range_of(maps:get(<<"range">>, T)),
            maps:get(<<"unpacked_length">>, T)
        }
     || T <- maps:get(<<"terms">>, Recon)
    ].

%% {CasStr, ChunkStart, ChunkEnd, Url, ByteStart, ByteEnd} per fetch.
fetches(#{<<"xorbs">> := Xorbs}) ->
    lists:append([
        [
            fetch_entry(CasStr, maps:get(<<"url">>, Entry), Rng)
         || Rng <- maps:get(<<"ranges">>, Entry)
        ]
     || {CasStr, [Entry]} <- maps:to_list(Xorbs)
    ]);
fetches(#{<<"fetch_info">> := FetchInfo}) ->
    lists:append([
        [v1_entry(CasStr, E) || E <- Entries]
     || {CasStr, Entries} <- maps:to_list(FetchInfo)
    ]).

fetch_entry(CasStr, Url, #{<<"chunks">> := Chunks, <<"bytes">> := Bytes}) ->
    {CS, CE} = range_of(Chunks),
    {BS, BE} = range_of(Bytes),
    {CasStr, CS, CE, Url, BS, BE}.

v1_entry(CasStr, Entry) ->
    {CS, CE} = range_of(maps:get(<<"range">>, Entry)),
    {BS, BE} = range_of(maps:get(<<"url_range">>, Entry)),
    {CasStr, CS, CE, maps:get(<<"url">>, Entry), BS, BE}.

range_of(#{<<"start">> := S, <<"end">> := E}) -> {S, E}.

%%--------------------------------------------------------------------
%% Fetching
%%--------------------------------------------------------------------

fetch_all(Fetches, Concurrency) ->
    Results = xet_par:map(fun fetch_one/1, Fetches, Concurrency),
    combine(Results, #{}).

fetch_one({CasStr, ChunkStart, ChunkEnd, Url, ByteStart, ByteEnd}) ->
    RangeHeader = iolist_to_binary([
        "bytes=", integer_to_binary(ByteStart), "-", integer_to_binary(ByteEnd)
    ]),
    case
        hackney:request(get, Url, [{<<"range">>, RangeHeader}], <<>>, [with_body, {pool, false}])
    of
        %% 206 body is exactly the chunk region; 200 means the backend
        %% ignored Range and returned the whole xorb, so slice it.
        {ok, 206, _, Body} ->
            tagged(CasStr, ChunkStart, xet_xorb:parse_chunk_stream(Body));
        {ok, 200, _, Body} ->
            tagged(CasStr, ChunkStart, xet_xorb:extract_range(Body, ChunkStart, ChunkEnd));
        {ok, 403, _, _} ->
            url_expired;
        {ok, Status, _, _} ->
            {error, {http, Status}};
        {error, _} = Error ->
            Error
    end.

tagged(CasStr, ChunkStart, {ok, Chunks}) -> {ok, {CasStr, ChunkStart, Chunks}};
tagged(_CasStr, _ChunkStart, {error, _} = Error) -> Error.

combine([], Acc) ->
    {ok, Acc};
combine([{ok, {CasStr, Start, Chunks}} | Rest], Acc) ->
    combine(Rest, index_chunks(CasStr, Start, Chunks, Acc));
combine([url_expired | _Rest], _Acc) ->
    {error, url_expired};
combine([{error, Reason} | _Rest], _Acc) ->
    {error, Reason}.

index_chunks(CasStr, Start, Chunks, Acc) ->
    lists:foldl(
        fun({Offset, Chunk}, A) -> maps:put({CasStr, Start + Offset}, Chunk, A) end,
        Acc,
        lists:zip(lists:seq(0, length(Chunks) - 1), Chunks)
    ).

%%--------------------------------------------------------------------
%% Assembly and verification
%%--------------------------------------------------------------------

extract_terms(Terms, ChunkMap) ->
    extract_terms(Terms, ChunkMap, []).

extract_terms([], _ChunkMap, Acc) ->
    {ok, lists:reverse(Acc)};
extract_terms([{CasStr, {Start, End}, Unpacked} | Rest], ChunkMap, Acc) ->
    Chunks = [maps:get({CasStr, I}, ChunkMap) || I <- lists:seq(Start, End - 1)],
    case lists:sum([byte_size(C) || C <- Chunks]) of
        Unpacked -> extract_terms(Rest, ChunkMap, [Chunks | Acc]);
        _ -> {error, unpacked_length_mismatch}
    end.

%% Full downloads (whole file, no skip) re-derive and check the file hash.
verify_file_hash(FileHash, all, 0, TermChunks) ->
    Entries = [
        {xet_hash:chunk_hash(C), byte_size(C)}
     || Chunks <- TermChunks, C <- Chunks
    ],
    case xet_hash:file_hash(Entries) of
        FileHash -> ok;
        _ -> {error, file_hash_mismatch}
    end;
verify_file_hash(_FileHash, _Range, _Offset, _TermChunks) ->
    ok.

output(all, TermChunks, 0) ->
    list_to_binary(TermChunks);
output(Range, TermChunks, Offset) ->
    Full = list_to_binary(TermChunks),
    Avail = byte_size(Full) - Offset,
    Len = requested_length(Range, Avail),
    binary:part(Full, Offset, Len).

requested_length(all, Avail) -> Avail;
requested_length({Start, End}, Avail) -> min(Avail, End - Start + 1).
