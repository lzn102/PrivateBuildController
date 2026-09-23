#!/usr/bin/env bash
set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${PACKAGE_NAME:?PACKAGE_NAME is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"

printf '%s=%s\n' \
  SOURCE_DIR "$RUNNER_TEMP/private-source" \
  OUTPUT_DIR "$RUNNER_TEMP/private-output" \
  PACKAGE_PATH "$RUNNER_TEMP/$PACKAGE_NAME" \
  >> "$GITHUB_ENV"
