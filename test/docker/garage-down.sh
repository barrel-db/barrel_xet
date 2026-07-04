#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Benoit Chesneau
# Stop and remove the integration-test Garage container.
set -euo pipefail
docker rm -f barrel-xet-garage >/dev/null 2>&1 || true
echo "Garage stopped."
