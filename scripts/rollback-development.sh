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

rollback_result_file="$(mktemp "$RUNNER_TEMP/development-rollback-result.XXXXXX")"
ssh "${ssh_args[@]}" "$target" \
    "TRANSACTION_ID='$DEPLOY_TRANSACTION_ID' bash -s" > "$rollback_result_file" <<'REMOTE'
set -euo pipefail

validate_relative_path() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  [[ "$value" != /* && "$value" != -* && "$value" != */ ]] || return 1
  case "/$value/" in
    *//*|*/./*|*/../*) return 1 ;;
  esac
}
validate_identifier() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

state_root="$HOME/.development-deploy-transactions"
state_dir="$state_root/$TRANSACTION_ID"
active_pointer="$state_root/active"
active_id=""
if test -e "$active_pointer"; then
  test -f "$active_pointer"
  active_id="$(cat "$active_pointer")"
  validate_identifier "$active_id"
fi

if ! test -f "$state_dir/ready"; then
  if test "$active_id" = "$TRANSACTION_ID"; then
    rm -f "$active_pointer"
  fi
  rm -rf "$state_dir"
  echo "not-started"
  exit 0
fi

if ! test -f "$state_dir/deployment-started"; then
  if test "$active_id" = "$TRANSACTION_ID"; then
    rm -f "$active_pointer"
  fi
  rm -rf "$state_dir"
  echo "not-started"
  exit 0
fi

test "$active_id" = "$TRANSACTION_ID" || {
  echo "Active development transaction does not match rollback state" >&2
  exit 1
}
for metadata_file in deploy-directory compose-file compose-project service-name network-service files-list; do
  test -f "$state_dir/$metadata_file"
done

deploy_directory="$(cat "$state_dir/deploy-directory")"
compose_file="$(cat "$state_dir/compose-file")"
compose_project="$(cat "$state_dir/compose-project")"
service_name="$(cat "$state_dir/service-name")"
network_service="$(cat "$state_dir/network-service")"
validate_relative_path "$deploy_directory"
validate_relative_path "$compose_file"
validate_identifier "$compose_project"
validate_identifier "$service_name"
validate_identifier "$network_service"

for command_name in docker grep timeout; do
  command -v "$command_name" >/dev/null || {
    echo "Required rollback command is unavailable: $command_name" >&2
    exit 1
  }
done
docker compose version >/dev/null

deploy_dir="$HOME/$deploy_directory"
env_file="$deploy_dir/.env"

if test -f "$deploy_dir/$compose_file" && test -f "$env_file" && \
    docker compose -p "$compose_project" -f "$deploy_dir/$compose_file" --env-file "$env_file" config >/dev/null 2>&1; then
  echo "Collecting opted-in deployment diagnostics before rollback." >&2
  docker compose -p "$compose_project" -f "$deploy_dir/$compose_file" --env-file "$env_file" ps --all >&2 || true
  while IFS= read -r container_id; do
    test -z "$container_id" && continue
    diagnostic="$(docker inspect --format '{{ index .Config.Labels "io.private-build-controller.diagnostics" }}' "$container_id" 2>/dev/null || true)"
    test "$diagnostic" = true || continue
    service="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.service" }}' "$container_id" 2>/dev/null || true)"
    validate_identifier "$service" || continue
    echo "Diagnostic logs for an opted-in service follow." >&2
    docker compose -p "$compose_project" -f "$deploy_dir/$compose_file" --env-file "$env_file" \
      logs --no-color --tail 120 "$service" >&2 || true
  done < <(docker compose -p "$compose_project" -f "$deploy_dir/$compose_file" --env-file "$env_file" ps -aq || true)
  timeout --signal=TERM --kill-after=30s 2m \
    docker compose -p "$compose_project" -f "$deploy_dir/$compose_file" --env-file "$env_file" \
      down --remove-orphans >/dev/null 2>&1 || true
fi

current_container_output="$(docker ps -aq --filter "label=com.docker.compose.project=$compose_project")"
current_containers=()
if test -n "$current_container_output"; then
  while IFS= read -r container_id; do
    test -z "$container_id" || current_containers+=("$container_id")
  done <<< "$current_container_output"
fi
if (( ${#current_containers[@]} > 0 )); then
  timeout --signal=TERM --kill-after=30s 2m docker rm -f "${current_containers[@]}" >/dev/null
fi

while IFS= read -r path; do
  test -z "$path" && continue
  validate_relative_path "$path"
  rm -rf -- "$deploy_dir/$path"
  if test -e "$state_dir/files/$path"; then
    install -d "$deploy_dir/$(dirname "$path")"
    cp -a -- "$state_dir/files/$path" "$deploy_dir/$path"
  fi
done < "$state_dir/files-list"

if test -f "$state_dir/had-env"; then
  install -d "$deploy_dir"
  cp -p "$state_dir/env" "$env_file"
else
  rm -f "$env_file"
fi

if test -f "$state_dir/created-data-directories"; then
  while IFS= read -r path; do
    test -z "$path" && continue
    validate_relative_path "$path"
    rm -rf -- "$deploy_dir/$path"
  done < "$state_dir/created-data-directories"
fi

if test -f "$state_dir/had-service"; then
  test -f "$deploy_dir/$compose_file"
  test -f "$env_file"
  expected_image_id="$(cat "$state_dir/service-image-id")"
  expected_image_ref="$(cat "$state_dir/service-image-ref")"
  [[ "$expected_image_id" =~ ^sha256:[0-9a-f]{64}$ ]]
  test -n "$expected_image_ref"
  docker image inspect "$expected_image_id" >/dev/null
  if [[ "$expected_image_ref" != *@sha256:* ]]; then
    docker image tag "$expected_image_id" "$expected_image_ref"
  fi
  timeout --signal=TERM --kill-after=30s 5m \
    docker compose -p "$compose_project" -f "$deploy_dir/$compose_file" --env-file "$env_file" \
      up -d --pull never --remove-orphans >/dev/null

  service_id="$(docker compose -p "$compose_project" -f "$deploy_dir/$compose_file" --env-file "$env_file" ps -q "$service_name")"
  network_id="$(docker compose -p "$compose_project" -f "$deploy_dir/$compose_file" --env-file "$env_file" ps -q "$network_service")"
  test -n "$service_id"
  test -n "$network_id"
  test "$(docker inspect --format '{{.Image}}' "$service_id")" = "$expected_image_id"

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
  result="restored-healthy"
else
  remaining_containers="$(docker ps -aq --filter "label=com.docker.compose.project=$compose_project")"
  test -z "$remaining_containers"
  if ! test -f "$state_dir/had-deploy-directory"; then
    rmdir "$deploy_dir" >/dev/null 2>&1 || true
  fi
  result="restored-absent"
fi

test "$(cat "$active_pointer")" = "$TRANSACTION_ID"
rm -f "$active_pointer"
rm -rf "$state_dir"
echo "$result"
REMOTE
rollback_result="$(cat "$rollback_result_file")"
rm -f "$rollback_result_file"

case "$rollback_result" in
  not-started|restored-healthy|restored-absent) ;;
  *) echo "Unexpected rollback result" >&2; exit 1 ;;
esac

echo "Development rollback completed and verified"
if test -n "${GITHUB_STEP_SUMMARY:-}"; then
  health_result="passed"
  if test "$rollback_result" = not-started; then
    health_result="not required"
  fi
  {
    echo "### Development rollback evidence"
    echo
    echo "- Rollback result: verified"
    echo "- Previous runtime state: restored"
    echo "- Post-rollback health: $health_result"
  } >> "$GITHUB_STEP_SUMMARY"
fi
