#!/usr/bin/env bash
set -euo pipefail

: "${PACKAGE_PATH:?PACKAGE_PATH is required}"
: "${R2_ENDPOINT:?R2_ENDPOINT is required}"
: "${R2_BUCKET:?R2_BUCKET is required}"
: "${R2_PREFIX:?R2_PREFIX is required}"
: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is required}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is required}"

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_EC2_METADATA_DISABLED=true

destination="s3://$R2_BUCKET/$R2_PREFIX/${GITHUB_RUN_ID:-manual}/"
aws s3 cp --only-show-errors --endpoint-url "$R2_ENDPOINT" "$PACKAGE_PATH" "$destination"
aws s3 cp --only-show-errors --endpoint-url "$R2_ENDPOINT" "$PACKAGE_PATH.sha256" "$destination"
echo "R2 delivery completed"
