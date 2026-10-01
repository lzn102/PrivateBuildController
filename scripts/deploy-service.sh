#!/usr/bin/env bash
set -euo pipefail
IMAGE_TRANSPORT="${IMAGE_TRANSPORT:-relay}"
case "$IMAGE_TRANSPORT" in relay|registry) ;; *) exit 2 ;; esac

: "${BUILD_ID:?BUILD_ID is required}"
: "${DEPLOY_DIRECTORY:?DEPLOY_DIRECTORY is required}"
: "${IMAGE_REF:?IMAGE_REF is required}"
: "${TARGET_SSH_HOST:?TARGET_SSH_HOST is required}"
: "${TARGET_SSH_KNOWN_HOSTS:?TARGET_SSH_KNOWN_HOSTS is required}"
: "${TARGET_SSH_PRIVATE_KEY:?TARGET_SSH_PRIVATE_KEY is required}"
: "${TARGET_SSH_USER:?TARGET_SSH_USER is required}"
: "${REGISTRY_HOST:?REGISTRY_HOST is required}"
: "${REGISTRY_WRITE_TOKEN:?REGISTRY_WRITE_TOKEN is required}"
: "${REGISTRY_USERNAME:?REGISTRY_USERNAME is required}"
if test "$IMAGE_TRANSPORT" = relay; then
: "${RELAY_ENCRYPTION_KEY:?RELAY_ENCRYPTION_KEY is required}"
: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is required}"
: "${R2_ARCHIVE_SHA256:?R2_ARCHIVE_SHA256 is required}"
: "${R2_BUCKET:?R2_BUCKET is required}"
: "${R2_ENDPOINT:?R2_ENDPOINT is required}"
: "${R2_OBJECT_KEY:?R2_OBJECT_KEY is required}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is required}"
else
  : "${REGISTRY_SOURCE_IMAGE:?}"
  : "${REGISTRY_SOURCE_DIGEST:?}"
  : "${REGISTRY_SOURCE_USER:?}"
  : "${REGISTRY_SOURCE_TOKEN:?}"
  [[ "$REGISTRY_SOURCE_IMAGE" == "$REGISTRY_HOST/"* ]]
  [[ "$REGISTRY_SOURCE_IMAGE" =~ ^[A-Za-z0-9._:/-]+$ ]]
  [[ "$REGISTRY_SOURCE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]
fi
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${SERVICE_COMPOSE_NAME:?SERVICE_COMPOSE_NAME is required}"
: "${SERVICE_IMAGE_VARIABLE:?SERVICE_IMAGE_VARIABLE is required}"
: "${TAILSCALE_COMPOSE_NAME:?TAILSCALE_COMPOSE_NAME is required}"
SOURCE_DIR="${SOURCE_DIR:-$RUNNER_TEMP/private-source}"

[[ "$BUILD_ID" =~ ^[0-9a-f]{40}$ ]]
[[ "$DEPLOY_DIRECTORY" =~ ^[A-Za-z0-9._/-]+$ ]]
[[ "$DEPLOY_DIRECTORY" != /* && "$DEPLOY_DIRECTORY" != *..* ]]
[[ "$IMAGE_REF" =~ ^[A-Za-z0-9._:/-]+$ ]]
[[ "$TARGET_SSH_HOST" =~ ^[A-Za-z0-9.:-]+$ ]]
[[ "$TARGET_SSH_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]
[[ "$REGISTRY_HOST" =~ ^[A-Za-z0-9.:-]+$ ]]
[[ "$REGISTRY_USERNAME" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]
if test "$IMAGE_TRANSPORT" = relay; then
[[ "$R2_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]]
[[ "$R2_BUCKET" =~ ^[A-Za-z0-9._-]+$ ]]
[[ "$R2_ENDPOINT" == https://* ]]
[[ "$R2_OBJECT_KEY" =~ ^relay/[A-Za-z0-9._-]+$ ]]
fi
[[ "$SERVICE_COMPOSE_NAME" =~ ^[A-Za-z0-9._-]+$ ]]
[[ "$SERVICE_IMAGE_VARIABLE" =~ ^[A-Z][A-Z0-9_]*$ ]]
[[ "$TAILSCALE_COMPOSE_NAME" =~ ^[A-Za-z0-9._-]+$ ]]

key_file="$RUNNER_TEMP/deploy-key"
known_hosts="$RUNNER_TEMP/deploy-known-hosts"
printf '%s\n' "$TARGET_SSH_PRIVATE_KEY" > "$key_file"
printf '%s\n' "$TARGET_SSH_KNOWN_HOSTS" > "$known_hosts"
chmod 600 "$key_file" "$known_hosts"

ssh_args=(-i "$key_file" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts")
target="$TARGET_SSH_USER@$TARGET_SSH_HOST"
ssh "${ssh_args[@]}" "$target" true

commands=(ssh scp)
if test "$IMAGE_TRANSPORT" = relay; then commands+=(aws openssl sha256sum); fi
for command_name in "${commands[@]}"; do
  command -v "$command_name" >/dev/null || {
    echo "Required command is unavailable: $command_name" >&2
    exit 1
  }
done
relay_url=""
relay_passphrase=""
if test "$IMAGE_TRANSPORT" = relay; then
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION=auto
export AWS_EC2_METADATA_DISABLED=true
relay_uri="s3://$R2_BUCKET/$R2_OBJECT_KEY"
cleanup_relay() {
  aws s3 rm --only-show-errors --endpoint-url "$R2_ENDPOINT" "$relay_uri" >/dev/null 2>&1 || true
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
}
trap cleanup_relay EXIT
relay_url="$(aws s3 presign --endpoint-url "$R2_ENDPOINT" --expires-in 1800 "$relay_uri")"
relay_passphrase="$(printf '%s' "$RELAY_ENCRYPTION_KEY:$BUILD_ID:$R2_OBJECT_KEY" | sha256sum | cut -d ' ' -f 1)"
fi

if test -f "$SOURCE_DIR/scripts/prepare-production-deployment.sh"; then
  ssh "${ssh_args[@]}" "$target" \
    "DEPLOY_DIRECTORY='$DEPLOY_DIRECTORY' BUILD_ID='$BUILD_ID' bash -s" \
    < "$SOURCE_DIR/scripts/prepare-production-deployment.sh"
fi

tar -C "$SOURCE_DIR" -czf - docker-compose.yml tailscale-serve.json \
  | ssh "${ssh_args[@]}" "$target" \
      "set -eu; deploy_dir=\"\$HOME/$DEPLOY_DIRECTORY\"; install -d -m 0700 \"\$deploy_dir\"; tar -xzf - -C \"\$deploy_dir\"; test -f \"\$deploy_dir/.env\""

auth_key=""
if ! ssh "${ssh_args[@]}" "$target" \
  "DEPLOY_DIRECTORY='$DEPLOY_DIRECTORY' TAILSCALE_COMPOSE_NAME='$TAILSCALE_COMPOSE_NAME' bash -s" <<'REMOTE'
set -eu
deploy_dir="$HOME/$DEPLOY_DIRECTORY"
container_id="$(docker ps -aq \
  --filter "label=com.docker.compose.project.working_dir=$deploy_dir" \
  --filter "label=com.docker.compose.service=$TAILSCALE_COMPOSE_NAME" \
  | head -n 1)"
test -n "$container_id"
state_volume="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/tailscale"}}{{.Source}}{{end}}{{end}}' "$container_id")"
state_image="$(docker inspect --format '{{.Config.Image}}' "$container_id")"
test -n "$state_volume"
docker run --rm -v "$state_volume:/state:ro" "$state_image" test -s /state/tailscaled.state
REMOTE
then
  auth_key="$(node "$SOURCE_DIR/scripts/create-tailscale-auth-key.mjs")"
fi

payload="$RUNNER_TEMP/deploy-input"
remote_payload="/tmp/private-deploy-$BUILD_ID"
printf '%s\n%s\n%s\n%s\n%s\n' \
  "$REGISTRY_WRITE_TOKEN" "$REGISTRY_HOST" "$REGISTRY_USERNAME" "$IMAGE_REF" "$auth_key" > "$payload"
printf '%s\n%s\n%s\n' "$relay_url" "$relay_passphrase" "${R2_ARCHIVE_SHA256:-}" >> "$payload"
printf '%s\n' "$IMAGE_TRANSPORT" "${REGISTRY_SOURCE_IMAGE:-}" "${REGISTRY_SOURCE_DIGEST:-}" "${REGISTRY_SOURCE_USER:-}" "${REGISTRY_SOURCE_TOKEN:-}" "$BUILD_ID" >> "$payload"
chmod 600 "$payload"
scp "${ssh_args[@]}" "$payload" "$target:$remote_payload"

ssh "${ssh_args[@]}" "$target" \
  "DEPLOY_DIRECTORY='$DEPLOY_DIRECTORY' SERVICE_COMPOSE_NAME='$SERVICE_COMPOSE_NAME' SERVICE_IMAGE_VARIABLE='$SERVICE_IMAGE_VARIABLE' TAILSCALE_COMPOSE_NAME='$TAILSCALE_COMPOSE_NAME' REMOTE_PAYLOAD='$remote_payload' bash -s" <<'REMOTE'
set -eu
registry_host=""
relay_archive="/tmp/private-image-$RANDOM.enc"
relay_tar="/tmp/private-image-$RANDOM.tar"
trap 'rm -f "$REMOTE_PAYLOAD" "$relay_archive" "$relay_tar"; if [ -n "$registry_host" ]; then docker logout "$registry_host" >/dev/null 2>&1 || true; fi' EXIT
chmod 0600 "$REMOTE_PAYLOAD"
{
  IFS= read -r registry_token
  IFS= read -r registry_host
  IFS= read -r registry_user
  IFS= read -r image_ref
  IFS= read -r auth_key
  IFS= read -r relay_url
  IFS= read -r relay_passphrase
  IFS= read -r relay_sha256
  IFS= read -r image_transport
  IFS= read -r source_image
  IFS= read -r source_digest
  IFS= read -r source_user
  IFS= read -r source_token
  IFS= read -r build_id
} < "$REMOTE_PAYLOAD"

if test "$image_transport" = registry; then
  printf '%s' "$source_token" | docker login "$registry_host" --username "$source_user" --password-stdin >/dev/null
  source_ref="$source_image@$source_digest"
  timeout --signal=TERM --kill-after=30s 10m docker pull "$source_ref" >/dev/null
  test "$(docker image inspect "$source_ref" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')" = "$build_id"
  docker tag "$source_ref" "$image_ref"
else
curl --fail --silent --show-error --location --retry 3 --output "$relay_archive" "$relay_url"
printf '%s  %s\n' "$relay_sha256" "$relay_archive" | sha256sum -c -
export relay_passphrase
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -pass env:relay_passphrase -in "$relay_archive" \
  | zstd -d --quiet -o "$relay_tar"
unset relay_passphrase
docker load --input "$relay_tar" >/dev/null
fi
docker image inspect "$image_ref" >/dev/null

deploy_dir="$HOME/$DEPLOY_DIRECTORY"
envfile="$deploy_dir/.env"
cd "$deploy_dir"
printf '%s' "$registry_token" | docker login "$registry_host" --username "$registry_user" --password-stdin >/dev/null
docker push "$image_ref" >/dev/null
sed -i "/^${SERVICE_IMAGE_VARIABLE}=/d;/^TS_AUTHKEY=/d" "$envfile"
printf '\n%s=%s\n' "$SERVICE_IMAGE_VARIABLE" "$image_ref" >> "$envfile"
if [ -n "$auth_key" ]; then
  printf 'TS_AUTHKEY=%s\n' "$auth_key" >> "$envfile"
fi
chmod 0600 "$envfile"

docker compose up -d --pull never --remove-orphans
tailscale_id="$(docker compose ps -q "$TAILSCALE_COMPOSE_NAME")"
service_id="$(docker compose ps -q "$SERVICE_COMPOSE_NAME")"
test -n "$tailscale_id"
test -n "$service_id"
attempt=0
until docker exec "$tailscale_id" tailscale status --json | grep -q '"Online": true'; do
  attempt=$((attempt + 1))
  test "$attempt" -lt 30
  sleep 2
done
attempt=0
until docker exec "$service_id" node scripts/verify-deployment.mjs; do
  attempt=$((attempt + 1))
  test "$attempt" -lt 30
  sleep 5
done
sed -i '/^TS_AUTHKEY=/d' "$envfile"
chmod 0600 "$envfile"
REMOTE

echo "Service deployment verified"
