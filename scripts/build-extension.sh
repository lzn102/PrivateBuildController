#!/usr/bin/env bash
set -euo pipefail

: "${BUILD_ID:?BUILD_ID is required}"
: "${GITEA_PACKAGE_TOKEN:?GITEA_PACKAGE_TOKEN is required}"
: "${SOURCE_DIR:?SOURCE_DIR is required}"
: "${STAGING_UPLOAD_URL:?STAGING_UPLOAD_URL is required}"

log="$RUNNER_TEMP/extension-build.log"
archive="$RUNNER_TEMP/extension.tar.gz"
checksum="$archive.sha256"

if ! (
  cd "$SOURCE_DIR"
  npm ci --no-audit --no-fund --silent
  npm run check --silent
  node scripts/build.mjs
) >"$log" 2>&1; then
  echo "Extension validation failed" >&2
  exit 1
fi

tar -C "$SOURCE_DIR/dist" -czf "$archive" .
sha256sum "$archive" | awk '{print $1}' > "$checksum"

base="${STAGING_UPLOAD_URL%/}/$BUILD_ID"
upload() {
  local source="$1"
  local destination="$2"
  local status
  status="$(curl --silent --show-error \
    -o /dev/null -w '%{http_code}' \
    -H "Authorization: token $GITEA_PACKAGE_TOKEN" \
    --upload-file "$source" "$destination")"
  [[ "$status" = 201 || "$status" = 204 || "$status" = 409 ]]
}

upload "$archive" "$base/extension.tar.gz"
upload "$checksum" "$base/extension.tar.gz.sha256"

echo "Extension output delivered"
