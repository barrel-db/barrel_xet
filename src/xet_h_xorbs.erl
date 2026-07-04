%% Xorb endpoints (spec Appendix A.5):
%%   POST /v1/xorbs/{ns}/{hash}: spool the body (memory below a
%%   threshold, disk above), validate the WHOLE xorb (footered or bare
%%   chunk stream, recomputed hashes, path hash equality) and only then
%%   commit: blob put first, metadata second. Failed validation deletes
%%   the spool and nothing reaches the blob store.
%%   HEAD /v1/xorbs/{ns}/{hash}: existence check against metadata.
-module(xet_h_xorbs).

-export([upload/1, head/1]).

upload(Req) ->
    Env = xet_server:env(livery_req:config(server, Req)),
    case request_target(Req, Env) of
        {ok, Ns, Hash} -> upload_checked(Req, Env, Ns, Hash);
        {error, Resp} -> Resp
    end.

upload_checked(Req, Env, Ns, Hash) ->
    #{metadata := Metadata} = Env,
    case xet_metadata:xorb_exists(Metadata, Hash) of
        true ->
            reply_inserted(false);
        false ->
            case spool_body(Req, Env) of
                {ok, Spooled} -> validate_and_commit(Env, Ns, Hash, Spooled);
                {error, Reason} -> xet_routes:error_response(400, Reason)
            end
    end.

validate_and_commit(Env, Ns, Hash, Spooled) ->
    Bin = spooled_binary(Spooled),
    Result =
        case xet_xorb:decode_any(Bin) of
            {ok, #{hash := Hash} = Decoded} ->
                commit(Env, Ns, Hash, Bin, Decoded);
            {ok, #{hash := _Other}} ->
                xet_routes:error_response(400, <<"hash_mismatch">>);
            {error, Reason} ->
                xet_routes:error_response(400, reason_to_binary(Reason))
        end,
    cleanup(Spooled),
    Result.

commit(#{metadata := Metadata, blob := Blob}, Ns, Hash, Bin, Decoded) ->
    Meta = #{
        hash => Hash,
        entries => lists:zip(
            maps:get(chunk_hashes, Decoded),
            [byte_size(C) || C <- maps:get(chunks, Decoded)]
        ),
        boundary_offsets => maps:get(boundary_offsets, Decoded),
        unpacked_offsets => maps:get(unpacked_offsets, Decoded),
        bytes_on_disk => byte_size(Bin)
    },
    maybe
        ok ?= xet_blob_store:put(Blob, Ns, Hash, Bin),
        ok ?= xet_metadata:register_xorb(Metadata, Meta),
        reply_inserted(true)
    else
        {error, _} -> xet_routes:error_response(500, <<"storage_error">>)
    end.

head(Req) ->
    Env = xet_server:env(livery_req:config(server, Req)),
    case request_target(Req, Env) of
        {ok, _Ns, Hash} ->
            #{metadata := Metadata} = Env,
            case xet_metadata:xorb_exists(Metadata, Hash) of
                true -> livery_resp:empty(200);
                false -> livery_resp:empty(404)
            end;
        {error, Resp} ->
            Resp
    end.

%% Shared: namespace allowlist + strict hash string validation.
request_target(Req, #{config := Config}) ->
    Ns = livery_req:binding(<<"ns">>, Req),
    HashStr = livery_req:binding(<<"hash">>, Req),
    Allowed = lists:member(Ns, maps:get(namespaces, Config)),
    case {Allowed, xet_hash:is_hash_string(HashStr)} of
        {true, true} -> {ok, Ns, xet_hash:from_string(HashStr)};
        {false, _} -> {error, xet_routes:error_response(400, <<"unknown_namespace">>)};
        {_, false} -> {error, xet_routes:error_response(400, <<"bad_hash">>)}
    end.

reply_inserted(Inserted) ->
    livery_resp:json(200, json:encode(#{was_inserted => Inserted})).

%%--------------------------------------------------------------------
%% Body spooling
%%--------------------------------------------------------------------

spool_body(Req, #{config := Config}) ->
    Cap = maps:get(max_xorb_bytes, Config),
    MemMax = maps:get(spool_memory_max, Config),
    SpoolDir = filename:join(maps:get(data_dir, Config), "spool"),
    case livery_req:body(Req) of
        empty ->
            {error, <<"empty_body">>};
        {buffered, IoData} ->
            check_cap(iolist_to_binary(IoData), Cap);
        {stream, Reader} ->
            read_stream(Reader, Cap, MemMax, SpoolDir, 0, [])
    end.

check_cap(Bin, Cap) when byte_size(Bin) =< Cap -> {ok, {memory, Bin}};
check_cap(_Bin, _Cap) -> {error, <<"too_large">>}.

read_stream(Reader, Cap, MemMax, SpoolDir, Size, Acc) ->
    case livery_body:read(Reader, 30000) of
        {ok, Chunk, Reader1} ->
            Size1 = Size + byte_size(Chunk),
            case Size1 > Cap of
                true ->
                    {error, <<"too_large">>};
                false when Size1 > MemMax ->
                    to_disk(Reader1, Cap, SpoolDir, Size1, [Chunk | Acc]);
                false ->
                    read_stream(Reader1, Cap, MemMax, SpoolDir, Size1, [Chunk | Acc])
            end;
        {done, _Reader1} ->
            {ok, {memory, iolist_to_binary(lists:reverse(Acc))}};
        {error, Reason, _Reader1} ->
            {error, reason_to_binary(Reason)}
    end.

%% Spill to a spool file once the memory threshold is crossed.
to_disk(Reader, Cap, SpoolDir, Size, Acc) ->
    ok = filelib:ensure_path(SpoolDir),
    Path = filename:join(
        SpoolDir, "upload." ++ integer_to_list(erlang:unique_integer([positive])) ++ ".tmp"
    ),
    {ok, Fd} = file:open(Path, [write, raw, binary]),
    ok = file:write(Fd, lists:reverse(Acc)),
    drain_to_disk(Reader, Cap, Size, Fd, Path).

drain_to_disk(Reader, Cap, Size, Fd, Path) ->
    case livery_body:read(Reader, 30000) of
        {ok, Chunk, Reader1} ->
            Size1 = Size + byte_size(Chunk),
            case Size1 > Cap of
                true ->
                    abort_disk(Fd, Path, <<"too_large">>);
                false ->
                    ok = file:write(Fd, Chunk),
                    drain_to_disk(Reader1, Cap, Size1, Fd, Path)
            end;
        {done, _} ->
            ok = file:close(Fd),
            {ok, {file, Path}};
        {error, Reason, _} ->
            abort_disk(Fd, Path, reason_to_binary(Reason))
    end.

abort_disk(Fd, Path, Reason) ->
    _ = file:close(Fd),
    _ = file:delete(Path),
    {error, Reason}.

spooled_binary({memory, Bin}) ->
    Bin;
spooled_binary({file, Path}) ->
    {ok, Bin} = file:read_file(Path),
    Bin.

cleanup({memory, _}) -> ok;
cleanup({file, Path}) -> file:delete(Path).

reason_to_binary(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason);
reason_to_binary(Reason) ->
    iolist_to_binary(io_lib:format("~0p", [Reason])).
