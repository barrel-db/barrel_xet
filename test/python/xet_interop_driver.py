#!/usr/bin/env python3
"""Cross-implementation driver: run the draft's Python reference client
against a barrel_xet CAS server.

Usage:
    xet_interop_driver.py upload   <endpoint> <token> <in_file>  <hash_out>
    xet_interop_driver.py download <endpoint> <token> <hash_hex> <out_file>

`upload` uploads <in_file> and writes the file hash (XET string form) to
<hash_out>. `download` fetches the file at <hash_hex> to <out_file>.
Exit code 0 on success, non-zero on failure.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent / "reference"))

from api import CASClient  # noqa: E402
from protocol import upload_file, download_file  # noqa: E402
from hashing import hash_to_string, string_to_hash  # noqa: E402


def main(argv):
    cmd = argv[1]
    endpoint, token = argv[2], argv[3]
    client = CASClient(endpoint, token)
    if cmd == "upload":
        data = Path(argv[4]).read_bytes()
        file_hash = upload_file(client, data)
        Path(argv[5]).write_text(hash_to_string(file_hash))
        return 0
    if cmd == "download":
        file_hash = string_to_hash(argv[4])
        data = download_file(client, file_hash)
        Path(argv[5]).write_bytes(data)
        return 0
    sys.stderr.write("unknown command %s\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
