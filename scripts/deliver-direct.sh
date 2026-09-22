#!/usr/bin/env bash
set -euo pipefail

: "${PACKAGE_PATH:?PACKAGE_PATH is required}"
: "${DEPLOY_HOST:?DEPLOY_HOST is required}"
: "${DEPLOY_USER:?DEPLOY_USER is required}"
: "${DEPLOY_PATH:?DEPLOY_PATH is required}"
: "${DEPLOY_SSH_KEY:?DEPLOY_SSH_KEY is required}"
: "${DEPLOY_KNOWN_HOSTS:?DEPLOY_KNOWN_HOSTS is required}"

[[ "$DEPLOY_HOST" =~ ^[A-Za-z0-9.:-]+$ ]] || { echo "Invalid DEPLOY_HOST" >&2; exit 2; }
[[ "$DEPLOY_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || { echo "Invalid DEPLOY_USER" >&2; exit 2; }
[[ "$DEPLOY_PATH" =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo "Invalid DEPLOY_PATH" >&2; exit 2; }

temp_root="${RUNNER_KIT_TEMP:-${RUNNER_TEMP:-/tmp}}"
key_file="$(mktemp "$temp_root/deploy-key.XXXXXX")"
known_hosts="$(mktemp "$temp_root/known-hosts.XXXXXX")"
cleanup() { rm -f "$key_file" "$known_hosts"; }
trap cleanup EXIT

chmod 600 "$key_file" "$known_hosts"
printf '%s\n' "$DEPLOY_SSH_KEY" > "$key_file"
printf '%s\n' "$DEPLOY_KNOWN_HOSTS" > "$known_hosts"

ssh_args=(-i "$key_file" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts")
remote="$DEPLOY_USER@$DEPLOY_HOST"
name="$(basename "$PACKAGE_PATH")"
temporary="$DEPLOY_PATH/.${name}.${GITHUB_RUN_ID:-manual}.tmp"
checksum_temporary="$temporary.sha256"

ssh "${ssh_args[@]}" "$remote" "mkdir -p '$DEPLOY_PATH'"
scp "${ssh_args[@]}" "$PACKAGE_PATH" "$remote:$temporary"
scp "${ssh_args[@]}" "$PACKAGE_PATH.sha256" "$remote:$checksum_temporary"
ssh "${ssh_args[@]}" "$remote" \
  "mv '$temporary' '$DEPLOY_PATH/$name' && mv '$checksum_temporary' '$DEPLOY_PATH/$name.sha256'"
