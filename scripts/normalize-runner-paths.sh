#!/usr/bin/env bash
set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${PACKAGE_NAME:?PACKAGE_NAME is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"

temp_root="$RUNNER_TEMP"
if command -v cygpath >/dev/null 2>&1; then
  temp_root="$(cygpath -u "$temp_root")"
fi

printf '%s=%s\n' \
  RUNNER_KIT_TEMP "$temp_root" \
  SOURCE_DIR "$temp_root/private-source" \
  OUTPUT_DIR "$temp_root/private-output" \
  PACKAGE_PATH "$temp_root/$PACKAGE_NAME" \
  >> "$GITHUB_ENV"
