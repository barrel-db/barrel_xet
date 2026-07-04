/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Benoit Chesneau */
/* LZ4 Frame compression (spec compression type 1) on top of the vendored
 * upstream library. Whole chunks are compressed as one complete frame.
 *
 * Decompression takes a hard output cap: chunk headers declare the
 * uncompressed size and the spec bounds it at MAX_CHUNK_SIZE, so anything
 * that inflates past the cap is rejected instead of allocated.
 */
#include <string.h>

#include "xet_nif.h"
#include "lz4frame.h"

ERL_NIF_TERM xet_lz4f_compress(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary data, out;
    LZ4F_preferences_t prefs;
    size_t bound, written;

    if (argc != 1 || !enif_inspect_iolist_as_binary(env, argv[0], &data))
        return enif_make_badarg(env);

    memset(&prefs, 0, sizeof(prefs));
    bound = LZ4F_compressFrameBound(data.size, &prefs);
    if (!enif_alloc_binary(bound, &out))
        return enif_raise_exception(env, enif_make_atom(env, "out_of_memory"));

    written = LZ4F_compressFrame(out.data, out.size, data.data, data.size, &prefs);
    if (LZ4F_isError(written)) {
        enif_release_binary(&out);
        return enif_raise_exception(env, enif_make_atom(env, "lz4_compress_failed"));
    }
    if (!enif_realloc_binary(&out, written)) {
        enif_release_binary(&out);
        return enif_raise_exception(env, enif_make_atom(env, "out_of_memory"));
    }
    return enif_make_binary(env, &out);
}

static ERL_NIF_TERM lz4f_error(ErlNifEnv *env, ErlNifBinary *out, const char *reason)
{
    enif_release_binary(out);
    return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, reason));
}

ERL_NIF_TERM xet_lz4f_decompress(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary data, out;
    LZ4F_dctx *dctx;
    size_t src_pos = 0, dst_pos = 0, ret = 0;
    unsigned long max_size;

    if (argc != 2 || !enif_inspect_iolist_as_binary(env, argv[0], &data) ||
        !enif_get_ulong(env, argv[1], &max_size))
        return enif_make_badarg(env);

    if (!enif_alloc_binary(max_size, &out))
        return enif_raise_exception(env, enif_make_atom(env, "out_of_memory"));

    if (LZ4F_isError(LZ4F_createDecompressionContext(&dctx, LZ4F_VERSION)))
        return lz4f_error(env, &out, "corrupt");

    while (src_pos < data.size) {
        size_t dst_len = out.size - dst_pos;
        size_t src_len = data.size - src_pos;

        ret = LZ4F_decompress(dctx, out.data + dst_pos, &dst_len,
                              data.data + src_pos, &src_len, NULL);
        dst_pos += dst_len;
        src_pos += src_len;
        if (LZ4F_isError(ret)) {
            LZ4F_freeDecompressionContext(dctx);
            return lz4f_error(env, &out, "corrupt");
        }
        if (ret == 0)
            break;
        /* Frame not finished: if no forward progress is possible the
         * destination cap is the blocker. */
        if (dst_pos == out.size && src_pos < data.size) {
            LZ4F_freeDecompressionContext(dctx);
            return lz4f_error(env, &out, "too_large");
        }
    }
    LZ4F_freeDecompressionContext(dctx);

    if (ret != 0)
        return lz4f_error(env, &out, src_pos >= data.size ? "truncated" : "too_large");

    if (src_pos != data.size)
        return lz4f_error(env, &out, "trailing_data");

    if (!enif_realloc_binary(&out, dst_pos))
        return lz4f_error(env, &out, "out_of_memory");

    return enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_binary(env, &out));
}
