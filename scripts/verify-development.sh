#!/usr/bin/env bash
set -euo pipefail

required=(
  DEPLOY_COMPOSE_FILE DEPLOY_COMPOSE_PROJECT DEPLOY_DIRECTORY DEPLOY_NETWORK_SERVICE
  DEPLOY_SERVICE_NAME DEPLOY_TRANSACTION_ID DEPLOY_VERIFY_COMMAND_B64 RUNNER_TEMP TARGET_SSH_HOST
  TARGET_SSH_KNOWN_HOSTS TARGET_SSH_PRIVATE_KEY TARGET_SSH_USER
)
for name in "${required[@]}"; do
  test -n "${!name:-}" || { echo "$name is required" >&2; exit 2; }
done

validate_relative_path() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  [[ "$value" != /* && "$value" != -* && "$value" != */ ]] || return 1
  case "/$value/" in
    *//*|*/./*|*/../*) return 1 ;;
  esac
}
validate_relative_path "$DEPLOY_COMPOSE_FILE"
[[ "$DEPLOY_COMPOSE_PROJECT" =~ ^[A-Za-z0-9._-]+$ ]]
validate_relative_path "$DEPLOY_DIRECTORY"
[[ "$DEPLOY_NETWORK_SERVICE" =~ ^[A-Za-z0-9._-]+$ ]]
[[ "$DEPLOY_SERVICE_NAME" =~ ^[A-Za-z0-9._-]+$ ]]
[[ "$DEPLOY_TRANSACTION_ID" =~ ^[A-Za-z0-9._-]+$ ]]
[[ "$TARGET_SSH_HOST" =~ ^[A-Za-z0-9.:-]+$ ]]
[[ "$TARGET_SSH_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]
[[ "$DEPLOY_VERIFY_COMMAND_B64" =~ ^[A-Za-z0-9+/=]+$ ]]
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
  "DEPLOY_DIRECTORY='$DEPLOY_DIRECTORY' COMPOSE_FILE='$DEPLOY_COMPOSE_FILE' COMPOSE_PROJECT='$DEPLOY_COMPOSE_PROJECT' SERVICE_NAME='$DEPLOY_SERVICE_NAME' NETWORK_SERVICE='$DEPLOY_NETWORK_SERVICE' TRANSACTION_ID='$DEPLOY_TRANSACTION_ID' VERIFY_COMMAND_B64='$DEPLOY_VERIFY_COMMAND_B64' bash -s" <<'REMOTE'
set -euo pipefail
deploy_dir="$HOME/$DEPLOY_DIRECTORY"
state_dir="$HOME/.development-deploy-transactions/$TRANSACTION_ID"
active_pointer="$HOME/.development-deploy-transactions/active"
env_file="$deploy_dir/.env"
test -f "$state_dir/ready"
test -f "$state_dir/deployment-started"
test -f "$active_pointer"
test "$(cat "$active_pointer")" = "$TRANSACTION_ID"
test "$(cat "$state_dir/deploy-directory")" = "$DEPLOY_DIRECTORY"
test "$(cat "$state_dir/compose-file")" = "$COMPOSE_FILE"
test "$(cat "$state_dir/compose-project")" = "$COMPOSE_PROJECT"
test "$(cat "$state_dir/service-name")" = "$SERVICE_NAME"
test "$(cat "$state_dir/network-service")" = "$NETWORK_SERVICE"
test -f "$deploy_dir/$COMPOSE_FILE"
test -f "$env_file"

service_id="$(docker compose -p "$COMPOSE_PROJECT" -f "$deploy_dir/$COMPOSE_FILE" --env-file "$env_file" ps -q "$SERVICE_NAME")"
network_id="$(docker compose -p "$COMPOSE_PROJECT" -f "$deploy_dir/$COMPOSE_FILE" --env-file "$env_file" ps -q "$NETWORK_SERVICE")"
test -n "$service_id"
test -n "$network_id"

attempt=0
until docker exec "$network_id" tailscale status --json | grep -q '"Online": true'; do
  attempt=$((attempt + 1))
  test "$attempt" -lt 45
  sleep 2
done

attempt=0
until test "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$service_id")" = healthy; do
  attempt=$((attempt + 1))
  test "$attempt" -lt 60
  sleep 2
done

verify_command="$(printf '%s' "$VERIFY_COMMAND_B64" | base64 -d)"
test -n "$verify_command"
docker exec "$service_id" sh -lc "$verify_command"
REMOTE

echo "Development deployment health and verification checks passed"
if test -n "${GITHUB_STEP_SUMMARY:-}"; then
  {
    echo "### Development deployment verification"
    echo
    echo "- Service health: passed"
    echo "- Network health: passed"
    echo "- Project verification: passed"
  } >> "$GITHUB_STEP_SUMMARY"
fi
