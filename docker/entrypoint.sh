#!/bin/sh
# barrel_xet container entrypoint. Ensures a tokens file exists (empty is
# valid: only /healthz and /readyz are reachable until you add tokens),
# then execs the release script with whatever command was given
# (foreground by default; also stop, eval, remote_console, ...).
set -e

: "${BARREL_XET_TOKENS_FILE:=/var/lib/barrel_xet/tokens}"
export BARREL_XET_TOKENS_FILE
[ -f "$BARREL_XET_TOKENS_FILE" ] || : > "$BARREL_XET_TOKENS_FILE"

exec /opt/barrel_xet/bin/barrel_xet "$@"
