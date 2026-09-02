#!/usr/bin/env bash
set -uo pipefail

docker logout "${REGISTRY_HOST:-}" >/dev/null 2>&1 || true
docker image rm "${IMAGE_REF:-}" >/dev/null 2>&1 || true

for target in \
  "${SOURCE_DIR:-${RUNNER_TEMP:-/tmp}/private-source}" \
  "${RUNNER_TEMP:-}/extension.tar.gz" \
  "${RUNNER_TEMP:-}/extension.tar.gz.sha256" \
  "${RUNNER_TEMP:-}/extension-build.log" \
  "${RUNNER_TEMP:-}/image-build.log" \
  "${RUNNER_TEMP:-}/service-image.tar.zst.enc" \
  "${RUNNER_TEMP:-}/release-response.json" \
  "${RUNNER_TEMP:-}/deploy-input" \
  "${RUNNER_TEMP:-}/development-deploy-input" \
  "${RUNNER_TEMP:-}/development-extension" \
  "${RUNNER_TEMP:-}/development-extension.zip" \
  "${RUNNER_TEMP:-}/deploy-key" \
  "${RUNNER_TEMP:-}/deploy-known-hosts"; do
  if [[ -n "$target" ]]; then
    rm -rf "$target"
  fi
done

find "${RUNNER_TEMP:-/tmp}" -maxdepth 1 -name 'source-auth.*' -exec rm -rf {} + 2>/dev/null || true
unset R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
echo "Ephemeral build data removed"
