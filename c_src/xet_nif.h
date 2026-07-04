/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Benoit Chesneau */
/* Shared declarations for the xet_nif feature files.
 *
 * One C file per feature: each file implements its NIF handlers and
 * declares them here; xet_nif.c only registers them.
 */
#ifndef XET_NIF_H
#define XET_NIF_H

#include <erl_nif.h>

/* xet_blake3.c */
ERL_NIF_TERM xet_blake3_keyed(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

/* xet_lz4.c */
ERL_NIF_TERM xet_lz4f_compress(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM xet_lz4f_decompress(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

/* xet_gearhash.c */
ERL_NIF_TERM xet_gearhash_scan(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

/* xet_fsync.c */
ERL_NIF_TERM xet_fsync_dir(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);

#endif
