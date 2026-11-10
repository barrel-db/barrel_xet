#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Benoit Chesneau
"""Drive xet-core (through its hf_xet Python bindings) against a barrel_xet
server, for xet_crossimpl_SUITE.

  hf_xet_driver.py upload   <endpoint> <token> <in_file> <hash_out>
  hf_xet_driver.py download <endpoint> <token> <hash> <size> <out_file>

Exits 0 on success; errors go to stderr.
"""
import sys
import time

import hf_xet


def token_info(token):
    # (token, expiry unix seconds); far enough out that no refresh happens.
    return (token, int(time.time()) + 3600)


def refresher(token):
    return lambda: token_info(token)


def upload(endpoint, token, in_file, hash_out):
    [info] = hf_xet.upload_files(
        [in_file], endpoint, token_info(token), refresher(token), None, "model"
    )
    with open(hash_out, "w") as out:
        out.write(info.hash)


def download(endpoint, token, file_hash, size, out_file):
    target = hf_xet.PyXetDownloadInfo(out_file, file_hash, int(size))
    hf_xet.download_files([target], endpoint, token_info(token), refresher(token), None)


def main(argv):
    command, args = argv[1], argv[2:]
    if command == "upload":
        upload(*args)
    elif command == "download":
        download(*args)
    else:
        sys.exit("unknown command " + command)


if __name__ == "__main__":
    main(sys.argv)
