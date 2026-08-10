#!/usr/bin/env bash
set -euo pipefail

: "${IMAGE_REF:?IMAGE_REF is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
SOURCE_DIR="${SOURCE_DIR:-$RUNNER_TEMP/private-source}"

if docker manifest inspect "$IMAGE_REF" >/dev/null 2>&1; then
  echo "Service image already available"
  exit 0
fi

log="$RUNNER_TEMP/image-build.log"
if ! docker build --quiet --tag "$IMAGE_REF" "$SOURCE_DIR" >"$log" 2>&1; then
  echo "Image build failed" >&2
  exit 1
fi
if ! docker push "$IMAGE_REF" >>"$log" 2>&1; then
  echo "Image delivery failed" >&2
  exit 1
fi

echo "Service image delivered"
