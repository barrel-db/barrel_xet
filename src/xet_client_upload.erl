%% Upload pipeline (spec Section 11): chunk files, plan xorbs and dedup,
%% upload new xorbs, then register a shard. Ties xet_chunker,
%% xet_upload_plan, xet_xorb, and xet_shard to the client's raw calls.
%%
%% Ordering per 11.7: every xorb a shard references is uploaded before
%% the shard. Xorbs upload with bounded parallelism (xet_par); each is
%% encoded (compression + footer) once, reusing that encoding for both
%% the upload and the shard's CAS info.
-module(xet_client_upload).

-export([upload_data/3, upload_file/3, upload_files/2, upload_files/3]).

-define(NS, <<"default">>).
-define(DEDUP_NS, <<"default-merkledb">>).
-define(UPLOAD_CONCURRENCY, 8).

-type upload_result() :: #{file_hash := xet_hash:hash(), stats := map()}.
-export_type([upload_result/0]).

-spec upload_data(xet_client:client(), term(), binary()) ->
    {ok, upload_result()} | {error, term()}.
upload_data(Client, FileId, Data) ->
    case upload_files(Client, [{FileId, Data}]) of
        {ok, [Result]} -> {ok, Result};
        {error, _} = Error -> Error
    end.

-spec upload_file(xet_client:client(), term(), file:filename_all()) ->
    {ok, upload_result()} | {error, term()}.
upload_file(Client, FileId, Path) ->
    case file:read_file(Path) of
        {ok, Data} -> upload_data(Client, FileId, Data);
        {error, _} = Error -> Error
    end.

-spec upload_files(xet_client:client(), [{term(), binary()}]) ->
    {ok, [upload_result()]} | {error, term()}.
upload_files(Client, Files) ->
    upload_files(Client, Files, #{}).

%% Opts: dedup => true (default) enables global dedup queries;
%% concurrency => N bounds parallel xorb uploads.
-spec upload_files(xet_client:client(), [{term(), binary()}], map()) ->
    {ok, [upload_result()]} | {error, term()}.
upload_files(Client, Files, Opts) ->
    Chunked = [{FileId, xet_chunker:split(Data)} || {FileId, Data} <- Files],
    #{xorbs := Xorbs, files := Planned, stats := Stats} = plan(Client, Chunked, Opts),
    Encoded = encode_xorbs(Xorbs),
    maybe
        ok ?= upload_xorbs(Client, Encoded, Opts),
        ok ?= register_shard(Client, Planned, Encoded),
        {ok, [result(F, Stats) || F <- Planned]}
    end.

%%--------------------------------------------------------------------
%% Planning
%%--------------------------------------------------------------------

plan(Client, Chunked, Opts) ->
    Session0 = xet_upload_plan:new(plan_opts(Client, Chunked, Opts)),
    {Emitted, Session1} = lists:foldl(
        fun({FileId, Chunks}, {Acc, S}) ->
            {Xs, S2} = xet_upload_plan:add_file(S, FileId, Chunks),
            {Acc ++ Xs, S2}
        end,
        {[], Session0},
        Chunked
    ),
    Final = xet_upload_plan:finalize(Session1),
    Final#{xorbs := Emitted ++ maps:get(xorbs, Final)}.

plan_opts(_Client, _Chunked, #{dedup := false}) ->
    #{};
plan_opts(Client, Chunked, _Opts) ->
    %% Match every local chunk hash against each dedupe response: one
    %% dedupe shard covers a whole xorb, so a single eligible-chunk query
    %% can dedup all of the client's chunks that live in that xorb.
    KnownHashes = lists:usort([
        xet_hash:chunk_hash(C)
     || {_FileId, Chunks} <- Chunked, C <- Chunks
    ]),
    #{query => fun(ChunkHash) -> query_dedup(Client, ChunkHash, KnownHashes) end}.

query_dedup(Client, ChunkHash, KnownHashes) ->
    case xet_client:query_chunk(Client, ?DEDUP_NS, ChunkHash) of
        {ok, Shard} -> mappings_from_shard(Shard, KnownHashes);
        not_found -> not_found;
        {error, _} -> not_found
    end.

mappings_from_shard(Shard, KnownHashes) ->
    Mappings = [
        {Hash, CasHash, Index}
     || Hash <- KnownHashes,
        {ok, #{cas_hash := CasHash, chunk_index := Index}} <- [xet_dedup:match(Shard, Hash)]
    ],
    case Mappings of
        [] -> not_found;
        _ -> {ok, Mappings}
    end.

%%--------------------------------------------------------------------
%% Xorb upload
%%--------------------------------------------------------------------

%% Encode each planned xorb once: {Hash, Bin, Entries}.
encode_xorbs(Xorbs) ->
    [encode_one(X) || X <- Xorbs].

encode_one(#{hash := Hash, chunks := Chunks}) ->
    {ok, Enc} = xet_xorb:encode(Chunks),
    Hash = maps:get(hash, Enc),
    #{hash => Hash, bin => maps:get(bin, Enc), entries => entries(Enc)}.

entries(Enc) ->
    lists:zip(maps:get(chunk_hashes, Enc), maps:get(unpacked_sizes, Enc)).

upload_xorbs(_Client, [], _Opts) ->
    ok;
upload_xorbs(Client, Encoded, Opts) ->
    Concurrency = maps:get(concurrency, Opts, ?UPLOAD_CONCURRENCY),
    Results = xet_par:map(
        fun(#{hash := Hash, bin := Bin}) -> xet_client:upload_xorb(Client, ?NS, Hash, Bin) end,
        Encoded,
        Concurrency
    ),
    first_error([normalize(R) || R <- Results]).

normalize({ok, _}) -> ok;
normalize(Other) -> Other.

%%--------------------------------------------------------------------
%% Shard registration
%%--------------------------------------------------------------------

register_shard(Client, Planned, Encoded) ->
    Shard = xet_shard:encode_upload(#{
        files => [file_info(F) || F <- Planned],
        cas => [cas_info(E) || E <- Encoded]
    }),
    case xet_client:upload_shard(Client, Shard) of
        {ok, #{result := _}} -> ok;
        {error, _} = Error -> Error
    end.

file_info(File) ->
    Base = #{
        file_hash => maps:get(file_hash, File),
        terms => maps:get(terms, File),
        verification => maps:get(verification, File)
    },
    case maps:get(sha256, File, undefined) of
        undefined -> Base;
        Sha -> Base#{sha256 => Sha}
    end.

cas_info(#{hash := Hash, bin := Bin, entries := Entries}) ->
    #{
        cas_hash => Hash,
        bytes_on_disk => byte_size(Bin),
        chunks => [
            #{hash => H, size => S, dedup_eligible => xet_dedup:hash_eligible(H)}
         || {H, S} <- Entries
        ]
    }.

result(File, Stats) ->
    #{file_hash => maps:get(file_hash, File), stats => Stats}.

first_error([]) -> ok;
first_error([ok | Rest]) -> first_error(Rest);
first_error([{error, _} = Error | _]) -> Error.
