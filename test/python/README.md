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

`hf_xet_driver.py` drives xet-core itself, through its `hf_xet` Python
bindings: upload, download, and a second upload that can only dedup
through the server's global chunk query. Those cases need `hf_xet` and
skip without it:

```sh
pip install hf_xet blake3 lz4 requests
rebar3 ct --suite=xet_crossimpl_SUITE
```

Note: the reference client stores the shard SHA-256 metadata field raw,
while xet-core and the Hugging Face fixtures store it byte-swapped;
barrel_xet matches the latter. This does not affect interop because the
field is informational and not validated on the server.
