#!/usr/bin/env bash
set -euo pipefail

required=(
  DEPLOY_TRANSACTION_ID RUNNER_TEMP TARGET_SSH_HOST TARGET_SSH_KNOWN_HOSTS
  TARGET_SSH_PRIVATE_KEY TARGET_SSH_USER
)
for name in "${required[@]}"; do
  test -n "${!name:-}" || { echo "$name is required" >&2; exit 2; }
done

[[ "$DEPLOY_TRANSACTION_ID" =~ ^[A-Za-z0-9._-]+$ ]]
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

ssh "${ssh_args[@]}" "$target" \
  "TRANSACTION_ID='$DEPLOY_TRANSACTION_ID' bash -s" <<'REMOTE'
set -euo pipefail
state_root="$HOME/.development-deploy-transactions"
state_dir="$state_root/$TRANSACTION_ID"
active_pointer="$state_root/active"
test -f "$state_dir/ready"
test -f "$state_dir/deployment-started"
test -f "$active_pointer"
test "$(cat "$active_pointer")" = "$TRANSACTION_ID"
rm -f "$active_pointer"
rm -rf "$state_dir"
REMOTE

echo "Verified development deployment finalized"
