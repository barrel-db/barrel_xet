/* Gearhash boundary scanner (spec Section 5).
 *
 * Scans one buffer, carrying {rolling hash, current chunk length} across
 * calls so callers can stream files of any size. Returned cut positions
 * are end offsets relative to the start of this buffer.
 */
#include "xet_nif.h"
#include "xet_gear_table.h"

#define XET_MIN_CHUNK 8192
#define XET_MAX_CHUNK 131072
#define XET_GEAR_MASK 0xFFFF000000000000ULL

ERL_NIF_TERM xet_gearhash_scan(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary data;
    ErlNifUInt64 h, chunk_len;
    ERL_NIF_TERM list;
    size_t *cuts, ncuts = 0, max_cuts, i;

    if (argc != 3 || !enif_get_uint64(env, argv[0], &h) ||
        !enif_get_uint64(env, argv[1], &chunk_len) ||
        !enif_inspect_iolist_as_binary(env, argv[2], &data))
        return enif_make_badarg(env);

    max_cuts = data.size / XET_MIN_CHUNK + 1;
    cuts = enif_alloc(max_cuts * sizeof(size_t));
    if (cuts == NULL)
        return enif_raise_exception(env, enif_make_atom(env, "out_of_memory"));

    for (i = 0; i < data.size; i++) {
        h = (h << 1) + XET_GEAR_TABLE[data.data[i]];
        chunk_len++;
        if (chunk_len < XET_MIN_CHUNK)
            continue;
        if (chunk_len >= XET_MAX_CHUNK || (h & XET_GEAR_MASK) == 0) {
            cuts[ncuts++] = i + 1;
            h = 0;
            chunk_len = 0;
        }
    }

    list = enif_make_list(env, 0);
    for (i = ncuts; i > 0; i--)
        list = enif_make_list_cell(env, enif_make_uint64(env, cuts[i - 1]), list);
    enif_free(cuts);

    return enif_make_tuple3(env, list, enif_make_uint64(env, h),
                            enif_make_uint64(env, chunk_len));
}
