#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Benoit Chesneau
# Start a single-node RustFS in Docker for the S3 integration suite, the
# second live target next to Garage. Adapted from livery_s3's test setup;
# uses its own container name and host port so both projects' suites can
# coexist.
set -euo pipefail

NAME=barrel-xet-rustfs
IMAGE=rustfs/rustfs:1.0.4
PORT=${XET_S3_PORT:-3920}
REGION=us-east-1
ACCESS_KEY=${XET_S3_ACCESS_KEY:-rustfsadmin}
SECRET_KEY=${XET_S3_SECRET_KEY:-rustfsadmin}
BUCKET=${XET_S3_BUCKET:-barrel-xet-test}

docker rm -f "$NAME" >/dev/null 2>&1 || true

for attempt in 1 2 3 4 5; do
  if docker pull "$IMAGE"; then break; fi
  echo "image pull failed (attempt $attempt), retrying in 5s..."
  sleep 5
done

docker run -d --name "$NAME" \
  -p "$PORT:9000" \
  -e RUSTFS_ACCESS_KEY="$ACCESS_KEY" \
  -e RUSTFS_SECRET_KEY="$SECRET_KEY" \
  -e RUSTFS_REGION="$REGION" \
  "$IMAGE" >/dev/null

# Signed S3 calls from inside the container, with curl's SigV4 support.
status() {
  docker exec "$NAME" curl -s -o /dev/null -w '%{http_code}' \
    --aws-sigv4 "aws:amz:$REGION:s3" --user "$ACCESS_KEY:$SECRET_KEY" "$@"
}

echo "Waiting for RustFS S3 API on :$PORT..."
for _ in $(seq 1 60); do
  if [ "$(status http://127.0.0.1:9000/ 2>/dev/null || true)" = "200" ]; then break; fi
  sleep 1
done

code=$(status -X PUT "http://127.0.0.1:9000/$BUCKET")
case "$code" in
  200|409) ;;
  *) echo "create bucket $BUCKET failed: HTTP $code" >&2; docker logs "$NAME" >&2; exit 1 ;;
esac

cat <<EOF
RustFS ready. Export for the suite:
  export XET_S3_ENDPOINT=http://127.0.0.1:$PORT
  export XET_S3_REGION=$REGION
  export XET_S3_ACCESS_KEY=$ACCESS_KEY
  export XET_S3_SECRET_KEY=$SECRET_KEY
  export XET_S3_BUCKET=$BUCKET
EOF
