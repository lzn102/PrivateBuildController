#!/usr/bin/env bash
set -euo pipefail

required=(RUNNER_TEMP TARGET_SSH_HOST TARGET_SSH_KNOWN_HOSTS TARGET_SSH_PRIVATE_KEY TARGET_SSH_USER)
for name in "${required[@]}"; do
  test -n "${!name:-}" || { echo "$name is required" >&2; exit 2; }
done

[[ "$TARGET_SSH_HOST" =~ ^[A-Za-z0-9.:-]+$ ]]
[[ "$TARGET_SSH_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]
command -v ssh >/dev/null || { echo "Required command is unavailable: ssh" >&2; exit 1; }

key_file="$RUNNER_TEMP/deploy-key"
known_hosts="$RUNNER_TEMP/deploy-known-hosts"
printf '%s\n' "$TARGET_SSH_PRIVATE_KEY" > "$key_file"
printf '%s\n' "$TARGET_SSH_KNOWN_HOSTS" > "$known_hosts"
chmod 600 "$key_file" "$known_hosts"
ssh_args=(
  -i "$key_file" -o BatchMode=yes -o ConnectTimeout=10
  -o ServerAliveCountMax=3 -o ServerAliveInterval=15
  -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts"
)
target="$TARGET_SSH_USER@$TARGET_SSH_HOST"

active_id_file="$(mktemp "$RUNNER_TEMP/development-recovery-result.XXXXXX")"
ssh "${ssh_args[@]}" "$target" "bash -s" > "$active_id_file" <<'REMOTE'
set -euo pipefail
state_root="$HOME/.development-deploy-transactions"
active_pointer="$state_root/active"
test -e "$active_pointer" || exit 0
test -f "$active_pointer"
transaction_id="$(cat "$active_pointer")"
[[ "$transaction_id" =~ ^[A-Za-z0-9._-]+$ ]]
state_dir="$state_root/$transaction_id"

# A ready snapshot is always written before the active pointer is published.
if ! test -f "$state_dir/ready"; then
  test "$(cat "$active_pointer")" = "$transaction_id"
  rm -f "$active_pointer"
  rm -rf "$state_dir"
  exit 0
fi
printf '%s' "$transaction_id"
REMOTE
active_id="$(cat "$active_id_file")"
rm -f "$active_id_file"

if test -z "$active_id"; then
  echo "No interrupted development transaction requires recovery"
  exit 0
fi
[[ "$active_id" =~ ^[A-Za-z0-9._-]+$ ]]

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_TRANSACTION_ID="$active_id" bash "$script_dir/rollback-development.sh"
echo "Interrupted development transaction recovered"
