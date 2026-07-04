/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Benoit Chesneau */
/* Directory fsync: after renaming a blob into place, the parent
 * directory entry must be durable before metadata acknowledges the
 * xorb. Erlang's file module cannot fsync a directory.
 */
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

#include <erl_driver.h>

#include "xet_nif.h"

ERL_NIF_TERM xet_fsync_dir(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    ErlNifBinary path;
    char buf[4096];
    int fd;

    if (argc != 1 || !enif_inspect_iolist_as_binary(env, argv[0], &path) ||
        path.size >= sizeof(buf))
        return enif_make_badarg(env);

    memcpy(buf, path.data, path.size);
    buf[path.size] = '\0';

    fd = open(buf, O_RDONLY);
    if (fd < 0)
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, erl_errno_id(errno)));
    if (fsync(fd) != 0) {
        int err = errno;
        close(fd);
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, erl_errno_id(err)));
    }
    close(fd);
    return enif_make_atom(env, "ok");
}
