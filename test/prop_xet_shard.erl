%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(prop_xet_shard).

-include_lib("proper/include/proper.hrl").

hash32() ->
    binary(32).

gen_term() ->
    ?LET(
        {Cas, Len, Start, Span},
        {hash32(), integer(0, 100000), integer(0, 5000), integer(1, 50)},
        #{cas_hash => Cas, unpacked_len => Len, chunk_start => Start, chunk_end => Start + Span}
    ).

gen_file() ->
    ?LET(
        {Hash, Terms, WithVer, Sha},
        {hash32(), non_empty(resize(5, list(gen_term()))), boolean(), oneof([undefined, hash32()])},
        begin
            F0 = #{file_hash => Hash, terms => Terms},
            F1 =
                case WithVer of
                    true -> F0#{verification => [<<I:256>> || I <- lists:seq(1, length(Terms))]};
                    false -> F0
                end,
            case Sha of
                undefined -> F1;
                _ -> F1#{sha256 => Sha}
            end
        end
    ).

gen_cas() ->
    ?LET(
        {Hash, OnDisk, Chunks},
        {hash32(), integer(0, 1 bsl 30), non_empty(resize(15, list(gen_chunk())))},
        #{cas_hash => Hash, bytes_on_disk => OnDisk, chunks => Chunks}
    ).

gen_chunk() ->
    ?LET(
        {Hash, Size, Eligible},
        {hash32(), integer(1, 131072), boolean()},
        #{hash => Hash, size => Size, dedup_eligible => Eligible}
    ).

gen_shard() ->
    ?LET(
        {Files, Cas},
        {resize(4, list(gen_file())), resize(4, list(gen_cas()))},
        #{files => Files, cas => Cas}
    ).

prop_upload_roundtrip() ->
    ?FORALL(
        Shard,
        gen_shard(),
        begin
            {ok, Dec} = xet_shard:decode(xet_shard:encode_upload(Shard)),
            maps:get(files, Dec) =:= maps:get(files, Shard) andalso
                maps:get(cas, Dec) =:= maps:get(cas, Shard) andalso
                maps:get(footer, Dec) =:= undefined
        end
    ).

prop_stored_roundtrip() ->
    ?FORALL(
        {Shard, Key, Created, Expiry},
        {gen_shard(), hash32(), integer(0, 1 bsl 40), integer(0, 1 bsl 40)},
        begin
            Bin = xet_shard:encode_stored(Shard, #{
                chunk_hash_key => Key, created_at => Created, key_expiry => Expiry
            }),
            {ok, Dec} = xet_shard:decode(Bin),
            Footer = maps:get(footer, Dec),
            maps:get(files, Dec) =:= maps:get(files, Shard) andalso
                maps:get(cas, Dec) =:= maps:get(cas, Shard) andalso
                maps:get(chunk_hash_key, Footer) =:= Key andalso
                maps:get(created_at, Footer) =:= Created andalso
                maps:get(key_expiry, Footer) =:= Expiry
        end
    ).

prop_upload_deterministic() ->
    ?FORALL(
        Shard,
        gen_shard(),
        xet_shard:encode_upload(Shard) =:= xet_shard:encode_upload(Shard)
    ).
