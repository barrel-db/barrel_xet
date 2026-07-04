# Cross-implementation test harness

`reference/` is the draft author's Python reference implementation of the
XET protocol, vendored from
[jedisct1/draft-denis-xet](https://github.com/jedisct1/draft-denis-xet)
(`reference-implementation/`). It is used only by `xet_crossimpl_SUITE` to
verify that barrel_xet interoperates with an independent implementation.

`xet_interop_driver.py` drives that client against a running barrel_xet
server for upload/download.

Requires `python3` with `blake3`, `lz4`, and `requests`. The suite skips
the Python cases when they are missing.

Note: the reference client stores the shard SHA-256 metadata field raw,
while xet-core and the Hugging Face fixtures store it byte-swapped;
barrel_xet matches the latter. This does not affect interop because the
field is informational and not validated on the server.
