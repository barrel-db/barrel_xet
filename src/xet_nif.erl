%% Native primitives for the XET protocol (see c_src/).
%%
%% Inputs above ?DIRTY_THRESHOLD bytes run on dirty CPU schedulers so
%% chunk-sized and xorb-sized workloads never block normal schedulers.
-module(xet_nif).

-export([blake3_keyed/2]).

-nifs([blake3_keyed_nif/2, blake3_keyed_dirty_nif/2]).
-on_load(init/0).

-define(DIRTY_THRESHOLD, 16384).

%% BLAKE3 keyed hash: 32-byte key, 32-byte digest.
-spec blake3_keyed(<<_:256>>, iodata()) -> <<_:256>>.
blake3_keyed(Key, Data) when is_binary(Key), byte_size(Key) =:= 32 ->
    case iolist_size(Data) > ?DIRTY_THRESHOLD of
        true -> blake3_keyed_dirty_nif(Key, Data);
        false -> blake3_keyed_nif(Key, Data)
    end.

init() ->
    erlang:load_nif(filename:join(priv_dir(), "xet_nif"), 0).

priv_dir() ->
    case code:priv_dir(barrel_xet) of
        {error, bad_name} ->
            Ebin = filename:dirname(code:which(?MODULE)),
            filename:join(filename:dirname(Ebin), "priv");
        Dir ->
            Dir
    end.

blake3_keyed_nif(_Key, _Data) ->
    erlang:nif_error(nif_not_loaded).

blake3_keyed_dirty_nif(_Key, _Data) ->
    erlang:nif_error(nif_not_loaded).
