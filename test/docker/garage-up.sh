#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Benoit Chesneau
# Start a single-node Garage in Docker for the S3 integration suite.
# Adapted from livery_s3's test setup; uses its own container name and
# host port so both projects' suites can coexist.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME=barrel-xet-garage
IMAGE=dxflrs/garage:v2.3.0
PORT=${XET_S3_PORT:-3910}
ACCESS_KEY=${XET_S3_ACCESS_KEY:-GKtestaccesskey1234567890}
SECRET_KEY=${XET_S3_SECRET_KEY:-testsecretkey00000000000000000000000000000000000}
BUCKET=${XET_S3_BUCKET:-barrel-xet-test}

docker rm -f "$NAME" >/dev/null 2>&1 || true

for attempt in 1 2 3 4 5; do
  if docker pull "$IMAGE"; then break; fi
  echo "image pull failed (attempt $attempt), retrying in 5s..."
  sleep 5
done

docker run -d --name "$NAME" \
  -p "$PORT:3900" \
  -v "$HERE/garage.toml:/etc/garage.toml" \
  -e GARAGE_DEFAULT_ACCESS_KEY="$ACCESS_KEY" \
  -e GARAGE_DEFAULT_SECRET_KEY="$SECRET_KEY" \
  -e GARAGE_DEFAULT_BUCKET="$BUCKET" \
  "$IMAGE" /garage server --single-node --default-bucket >/dev/null

echo "Waiting for Garage S3 API on :$PORT..."
for _ in $(seq 1 60); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT"; then break; fi
  sleep 1
done

docker exec "$NAME" /garage key allow --create-bucket "$ACCESS_KEY" >/dev/null 2>&1 || true

cat <<EOF
Garage ready. Export for the suite:
  export XET_S3_ENDPOINT=http://127.0.0.1:$PORT
  export XET_S3_REGION=garage
  export XET_S3_ACCESS_KEY=$ACCESS_KEY
  export XET_S3_SECRET_KEY=$SECRET_KEY
  export XET_S3_BUCKET=$BUCKET
EOF
