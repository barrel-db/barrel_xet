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
};

ERL_NIF_INIT(xet_nif, nif_funcs, NULL, NULL, NULL, NULL)
