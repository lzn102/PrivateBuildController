#!/usr/bin/env bash
set -euo pipefail

: "${BUILD_ID:?BUILD_ID is required}"
: "${IMAGE_REF:?IMAGE_REF is required}"
: "${RELAY_ENCRYPTION_KEY:?RELAY_ENCRYPTION_KEY is required}"
: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is required}"
: "${R2_BUCKET:?R2_BUCKET is required}"
: "${R2_ENDPOINT:?R2_ENDPOINT is required}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
SOURCE_DIR="${SOURCE_DIR:-$RUNNER_TEMP/private-source}"

[[ "$BUILD_ID" =~ ^[0-9a-f]{40}$ ]]
[[ "$R2_BUCKET" =~ ^[A-Za-z0-9._-]+$ ]]
[[ "$R2_ENDPOINT" == https://* ]]

for command_name in aws docker openssl sha256sum zstd; do
  command -v "$command_name" >/dev/null || {
    echo "Required command is unavailable: $command_name" >&2
    exit 1
  }
done

archive="$RUNNER_TEMP/service-image.tar.zst.enc"
log="$RUNNER_TEMP/image-build.log"
object_key="relay/${GITHUB_RUN_ID:-manual}-${GITHUB_RUN_ATTEMPT:-1}-$(openssl rand -hex 16).bin"
relay_passphrase="$(printf '%s' "$RELAY_ENCRYPTION_KEY:$BUILD_ID:$object_key" | sha256sum | cut -d ' ' -f 1)"

if ! docker build --quiet --tag "$IMAGE_REF" "$SOURCE_DIR" >"$log" 2>&1; then
  echo "Image build failed" >&2
  exit 1
fi

export relay_passphrase
docker save "$IMAGE_REF" \
  | zstd -T0 -10 --quiet \
  | openssl enc -aes-256-cbc -salt -pbkdf2 -iter 200000 \
      -pass env:relay_passphrase -out "$archive"
archive_sha256="$(sha256sum "$archive" | cut -d ' ' -f 1)"

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto
export AWS_EC2_METADATA_DISABLED=true
aws s3 cp --only-show-errors --endpoint-url "$R2_ENDPOINT" \
  "$archive" "s3://$R2_BUCKET/$object_key"

{
  echo "object_key=$object_key"
  echo "archive_sha256=$archive_sha256"
} >> "$GITHUB_OUTPUT"
unset relay_passphrase AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
echo "Encrypted service image relayed"
