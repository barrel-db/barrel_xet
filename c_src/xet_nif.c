/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Benoit Chesneau */
/* xet_nif: NIF registration only. Feature code lives in one small C file
 * per feature (xet_blake3.c, ...), declared in xet_nif.h.
 *
 * Each operation is registered twice, once on a normal scheduler and once
 * as a dirty CPU job; xet_nif.erl picks by input size.
 */
#include "xet_nif.h"

static ErlNifFunc nif_funcs[] = {
    {"blake3_keyed_nif", 2, xet_blake3_keyed, 0},
    {"blake3_keyed_dirty_nif", 2, xet_blake3_keyed, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"lz4f_compress_nif", 1, xet_lz4f_compress, 0},
    {"lz4f_compress_dirty_nif", 1, xet_lz4f_compress, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"lz4f_decompress_nif", 2, xet_lz4f_decompress, 0},
    {"lz4f_decompress_dirty_nif", 2, xet_lz4f_decompress, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"gearhash_scan_nif", 3, xet_gearhash_scan, 0},
    {"gearhash_scan_dirty_nif", 3, xet_gearhash_scan, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"fsync_dir_nif", 1, xet_fsync_dir, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(xet_nif, nif_funcs, NULL, NULL, NULL, NULL)
