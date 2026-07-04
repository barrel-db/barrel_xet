%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
%% Shard format constants (spec Section 9).

-define(SHARD_HEADER_SIZE, 48).
-define(SHARD_FOOTER_SIZE, 200).
-define(SHARD_VERSION, 2).
-define(SHARD_FOOTER_VERSION, 1).

%% 14-byte application id, one null byte, 17-byte magic sequence.
-define(SHARD_APP_ID, <<"HFRepoMetaData">>).
-define(SHARD_MAGIC_SEQUENCE,
    <<16#55, 16#69, 16#67, 16#45, 16#6a, 16#7b, 16#81, 16#57, 16#83, 16#a5, 16#bd, 16#d9, 16#5c,
        16#cd, 16#d1, 16#4a, 16#a9>>
).
-define(SHARD_TAG, [?SHARD_APP_ID, 0, ?SHARD_MAGIC_SEQUENCE]).

-define(SHARD_BOOKEND_BIN,
    <<16#FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF:256, 0:128>>
).
-define(SHARD_BOOKEND, ?SHARD_BOOKEND_BIN).

-define(FILE_FLAG_WITH_VERIFICATION, 16#80000000).
-define(FILE_FLAG_WITH_METADATA_EXT, 16#40000000).
-define(CHUNK_FLAG_GLOBAL_DEDUP_ELIGIBLE, 16#80000000).
