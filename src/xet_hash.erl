%% Hash string representation (spec Section 6.5).
%%
%% A 32-byte hash is displayed as four little-endian 64-bit values, each
%% printed as 16 lowercase hex digits: equivalent to reversing the byte
%% order inside each 8-byte segment, then hex encoding.
%%
%% Domain-separation keys and the hash computations land with T1.4.
-module(xet_hash).

-export([to_string/1, from_string/1, is_hash_string/1]).

-type hash() :: <<_:256>>.
-type hash_string() :: <<_:512>>.

-export_type([hash/0, hash_string/0]).

-spec to_string(hash()) -> hash_string().
to_string(Hash) when byte_size(Hash) =:= 32 ->
    Swapped = <<<<S:64/big>> || <<S:64/little>> <= Hash>>,
    binary:encode_hex(Swapped, lowercase).

%% Strict inverse: only the canonical lowercase form is accepted.
-spec from_string(hash_string()) -> hash().
from_string(Str) ->
    case is_hash_string(Str) of
        true ->
            Raw = binary:decode_hex(Str),
            <<<<S:64/little>> || <<S:64/big>> <= Raw>>;
        false ->
            error(badarg)
    end.

-spec is_hash_string(term()) -> boolean().
is_hash_string(Str) when is_binary(Str), byte_size(Str) =:= 64 ->
    lowercase_hex(Str);
is_hash_string(_) ->
    false.

lowercase_hex(<<C, Rest/binary>>) when C >= $0, C =< $9 ->
    lowercase_hex(Rest);
lowercase_hex(<<C, Rest/binary>>) when C >= $a, C =< $f ->
    lowercase_hex(Rest);
lowercase_hex(<<>>) ->
    true;
lowercase_hex(_) ->
    false.
