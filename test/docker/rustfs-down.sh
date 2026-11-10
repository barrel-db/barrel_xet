#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Benoit Chesneau
# Stop and remove the RustFS container started by rustfs-up.sh.
set -euo pipefail
docker rm -f barrel-xet-rustfs >/dev/null 2>&1 || true
echo "RustFS stopped."
