/* BLAKE3 keyed hashing on top of the vendored upstream implementation. */
#include <string.h>

#include "xet_nif.h"
#include "blake3.h"

ERL_NIF_TERM xet_blake3_keyed(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary key, data;
    blake3_hasher hasher;
    uint8_t keybuf[BLAKE3_KEY_LEN];
    unsigned char *out;
    ERL_NIF_TERM ret;

    if (argc != 2 || !enif_inspect_binary(env, argv[0], &key) || key.size != BLAKE3_KEY_LEN)
        return enif_make_badarg(env);
    if (!enif_inspect_iolist_as_binary(env, argv[1], &data))
        return enif_make_badarg(env);

    memcpy(keybuf, key.data, BLAKE3_KEY_LEN);
    blake3_hasher_init_keyed(&hasher, keybuf);
    blake3_hasher_update(&hasher, data.data, data.size);

    out = enif_make_new_binary(env, BLAKE3_OUT_LEN, &ret);
    blake3_hasher_finalize(&hasher, out, BLAKE3_OUT_LEN);
    return ret;
}
