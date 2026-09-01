#!/usr/bin/env bash
set -euo pipefail

required=(
  BUILD_ID DEPLOY_BUILD_VARIABLE DEPLOY_COMPOSE_FILE DEPLOY_COMPOSE_PROJECT
  DEPLOY_DATA_DIRECTORIES DEPLOY_DIRECTORY DEPLOY_ENV_FILE_B64 DEPLOY_FILES DEPLOY_IMAGE_VARIABLE
  DEPLOY_NETWORK_SERVICE DEPLOY_NETWORK_STATE_FILE DEPLOY_SERVICE_NAME IMAGE_REF
  R2_ACCESS_KEY_ID R2_ARCHIVE_SHA256 R2_BUCKET R2_ENDPOINT R2_OBJECT_KEY
  R2_SECRET_ACCESS_KEY REGISTRY_HOST REGISTRY_USERNAME REGISTRY_WRITE_TOKEN
  RELAY_ENCRYPTION_KEY RUNNER_TEMP TARGET_SSH_HOST TARGET_SSH_KNOWN_HOSTS
  TARGET_SSH_PRIVATE_KEY TARGET_SSH_USER
)
for name in "${required[@]}"; do
  test -n "${!name:-}" || { echo "$name is required" >&2; exit 2; }
done
SOURCE_DIR="${SOURCE_DIR:-$RUNNER_TEMP/private-source}"

[[ "$BUILD_ID" =~ ^[0-9a-f]{40}$ ]]
[[ "$DEPLOY_BUILD_VARIABLE" =~ ^[A-Z][A-Z0-9_]*$ ]]
[[ "$DEPLOY_COMPOSE_PROJECT" =~ ^[A-Za-z0-9._-]+$ ]]
[[ "$DEPLOY_DIRECTORY" =~ ^[A-Za-z0-9._/-]+$ && "$DEPLOY_DIRECTORY" != /* && "$DEPLOY_DIRECTORY" != *..* ]]
[[ "$DEPLOY_IMAGE_VARIABLE" =~ ^[A-Z][A-Z0-9_]*$ ]]
[[ "$DEPLOY_NETWORK_SERVICE" =~ ^[A-Za-z0-9._-]+$ ]]
[[ "$DEPLOY_SERVICE_NAME" =~ ^[A-Za-z0-9._-]+$ ]]
[[ "$IMAGE_REF" =~ ^[A-Za-z0-9._:/-]+$ ]]
[[ "$TARGET_SSH_HOST" =~ ^[A-Za-z0-9.:-]+$ ]]
[[ "$TARGET_SSH_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]
[[ "$R2_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]]
[[ "$R2_BUCKET" =~ ^[A-Za-z0-9._-]+$ ]]
[[ "$R2_ENDPOINT" == https://* ]]
[[ "$R2_OBJECT_KEY" =~ ^relay/[A-Za-z0-9._-]+$ ]]
[[ "$REGISTRY_HOST" =~ ^[A-Za-z0-9.:-]+$ ]]
[[ "$REGISTRY_USERNAME" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]

validate_relative_path() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9._/-]+$ && "$value" != /* && "$value" != *..* ]]
}
validate_relative_path "$DEPLOY_COMPOSE_FILE"
validate_relative_path "$DEPLOY_NETWORK_STATE_FILE"

deploy_files=("$DEPLOY_COMPOSE_FILE")
while IFS= read -r path; do
  test -z "$path" && continue
  validate_relative_path "$path"
  deploy_files+=("$path")
done <<< "$DEPLOY_FILES"
for path in "${deploy_files[@]}"; do
  test -f "$SOURCE_DIR/$path" || { echo "Deployment file is unavailable: $path" >&2; exit 2; }
done

while IFS= read -r path; do
  test -z "$path" && continue
  validate_relative_path "$path"
done <<< "$DEPLOY_DATA_DIRECTORIES"

key_file="$RUNNER_TEMP/deploy-key"
known_hosts="$RUNNER_TEMP/deploy-known-hosts"
payload="$RUNNER_TEMP/development-deploy-input"
printf '%s\n' "$TARGET_SSH_PRIVATE_KEY" > "$key_file"
printf '%s\n' "$TARGET_SSH_KNOWN_HOSTS" > "$known_hosts"
chmod 600 "$key_file" "$known_hosts"
ssh_args=(-i "$key_file" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts")
target="$TARGET_SSH_USER@$TARGET_SSH_HOST"
ssh "${ssh_args[@]}" "$target" true

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto
export AWS_EC2_METADATA_DISABLED=true
relay_uri="s3://$R2_BUCKET/$R2_OBJECT_KEY"
cleanup() {
  aws s3 rm --only-show-errors --endpoint-url "$R2_ENDPOINT" "$relay_uri" >/dev/null 2>&1 || true
  rm -f "$payload"
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
}
trap cleanup EXIT
relay_url="$(aws s3 presign --endpoint-url "$R2_ENDPOINT" --expires-in 1800 "$relay_uri")"
relay_passphrase="$(printf '%s' "$RELAY_ENCRYPTION_KEY:$BUILD_ID:$R2_OBJECT_KEY" | sha256sum | cut -d ' ' -f 1)"

remote_staging="/tmp/development-source-$BUILD_ID"
tar -C "$SOURCE_DIR" -czf - "${deploy_files[@]}" \
  | ssh "${ssh_args[@]}" "$target" \
      "set -eu; rm -rf '$remote_staging'; install -d -m 0700 '$remote_staging'; tar -xzf - -C '$remote_staging'"

auth_key=""
if ! ssh "${ssh_args[@]}" "$target" "test -s \"\$HOME/$DEPLOY_DIRECTORY/$DEPLOY_NETWORK_STATE_FILE\""; then
  auth_key="$(node "$SOURCE_DIR/scripts/create-tailscale-auth-key.mjs")"
fi

encode() { printf '%s' "$1" | base64 | tr -d '\n'; }
values=(
  "$REGISTRY_WRITE_TOKEN" "$REGISTRY_HOST" "$REGISTRY_USERNAME" "$IMAGE_REF"
  "$auth_key" "$relay_url" "$relay_passphrase" "$R2_ARCHIVE_SHA256"
  "$DEPLOY_ENV_FILE_B64" "$DEPLOY_COMPOSE_FILE" "$DEPLOY_COMPOSE_PROJECT"
  "$DEPLOY_SERVICE_NAME" "$DEPLOY_NETWORK_SERVICE" "$DEPLOY_NETWORK_STATE_FILE"
  "$DEPLOY_IMAGE_VARIABLE" "$DEPLOY_BUILD_VARIABLE" "${DEPLOY_VERIFY_COMMAND_B64:-}"
  "$DEPLOY_DATA_DIRECTORIES" "$(printf '%s\n' "${deploy_files[@]}")" "$BUILD_ID"
)
for value in "${values[@]}"; do
  encode "$value"
  printf '\n'
done > "$payload"
chmod 600 "$payload"
remote_payload="/tmp/development-deploy-$BUILD_ID"
scp "${ssh_args[@]}" "$payload" "$target:$remote_payload"

ssh "${ssh_args[@]}" "$target" \
  "DEPLOY_DIRECTORY='$DEPLOY_DIRECTORY' REMOTE_PAYLOAD='$remote_payload' REMOTE_STAGING='$remote_staging' bash -s" <<'REMOTE'
set -euo pipefail
decode() { printf '%s' "$1" | base64 -d; }
mapfile -t lines < "$REMOTE_PAYLOAD"
registry_token="$(decode "${lines[0]}")"
registry_host="$(decode "${lines[1]}")"
registry_user="$(decode "${lines[2]}")"
image_ref="$(decode "${lines[3]}")"
auth_key="$(decode "${lines[4]}")"
relay_url="$(decode "${lines[5]}")"
relay_passphrase="$(decode "${lines[6]}")"
relay_sha256="$(decode "${lines[7]}")"
env_file_b64="$(decode "${lines[8]}")"
compose_file="$(decode "${lines[9]}")"
compose_project="$(decode "${lines[10]}")"
service_name="$(decode "${lines[11]}")"
network_service="$(decode "${lines[12]}")"
network_state_file="$(decode "${lines[13]}")"
image_variable="$(decode "${lines[14]}")"
build_variable="$(decode "${lines[15]}")"
verify_command_b64="$(decode "${lines[16]}")"
data_directories="$(decode "${lines[17]}")"
deploy_files="$(decode "${lines[18]}")"
build_id="$(decode "${lines[19]}")"

deploy_dir="$HOME/$DEPLOY_DIRECTORY"
env_file="$deploy_dir/.env"
backup_dir="/tmp/development-backup-$build_id"
archive="/tmp/development-image-$RANDOM.enc"
image_tar="/tmp/development-image-$RANDOM.tar"
old_image=""
had_env=false
deployment_started=false

install -d -m 0700 "$deploy_dir" "$backup_dir"
while IFS= read -r path; do
  test -z "$path" && continue
  install -d -m 0700 "$deploy_dir/$path"
done <<< "$data_directories"

if test -f "$env_file"; then
  cp -p "$env_file" "$backup_dir/env"
  had_env=true
fi
while IFS= read -r path; do
  test -z "$path" && continue
  if test -e "$deploy_dir/$path"; then
    install -d "$backup_dir/files/$(dirname "$path")"
    cp -a "$deploy_dir/$path" "$backup_dir/files/$path"
  fi
done <<< "$deploy_files"

if test -f "$deploy_dir/$compose_file" && test -f "$env_file"; then
  old_service_id="$(docker compose -p "$compose_project" -f "$deploy_dir/$compose_file" --env-file "$env_file" ps -q "$service_name" 2>/dev/null || true)"
  if test -n "$old_service_id"; then
    old_image="$(docker inspect --format '{{.Config.Image}}' "$old_service_id")"
  fi
fi

rollback() {
  status=$?
  rm -f "$REMOTE_PAYLOAD" "$archive" "$image_tar"
  rm -rf "$REMOTE_STAGING"
  docker logout "$registry_host" >/dev/null 2>&1 || true
  if test "$status" -ne 0 && test "$deployment_started" = true; then
    while IFS= read -r path; do
      test -z "$path" && continue
      rm -rf "$deploy_dir/$path"
      if test -e "$backup_dir/files/$path"; then
        install -d "$deploy_dir/$(dirname "$path")"
        cp -a "$backup_dir/files/$path" "$deploy_dir/$path"
      fi
    done <<< "$deploy_files"
    if test "$had_env" = true; then
      cp -p "$backup_dir/env" "$env_file"
    else
      rm -f "$env_file"
    fi
    if test -n "$old_image" && test -f "$deploy_dir/$compose_file" && test -f "$env_file"; then
      docker compose -p "$compose_project" -f "$deploy_dir/$compose_file" --env-file "$env_file" up -d --pull never --remove-orphans >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "$backup_dir"
  exit "$status"
}
trap rollback EXIT

curl --fail --silent --show-error --location --retry 3 --output "$archive" "$relay_url"
printf '%s  %s\n' "$relay_sha256" "$archive" | sha256sum -c - >/dev/null
export relay_passphrase
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:relay_passphrase -in "$archive" \
  | zstd -d --quiet -o "$image_tar"
unset relay_passphrase
docker load --input "$image_tar" >/dev/null
docker image inspect "$image_ref" >/dev/null
printf '%s' "$registry_token" | docker login "$registry_host" --username "$registry_user" --password-stdin >/dev/null
docker push "$image_ref" >/dev/null

deployment_started=true
while IFS= read -r path; do
  test -z "$path" && continue
  install -d "$deploy_dir/$(dirname "$path")"
  cp -a "$REMOTE_STAGING/$path" "$deploy_dir/$path"
done <<< "$deploy_files"

umask 077
printf '%s' "$env_file_b64" | base64 -d > "$env_file"
sed -i "/^${image_variable}=/d;/^${build_variable}=/d;/^TS_AUTHKEY=/d" "$env_file"
printf '\n%s=%s\n%s=%s\n' "$image_variable" "$image_ref" "$build_variable" "$build_id" >> "$env_file"
if test -n "$auth_key"; then
  printf 'TS_AUTHKEY=%s\n' "$auth_key" >> "$env_file"
fi
chmod 0600 "$env_file"

cd "$deploy_dir"
docker compose -p "$compose_project" -f "$compose_file" --env-file .env up -d --pull never --remove-orphans
service_id="$(docker compose -p "$compose_project" -f "$compose_file" --env-file .env ps -q "$service_name")"
network_id="$(docker compose -p "$compose_project" -f "$compose_file" --env-file .env ps -q "$network_service")"
test -n "$service_id" && test -n "$network_id"

attempt=0
until docker exec "$network_id" tailscale status --json | grep -q '"Online": true'; do
  attempt=$((attempt + 1)); test "$attempt" -lt 45; sleep 2
done
attempt=0
until test "$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$service_id")" = healthy; do
  attempt=$((attempt + 1)); test "$attempt" -lt 60; sleep 2
done
if test -n "$verify_command_b64"; then
  verify_command="$(printf '%s' "$verify_command_b64" | base64 -d)"
  docker exec "$service_id" sh -lc "$verify_command"
fi

sed -i '/^TS_AUTHKEY=/d' "$env_file"
chmod 0600 "$env_file"
trap - EXIT
rollback
REMOTE

echo "Development service deployment verified"
