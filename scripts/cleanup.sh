#!/usr/bin/env bash
set -uo pipefail

docker logout "${REGISTRY_HOST:-}" >/dev/null 2>&1 || true
docker image rm "${IMAGE_REF:-}" >/dev/null 2>&1 || true

for target in \
  "${SOURCE_DIR:-}" \
  "${RUNNER_TEMP:-}/extension.tar.gz" \
  "${RUNNER_TEMP:-}/extension.tar.gz.sha256" \
  "${RUNNER_TEMP:-}/extension-build.log" \
  "${RUNNER_TEMP:-}/image-build.log"; do
  if [[ -n "$target" ]]; then
    rm -rf "$target"
  fi
done

find "${RUNNER_TEMP:-/tmp}" -maxdepth 1 -name 'source-auth.*' -exec rm -rf {} + 2>/dev/null || true
echo "Ephemeral build data removed"
