%% Aggregated hash tree with variable fan-out (spec Section 6.2.2).
%%
%% Not a binary Merkle tree: a list of {hash, size} pairs is collapsed
%% iteratively; cut points are derived from the hash values themselves
%% (mean branching factor 4, between 2 and 9 children per node).
-module(xet_merkle).

-export([root/1, next_merge_cut/1]).

-define(MEAN_BRANCHING_FACTOR, 4).
-define(MAX_CHILDREN, 9).

-spec root([xet_hash:entry()]) -> xet_hash:hash().
root([]) ->
    xet_hash:zero_hash();
root(Entries) ->
    collapse(Entries).

collapse([{Hash, _Size}]) ->
    Hash;
collapse(Entries) ->
    collapse(merge_pass(Entries, [])).

merge_pass([], Acc) ->
    lists:reverse(Acc);
merge_pass(Entries, Acc) ->
    Cut = next_merge_cut(Entries),
    {Group, Rest} = lists:split(Cut, Entries),
    merge_pass(Rest, [merged_hash_of_sequence(Group) | Acc]).

%% Number of leading entries to merge into the next node. With more than
%% two entries left, the minimum merge is 3; a cut fires at the first
%% index >= 2 whose hash tail (bytes 24..31, little-endian u64) is
%% divisible by the mean branching factor.
-spec next_merge_cut([xet_hash:entry()]) -> non_neg_integer().
next_merge_cut(Entries) when length(Entries) =< 2 ->
    length(Entries);
next_merge_cut(Entries) ->
    End = min(?MAX_CHILDREN, length(Entries)),
    Candidates = lists:sublist(Entries, 3, End - 2),
    find_cut(Candidates, 2, End).

find_cut([], _I, End) ->
    End;
find_cut([{Hash, _} | Rest], I, End) ->
    <<_:24/binary, Tail:64/little>> = Hash,
    case Tail rem ?MEAN_BRANCHING_FACTOR of
        0 -> I + 1;
        _ -> find_cut(Rest, I + 1, End)
    end.

%% Section 6.2.2.3: children are hashed as text lines "<hex> : <size>\n".
merged_hash_of_sequence(Pairs) ->
    Buffer = [
        [xet_hash:to_string(Hash), <<" : ">>, integer_to_binary(Size), $\n]
     || {Hash, Size} <- Pairs
    ],
    TotalSize = lists:sum([Size || {_, Size} <- Pairs]),
    {xet_hash:internal_node_hash(Buffer), TotalSize}.
