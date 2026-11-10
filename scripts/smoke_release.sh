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
PORT2=${SMOKE_PORT2:-18081}
DATA=$(mktemp -d)
DATA2=$(mktemp -d)
TOKEN=smoke-write-token
REL=_build/prod/rel/barrel_xet
# Bound every daemon start: a node that never answers fails the smoke
# with its logs instead of hanging until the CI job is cancelled.
START_TIMEOUT=${SMOKE_START_TIMEOUT:-120}
cleanup() {
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "smoke failed; node logs:" >&2
        tail -n 50 "$REL"/log/erlang.log.* 2>/dev/null >&2 || true
    fi
    HOME="$DATA" "$REL/bin/barrel_xet" stop >/dev/null 2>&1 || true
    HOME="$DATA2" BARREL_XET_NODE=smoke_env@127.0.0.1 \
        "$REL/bin/barrel_xet" stop >/dev/null 2>&1 || true
    rm -rf "$DATA" "$DATA2"
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

# `daemon` waits for the node over Erlang RPC, which needs a cookie; seed
# one in a throwaway HOME rather than relying on ~/.erlang.cookie (a fresh
# CI runner has none, and daemon then waits forever).
head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$DATA/.erlang.cookie"
chmod 400 "$DATA/.erlang.cookie"
main_node() {
    HOME="$DATA" RELX_CONFIG_PATH="$SYS" "$REL/bin/barrel_xet" "$@"
}
echo "starting node..."
HOME="$DATA" RELX_CONFIG_PATH="$SYS" timeout "$START_TIMEOUT" "$REL/bin/barrel_xet" daemon

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
main_node eval "$EVAL" | grep -q roundtrip_ok
echo "roundtrip ok"

echo "stopping node..."
main_node stop

# Second boot driven purely by BARREL_XET_* environment variables (the
# sys.config.src / vm.args.src substitution path): no config file is
# written. HOME is pinned so the distribution cookie lives in the
# throwaway dir; stop and eval below reuse the same HOME.
#
# The cookie is seeded up front: `daemon` waits for the node with
# erl_rpc, which cannot authenticate before a cookie exists (fresh
# installs using daemon mode need the same one-time step; foreground
# mode, which systemd and Docker use, has no such wait).
echo "starting env-configured node..."
printf '%s write\n' "$TOKEN" >"$DATA2/tokens"
head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$DATA2/.erlang.cookie"
chmod 400 "$DATA2/.erlang.cookie"
env_node() {
    HOME="$DATA2" \
        BARREL_XET_NODE=smoke_env@127.0.0.1 \
        BARREL_XET_DATA_DIR="$DATA2/data" \
        BARREL_XET_HTTP_PORT="$PORT2" \
        BARREL_XET_TOKENS_FILE="$DATA2/tokens" \
        "$REL/bin/barrel_xet" "$@"
}
HOME="$DATA2" BARREL_XET_NODE=smoke_env@127.0.0.1 BARREL_XET_DATA_DIR="$DATA2/data" \
    BARREL_XET_HTTP_PORT="$PORT2" BARREL_XET_TOKENS_FILE="$DATA2/tokens" \
    timeout "$START_TIMEOUT" "$REL/bin/barrel_xet" daemon

echo "waiting for env node health..."
for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:$PORT2/healthz" >/dev/null 2>&1; then break; fi
    sleep 1
done
curl -fsS "http://127.0.0.1:$PORT2/healthz" | grep -q '"status":"ok"'
echo "env health ok"

echo "env roundtrip via remote eval..."
EVAL2='Client = xet_client:new(#{endpoint => <<"http://127.0.0.1:'"$PORT2"'">>, token => <<"'"$TOKEN"'">>}), Data = binary:copy(<<"barrel_xet env smoke ">>, 20000), {ok, #{file_hash := H}} = xet_client_upload:upload_data(Client, smoke_env, Data), {ok, Data} = xet_client_download:download_data(Client, H), roundtrip_ok.'
env_node eval "$EVAL2" | grep -q roundtrip_ok
echo "env roundtrip ok"

echo "stopping env node..."
env_node stop
echo "SMOKE PASSED"
