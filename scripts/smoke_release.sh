#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Benoit Chesneau
# Cold-start smoke: build the release, boot it on an ephemeral data dir
# and port, exercise health + an upload/download roundtrip through the
# HTTP API, then stop it gracefully.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PORT=${SMOKE_PORT:-18080}
DATA=$(mktemp -d)
TOKEN=smoke-write-token
REL=_build/prod/rel/barrel_xet
cleanup() {
    "$REL/bin/barrel_xet" stop >/dev/null 2>&1 || true
    rm -rf "$DATA"
}
trap cleanup EXIT

echo "building release..."
rebar3 as prod release >/dev/null

# A throwaway sys.config pointing at the temp data dir and ephemeral
# port. RELX_CONFIG_PATH must name a .config file (the start script strips
# the extension before passing it to -config).
SYS="$DATA/smoke_sys.config"
cat >"$SYS" <<EOF
[{barrel_xet, [{server, #{
    name => barrel_xet,
    data_dir => "$DATA",
    http => #{port => $PORT},
    auth => {xet_auth_static, #{tokens => #{<<"$TOKEN">> => write}}}
}}]}].
EOF

echo "starting node..."
RELX_CONFIG_PATH="$SYS" "$REL/bin/barrel_xet" daemon

echo "waiting for health..."
for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then break; fi
    sleep 1
done
curl -fsS "http://127.0.0.1:$PORT/healthz" | grep -q '"status":"ok"'
echo "health ok"

# Round-trip a xorb + shard + reconstruction using the node's own client
# via a remote eval. eval prints the form's return value, so the final
# expression yields an atom we can grep (a failed match errors instead).
echo "roundtrip via remote eval..."
EVAL='Client = xet_client:new(#{endpoint => <<"http://127.0.0.1:'"$PORT"'">>, token => <<"'"$TOKEN"'">>}), Data = binary:copy(<<"barrel_xet release smoke ">>, 20000), {ok, #{file_hash := H}} = xet_client_upload:upload_data(Client, smoke, Data), {ok, Data} = xet_client_download:download_data(Client, H), roundtrip_ok.'
"$REL/bin/barrel_xet" eval "$EVAL" | grep -q roundtrip_ok
echo "roundtrip ok"

echo "stopping node..."
"$REL/bin/barrel_xet" stop
echo "SMOKE PASSED"
