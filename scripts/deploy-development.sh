#!/usr/bin/env bash
set -euo pipefail

required=(
  BUILD_ID DEPLOY_BUILD_VARIABLE DEPLOY_COMPOSE_FILE DEPLOY_COMPOSE_PROJECT
  DEPLOY_DATA_DIRECTORIES DEPLOY_DIRECTORY DEPLOY_ENV_FILE_B64 DEPLOY_FILES DEPLOY_IMAGE_VARIABLE
  DEPLOY_NETWORK_SERVICE DEPLOY_NETWORK_STATE_FILE DEPLOY_SERVICE_NAME IMAGE_REF
  R2_ACCESS_KEY_ID R2_ARCHIVE_SHA256 R2_BUCKET R2_ENDPOINT R2_OBJECT_KEY
  R2_SECRET_ACCESS_KEY REGISTRY_HOST REGISTRY_USERNAME REGISTRY_WRITE_TOKEN
  GITHUB_OUTPUT RELAY_ENCRYPTION_KEY RUNNER_TEMP TARGET_SSH_HOST TARGET_SSH_KNOWN_HOSTS
  TARGET_SSH_PRIVATE_KEY TARGET_SSH_USER
)
for name in "${required[@]}"; do
  test -n "${!name:-}" || { echo "$name is required" >&2; exit 2; }
done
SOURCE_DIR="${SOURCE_DIR:-$RUNNER_TEMP/private-source}"

for command_name in aws base64 node scp sha256sum ssh tar; do
  command -v "$command_name" >/dev/null || {
    echo "Required command is unavailable: $command_name" >&2
    exit 1
  }
done

[[ "$BUILD_ID" =~ ^[0-9a-f]{40}$ ]]
[[ "$DEPLOY_BUILD_VARIABLE" =~ ^[A-Z][A-Z0-9_]*$ ]]
[[ "$DEPLOY_COMPOSE_PROJECT" =~ ^[A-Za-z0-9._-]+$ ]]
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
  [[ "$value" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  [[ "$value" != /* && "$value" != -* && "$value" != */ ]] || return 1
  case "/$value/" in
    *//*|*/./*|*/../*) return 1 ;;
  esac
}
validate_relative_path "$DEPLOY_DIRECTORY"
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
remote_staging="/tmp/development-source-$BUILD_ID"
remote_payload="/tmp/development-deploy-$BUILD_ID"
printf '%s\n' "$TARGET_SSH_PRIVATE_KEY" > "$key_file"
printf '%s\n' "$TARGET_SSH_KNOWN_HOSTS" > "$known_hosts"
chmod 600 "$key_file" "$known_hosts"
ssh_args=(
  -i "$key_file" -o BatchMode=yes -o ConnectTimeout=10
  -o ServerAliveCountMax=3 -o ServerAliveInterval=15
  -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts"
)
target="$TARGET_SSH_USER@$TARGET_SSH_HOST"
transaction_id="${GITHUB_RUN_ID:-manual}-${GITHUB_RUN_ATTEMPT:-1}-${BUILD_ID:0:12}"
[[ "$transaction_id" =~ ^[A-Za-z0-9._-]+$ ]]
printf 'transaction_id=%s\n' "$transaction_id" >> "$GITHUB_OUTPUT"
ssh "${ssh_args[@]}" "$target" true

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto
export AWS_EC2_METADATA_DISABLED=true
relay_uri="s3://$R2_BUCKET/$R2_OBJECT_KEY"
cleanup() {
  set +e
  aws s3 rm --only-show-errors --endpoint-url "$R2_ENDPOINT" "$relay_uri" >/dev/null 2>&1
  ssh "${ssh_args[@]}" "$target" \
    "rm -f '$remote_payload'; rm -rf '$remote_staging'" >/dev/null 2>&1
  rm -f "$payload"
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
}
trap 'status=$?; trap - EXIT; cleanup; exit "$status"' EXIT
relay_url="$(aws s3 presign --endpoint-url "$R2_ENDPOINT" --expires-in 3600 "$relay_uri")"
relay_passphrase="$(printf '%s' "$RELAY_ENCRYPTION_KEY:$BUILD_ID:$R2_OBJECT_KEY" | sha256sum | cut -d ' ' -f 1)"

tar -C "$SOURCE_DIR" -czf - -- "${deploy_files[@]}" \
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
  "$DEPLOY_IMAGE_VARIABLE" "$DEPLOY_BUILD_VARIABLE" "$DEPLOY_DATA_DIRECTORIES"
  "$(printf '%s\n' "${deploy_files[@]}")" "$BUILD_ID" "$transaction_id"
)
for value in "${values[@]}"; do
  encode "$value"
  printf '\n'
done > "$payload"
chmod 600 "$payload"
scp "${ssh_args[@]}" "$payload" "$target:$remote_payload"

ssh "${ssh_args[@]}" "$target" \
  "DEPLOY_DIRECTORY='$DEPLOY_DIRECTORY' REMOTE_PAYLOAD='$remote_payload' REMOTE_STAGING='$remote_staging' bash -s" <<'REMOTE'
set -euo pipefail
decode() { printf '%s' "$1" | base64 -d; }
lines=()
while IFS= read -r line || test -n "$line"; do
  lines+=("$line")
done < "$REMOTE_PAYLOAD"
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
data_directories="$(decode "${lines[16]}")"
deploy_files="$(decode "${lines[17]}")"
build_id="$(decode "${lines[18]}")"
transaction_id="$(decode "${lines[19]}")"

for command_name in base64 curl docker install ln openssl sed sha256sum sleep timeout zstd; do
  command -v "$command_name" >/dev/null || {
    echo "Required remote command is unavailable: $command_name" >&2
    exit 1
  }
done
docker compose version >/dev/null

deploy_dir="$HOME/$DEPLOY_DIRECTORY"
env_file="$deploy_dir/.env"
state_root="$HOME/.development-deploy-transactions"
state_dir="$state_root/$transaction_id"
active_pointer="$state_root/active"
archive="/tmp/development-image-$RANDOM.enc"
image_tar="/tmp/development-image-$RANDOM.tar"

cleanup_remote() {
  status=$?
  rm -f "$REMOTE_PAYLOAD" "$archive" "$image_tar"
  rm -rf "$REMOTE_STAGING"
  if test -d "$state_dir" && \
      { ! test -f "$active_pointer" || test "$(cat "$active_pointer")" != "$transaction_id"; }; then
    rm -rf "$state_dir"
  fi
  docker logout "$registry_host" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup_remote EXIT

test ! -e "$state_dir"
install -d -m 0700 "$state_root" "$state_dir" "$state_dir/files"
chmod 0700 "$state_root"
test ! -e "$deploy_dir" || test -d "$deploy_dir"
if test -d "$deploy_dir"; then
  touch "$state_dir/had-deploy-directory"
fi

if test -f "$env_file"; then
  cp -p "$env_file" "$state_dir/env"
  touch "$state_dir/had-env"
fi
printf '%s\n' "$deploy_files" > "$state_dir/files-list"
chmod 0600 "$state_dir/files-list"
while IFS= read -r path; do
  test -z "$path" && continue
  if test -e "$deploy_dir/$path"; then
    install -d "$state_dir/files/$(dirname "$path")"
    cp -a "$deploy_dir/$path" "$state_dir/files/$path"
  fi
done <<< "$deploy_files"

if test -f "$deploy_dir/$compose_file" && test -f "$env_file"; then
  if ! docker compose -p "$compose_project" -f "$deploy_dir/$compose_file" --env-file "$env_file" config --images \
      > "$state_dir/compose-images" 2>/dev/null; then
    echo "Previous Compose state is invalid" >&2
    exit 1
  fi
  while IFS= read -r previous_image; do
    test -z "$previous_image" && continue
    docker image inspect "$previous_image" >/dev/null
  done < "$state_dir/compose-images"
  old_service_id="$(docker compose -p "$compose_project" -f "$deploy_dir/$compose_file" --env-file "$env_file" ps -q "$service_name" 2>/dev/null || true)"
  if test -n "$old_service_id"; then
    docker inspect --format '{{.Image}}' "$old_service_id" > "$state_dir/service-image-id"
    docker inspect --format '{{.Config.Image}}' "$old_service_id" > "$state_dir/service-image-ref"
    docker image inspect "$(cat "$state_dir/service-image-id")" >/dev/null
    touch "$state_dir/had-service"
  fi
fi

printf '%s' "$DEPLOY_DIRECTORY" > "$state_dir/deploy-directory"
printf '%s' "$compose_file" > "$state_dir/compose-file"
printf '%s' "$compose_project" > "$state_dir/compose-project"
printf '%s' "$service_name" > "$state_dir/service-name"
printf '%s' "$network_service" > "$state_dir/network-service"
while IFS= read -r path; do
  test -z "$path" && continue
  if ! test -e "$deploy_dir/$path"; then
    printf '%s\n' "$path" >> "$state_dir/created-data-directories"
  fi
done <<< "$data_directories"
touch "$state_dir/ready"
chmod -R go-rwx "$state_dir"

# Publish a fully written transaction handle before any live deployment mutation.
printf '%s\n' "$transaction_id" > "$state_dir/active-pointer"
chmod 0600 "$state_dir/active-pointer"
if ! ln "$state_dir/active-pointer" "$active_pointer"; then
  echo "Another development deployment transaction is active" >&2
  exit 1
fi

relay_downloaded=false
for attempt in 1 2 3 4 5 6; do
  if curl --fail --silent --show-error --location --continue-at - \
      --connect-timeout 10 --max-time 300 --output "$archive" "$relay_url"; then
    relay_downloaded=true
    break
  fi
  if test -s "$archive" && \
      printf '%s  %s\n' "$relay_sha256" "$archive" | sha256sum -c - >/dev/null 2>&1; then
    relay_downloaded=true
    break
  fi
  test "$attempt" -eq 6 || sleep $((attempt * 2))
done
if test "$relay_downloaded" != true; then
  echo "Relay download failed after resumable attempts" >&2
  exit 1
fi
printf '%s  %s\n' "$relay_sha256" "$archive" | sha256sum -c - >/dev/null
export relay_passphrase
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:relay_passphrase -in "$archive" \
  | zstd -d --quiet -o "$image_tar"
unset relay_passphrase
docker load --input "$image_tar" >/dev/null
if ! docker image inspect "$image_ref" >/dev/null 2>&1; then
  echo "Loaded image verification failed" >&2
  exit 1
fi
if ! printf '%s' "$registry_token" | docker login "$registry_host" --username "$registry_user" --password-stdin >/dev/null 2>&1; then
  echo "Registry authentication failed" >&2
  exit 1
fi
if ! timeout --signal=TERM --kill-after=30s 10m docker push "$image_ref" >/dev/null 2>&1; then
  echo "Image publication failed" >&2
  exit 1
fi

touch "$state_dir/deployment-started"
install -d -m 0700 "$deploy_dir"
while IFS= read -r path; do
  test -z "$path" && continue
  install -d -m 0700 "$deploy_dir/$path"
done <<< "$data_directories"

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
if ! timeout --signal=TERM --kill-after=30s 5m \
    docker compose -p "$compose_project" -f "$compose_file" --env-file .env \
    up -d --pull never --remove-orphans >/dev/null 2>&1; then
  echo "Compose deployment failed" >&2
  exit 1
fi
service_id="$(docker compose -p "$compose_project" -f "$compose_file" --env-file .env ps -q "$service_name" 2>/dev/null)"
network_id="$(docker compose -p "$compose_project" -f "$compose_file" --env-file .env ps -q "$network_service" 2>/dev/null)"
test -n "$service_id" && test -n "$network_id"

sed -i '/^TS_AUTHKEY=/d' "$env_file"
chmod 0600 "$env_file"
REMOTE

echo "Development service deployed; transaction retained for verification"
