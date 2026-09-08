#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

command -v openssl >/dev/null || {
  echo "Required command is unavailable: openssl" >&2
  exit 1
}

object_key="relay/${GITHUB_RUN_ID:-manual}-${GITHUB_RUN_ATTEMPT:-1}-$(openssl rand -hex 16).bin"
[[ "$object_key" =~ ^relay/[A-Za-z0-9._-]+$ ]]

umask 077
printf 'object_key=%s\n' "$object_key" >> "$GITHUB_OUTPUT"
printf '%s\n' "$object_key" > "$RUNNER_TEMP/relay-object-key"
chmod 600 "$RUNNER_TEMP/relay-object-key"
echo "Relay cleanup handle reserved"
