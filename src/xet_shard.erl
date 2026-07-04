%% Shard codec (spec Section 9): binary metadata describing file
%% reconstructions (file info section) and xorb contents (CAS info
%% section).
%%
%% Two forms:
%%   upload form: header (footer_size 0) + file info + CAS info, exactly
%%   what POST /shards carries;
%%   stored form: adds three sorted lookup tables and the 200-byte footer
%%   (encode_stored/2), used for dedupe responses and at-rest shards.
%%
%% Footer and lookup tables live in xet_shard_footer.
-module(xet_shard).

-export([encode_upload/1, encode_stored/2, decode/1, decode_prefix/1]).

-include("xet_shard.hrl").

-type file_term() :: #{
    cas_hash := xet_hash:hash(),
    unpacked_len := non_neg_integer(),
    chunk_start := non_neg_integer(),
    chunk_end := pos_integer()
}.
-type file_info() :: #{
    file_hash := xet_hash:hash(),
    terms := [file_term()],
    verification => [xet_hash:hash()],
    sha256 => xet_hash:hash()
}.
-type cas_chunk() :: #{
    hash := xet_hash:hash(),
    size := non_neg_integer(),
    dedup_eligible => boolean()
}.
-type cas_info() :: #{
    cas_hash := xet_hash:hash(),
    bytes_on_disk := non_neg_integer(),
    chunks := [cas_chunk()]
}.
-type shard() :: #{
    files := [file_info()],
    cas := [cas_info()],
    footer := undefined | xet_shard_footer:footer()
}.
-export_type([file_term/0, file_info/0, cas_chunk/0, cas_info/0, shard/0]).

-spec encode_upload(#{files := [file_info()], cas := [cas_info()]}) -> binary().
encode_upload(#{files := Files, cas := Cas}) ->
    Body = [file_section(Files), cas_section(Cas)],
    iolist_to_binary([header(0), Body]).

-spec encode_stored(#{files := [file_info()], cas := [cas_info()]}, map()) -> binary().
encode_stored(#{files := Files, cas := Cas}, FooterOpts) ->
    FileSection = iolist_to_binary(file_section(Files)),
    CasSection = iolist_to_binary(cas_section(Cas)),
    FileOffset = ?SHARD_HEADER_SIZE,
    CasOffset = FileOffset + byte_size(FileSection),
    Tail = xet_shard_footer:encode(
        Files, Cas, FileOffset, CasOffset, CasOffset + byte_size(CasSection), FooterOpts
    ),
    iolist_to_binary([header(?SHARD_FOOTER_SIZE), FileSection, CasSection, Tail]).

header(FooterSize) ->
    [?SHARD_TAG, <<?SHARD_VERSION:64/little, FooterSize:64/little>>].

file_section(Files) ->
    [[file_block(F) || F <- Files], ?SHARD_BOOKEND].

file_block(#{file_hash := Hash, terms := Terms} = File) when Terms =/= [] ->
    Verification = maps:get(verification, File, undefined),
    Sha256 = maps:get(sha256, File, undefined),
    Flags = ver_flag(Verification) bor ext_flag(Sha256),
    N = length(Terms),
    ok = check_verification(Verification, N),
    [
        <<Hash:32/binary, Flags:32/little, N:32/little, 0:64>>,
        [term_entry(T) || T <- Terms],
        [<<V:32/binary, 0:128>> || Verification =/= undefined, V <- Verification],
        [<<S:32/binary, 0:128>> || Sha256 =/= undefined, S <- [Sha256]]
    ].

ver_flag(undefined) -> 0;
ver_flag(_) -> ?FILE_FLAG_WITH_VERIFICATION.

ext_flag(undefined) -> 0;
ext_flag(_) -> ?FILE_FLAG_WITH_METADATA_EXT.

check_verification(undefined, _N) -> ok;
check_verification(V, N) when length(V) =:= N -> ok.

term_entry(#{
    cas_hash := Cas, unpacked_len := Len, chunk_start := Start, chunk_end := End
}) when End > Start ->
    <<Cas:32/binary, 0:32, Len:32/little, Start:32/little, End:32/little>>.

cas_section(Blocks) ->
    [[cas_block(B) || B <- Blocks], ?SHARD_BOOKEND].

cas_block(#{cas_hash := Hash, bytes_on_disk := OnDisk, chunks := Chunks}) when Chunks =/= [] ->
    N = length(Chunks),
    Total = lists:sum([maps:get(size, C) || C <- Chunks]),
    [
        <<Hash:32/binary, 0:32, N:32/little, Total:32/little, OnDisk:32/little>>,
        chunk_entries(Chunks, 0)
    ].

chunk_entries([], _Offset) ->
    [];
chunk_entries([#{hash := Hash, size := Size} = C | Rest], Offset) ->
    Flags = eligible_flag(maps:get(dedup_eligible, C, false)),
    [
        <<Hash:32/binary, Offset:32/little, Size:32/little, Flags:32/little, 0:32>>
        | chunk_entries(Rest, Offset + Size)
    ].

eligible_flag(true) -> ?CHUNK_FLAG_GLOBAL_DEDUP_ELIGIBLE;
eligible_flag(false) -> 0.

%% Decode either form. The magic sequence is verified byte for byte; the
%% application id is surfaced, not enforced.
-spec decode(binary()) -> {ok, shard()} | {error, term()}.
decode(
    <<_AppId:14/binary, 0, Magic:17/binary, Version:64/little, FooterSize:64/little, Rest/binary>>
) when
    Magic =:= ?SHARD_MAGIC_SEQUENCE
->
    case {Version, FooterSize} of
        {?SHARD_VERSION, 0} -> decode_body(Rest, undefined);
        {?SHARD_VERSION, ?SHARD_FOOTER_SIZE} -> decode_stored(Rest);
        {?SHARD_VERSION, _} -> {error, bad_footer_size};
        _ -> {error, bad_version}
    end;
decode(Bin) when byte_size(Bin) >= ?SHARD_HEADER_SIZE ->
    {error, bad_magic};
decode(_) ->
    {error, truncated}.

%% Tolerant parse for the upload endpoint: header plus the two body
%% sections, ignoring whatever follows (zig-xet posts a footered form
%% with non-conformant lookup offsets; the body is still good). Returns
%% the declared footer_size and the unparsed tail.
-spec decode_prefix(binary()) ->
    {ok, shard(), non_neg_integer(), binary()} | {error, term()}.
decode_prefix(
    <<_AppId:14/binary, 0, Magic:17/binary, Version:64/little, FooterSize:64/little, Rest/binary>>
) when Magic =:= ?SHARD_MAGIC_SEQUENCE ->
    case Version of
        ?SHARD_VERSION ->
            maybe
                {ok, Files, AfterFiles} ?= file_blocks(Rest, []),
                {ok, Cas, Tail} ?= cas_blocks(AfterFiles, []),
                {ok, #{files => Files, cas => Cas, footer => undefined}, FooterSize, Tail}
            end;
        _ ->
            {error, bad_version}
    end;
decode_prefix(Bin) when byte_size(Bin) >= ?SHARD_HEADER_SIZE ->
    {error, bad_magic};
decode_prefix(_) ->
    {error, truncated}.

decode_stored(Rest) ->
    case xet_shard_footer:decode(Rest) of
        {ok, Footer, BodyEnd, Counts} ->
            BodyLen = BodyEnd - ?SHARD_HEADER_SIZE,
            LookupLen = byte_size(Rest) - BodyLen - ?SHARD_FOOTER_SIZE,
            <<Body:BodyLen/binary, Lookups:LookupLen/binary, _:?SHARD_FOOTER_SIZE/binary>> = Rest,
            checked_body(Body, Lookups, Counts, Footer);
        {error, _} = Error ->
            Error
    end.

%% Lookup tables are trusted at three levels: byte-identical to our own
%% regeneration (our encoder, full tables), empty (the reference tooling
%% writes zero-length tables), or at minimum sorted by truncated hash
%% (foreign emitters may index a subset).
checked_body(Body, Lookups, Counts, Footer) ->
    case decode_body(Body, Footer) of
        {ok, #{files := Files, cas := Cas}} = Ok ->
            {F, C, Ch} = xet_shard_footer:encode_lookups(Files, Cas),
            Regenerated = <<F/binary, C/binary, Ch/binary>>,
            case Lookups =:= Regenerated orelse sorted_lookups(Lookups, Counts) of
                true -> Ok;
                false -> {error, bad_lookup_tables}
            end;
        {error, _} = Error ->
            Error
    end.

sorted_lookups(Lookups, {NF, NC, NCh}) ->
    FBytes = 12 * NF,
    CBytes = 12 * NC,
    ChBytes = 16 * NCh,
    case Lookups of
        <<FTab:FBytes/binary, CTab:CBytes/binary, ChTab:ChBytes/binary>> ->
            sorted12(FTab) andalso sorted12(CTab) andalso sorted16(ChTab);
        _ ->
            false
    end.

sorted12(Tab) -> sorted_keys([T || <<T:64/little, _:32>> <= Tab]).
sorted16(Tab) -> sorted_keys([T || <<T:64/little, _:64>> <= Tab]).

sorted_keys(Keys) -> Keys =:= lists:sort(Keys).

decode_body(Bin, Footer) ->
    maybe
        {ok, Files, AfterFiles} ?= file_blocks(Bin, []),
        {ok, Cas, AfterCas} ?= cas_blocks(AfterFiles, []),
        ok ?= expect_end(AfterCas, Footer),
        {ok, #{files => Files, cas => Cas, footer => Footer}}
    end.

expect_end(<<>>, _Footer) -> ok;
expect_end(_, _) -> {error, trailing_data}.

file_blocks(<<Bookend:48/binary, Rest/binary>>, Acc) when Bookend =:= ?SHARD_BOOKEND_BIN ->
    {ok, lists:reverse(Acc), Rest};
file_blocks(
    <<Hash:32/binary, Flags:32/little, N:32/little, 0:64, Rest/binary>>, Acc
) when N >= 1 ->
    WithVer = Flags band ?FILE_FLAG_WITH_VERIFICATION =/= 0,
    WithExt = Flags band ?FILE_FLAG_WITH_METADATA_EXT =/= 0,
    case Flags band (bnot (?FILE_FLAG_WITH_VERIFICATION bor ?FILE_FLAG_WITH_METADATA_EXT)) of
        0 -> file_block_body(Rest, Hash, N, WithVer, WithExt, Acc);
        _ -> {error, bad_file_flags}
    end;
file_blocks(_, _Acc) ->
    {error, bad_file_block}.

file_block_body(Bin, Hash, N, WithVer, WithExt, Acc) ->
    maybe
        {ok, Terms, R1} ?= take_terms(Bin, N, []),
        {ok, Verification, R2} ?= take_verification(R1, N, WithVer),
        {ok, Sha256, R3} ?= take_ext(R2, WithExt),
        File0 = #{file_hash => Hash, terms => Terms},
        File1 = put_opt(verification, Verification, File0),
        File2 = put_opt(sha256, Sha256, File1),
        file_blocks(R3, [File2 | Acc])
    end.

take_terms(Bin, 0, Acc) ->
    {ok, lists:reverse(Acc), Bin};
take_terms(
    <<Cas:32/binary, 0:32, Len:32/little, Start:32/little, End:32/little, Rest/binary>>, N, Acc
) when End > Start ->
    Term = #{cas_hash => Cas, unpacked_len => Len, chunk_start => Start, chunk_end => End},
    take_terms(Rest, N - 1, [Term | Acc]);
take_terms(_, _, _) ->
    {error, bad_term_entry}.

take_verification(Bin, _N, false) ->
    {ok, undefined, Bin};
take_verification(Bin, N, true) ->
    take_hash48(Bin, N, []).

take_hash48(Bin, 0, Acc) ->
    {ok, lists:reverse(Acc), Bin};
take_hash48(<<Hash:32/binary, 0:128, Rest/binary>>, N, Acc) ->
    take_hash48(Rest, N - 1, [Hash | Acc]);
take_hash48(_, _, _) ->
    {error, bad_verification_entry}.

take_ext(Bin, false) ->
    {ok, undefined, Bin};
take_ext(<<Sha:32/binary, 0:128, Rest/binary>>, true) ->
    {ok, Sha, Rest};
take_ext(_, true) ->
    {error, bad_metadata_ext}.

put_opt(_Key, undefined, Map) -> Map;
put_opt(Key, Value, Map) -> Map#{Key => Value}.

cas_blocks(<<Bookend:48/binary, Rest/binary>>, Acc) when Bookend =:= ?SHARD_BOOKEND_BIN ->
    {ok, lists:reverse(Acc), Rest};
cas_blocks(
    <<Hash:32/binary, 0:32, N:32/little, Total:32/little, OnDisk:32/little, Rest/binary>>, Acc
) when N >= 1 ->
    case take_chunks(Rest, N, 0, []) of
        {ok, Chunks, Total, R1} ->
            Block = #{cas_hash => Hash, bytes_on_disk => OnDisk, chunks => Chunks},
            cas_blocks(R1, [Block | Acc]);
        {ok, _Chunks, _OtherTotal, _} ->
            {error, cas_bytes_mismatch};
        {error, _} = Error ->
            Error
    end;
cas_blocks(_, _Acc) ->
    {error, bad_cas_block}.

take_chunks(Bin, 0, Offset, Acc) ->
    {ok, lists:reverse(Acc), Offset, Bin};
take_chunks(
    <<Hash:32/binary, Start:32/little, Size:32/little, Flags:32/little, 0:32, Rest/binary>>,
    N,
    Offset,
    Acc
) when Start =:= Offset, Flags band (bnot ?CHUNK_FLAG_GLOBAL_DEDUP_ELIGIBLE) =:= 0 ->
    Chunk = #{
        hash => Hash,
        size => Size,
        dedup_eligible => Flags band ?CHUNK_FLAG_GLOBAL_DEDUP_ELIGIBLE =/= 0
    },
    take_chunks(Rest, N - 1, Offset + Size, [Chunk | Acc]);
take_chunks(_, _, _, _) ->
    {error, bad_chunk_entry}.
