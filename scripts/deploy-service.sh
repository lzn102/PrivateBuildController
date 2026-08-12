#!/usr/bin/env bash
set -euo pipefail

: "${BUILD_ID:?BUILD_ID is required}"
: "${DEPLOY_DIRECTORY:?DEPLOY_DIRECTORY is required}"
: "${IMAGE_REF:?IMAGE_REF is required}"
: "${N100_SSH_HOST:?N100_SSH_HOST is required}"
: "${N100_SSH_KNOWN_HOSTS:?N100_SSH_KNOWN_HOSTS is required}"
: "${N100_SSH_PRIVATE_KEY:?N100_SSH_PRIVATE_KEY is required}"
: "${N100_SSH_USER:?N100_SSH_USER is required}"
: "${REGISTRY_HOST:?REGISTRY_HOST is required}"
: "${REGISTRY_WRITE_TOKEN:?REGISTRY_WRITE_TOKEN is required}"
: "${REGISTRY_USERNAME:?REGISTRY_USERNAME is required}"
: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is required}"
: "${R2_ARCHIVE_SHA256:?R2_ARCHIVE_SHA256 is required}"
: "${R2_BUCKET:?R2_BUCKET is required}"
: "${R2_ENDPOINT:?R2_ENDPOINT is required}"
: "${R2_OBJECT_KEY:?R2_OBJECT_KEY is required}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${SERVICE_COMPOSE_NAME:?SERVICE_COMPOSE_NAME is required}"
: "${SERVICE_IMAGE_VARIABLE:?SERVICE_IMAGE_VARIABLE is required}"
: "${TAILSCALE_COMPOSE_NAME:?TAILSCALE_COMPOSE_NAME is required}"
SOURCE_DIR="${SOURCE_DIR:-$RUNNER_TEMP/private-source}"

[[ "$BUILD_ID" =~ ^[0-9a-f]{40}$ ]]
[[ "$DEPLOY_DIRECTORY" =~ ^[A-Za-z0-9._/-]+$ ]]
[[ "$DEPLOY_DIRECTORY" != /* && "$DEPLOY_DIRECTORY" != *..* ]]
[[ "$IMAGE_REF" =~ ^[A-Za-z0-9._:/-]+$ ]]
[[ "$N100_SSH_HOST" =~ ^[A-Za-z0-9.:-]+$ ]]
[[ "$N100_SSH_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]
[[ "$REGISTRY_HOST" =~ ^[A-Za-z0-9.:-]+$ ]]
[[ "$REGISTRY_USERNAME" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]
[[ "$R2_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]]
[[ "$R2_BUCKET" =~ ^[A-Za-z0-9._-]+$ ]]
[[ "$R2_ENDPOINT" == https://* ]]
[[ "$R2_OBJECT_KEY" =~ ^relay/[A-Za-z0-9._-]+$ ]]
[[ "$SERVICE_COMPOSE_NAME" =~ ^[A-Za-z0-9._-]+$ ]]
[[ "$SERVICE_IMAGE_VARIABLE" =~ ^[A-Z][A-Z0-9_]*$ ]]
[[ "$TAILSCALE_COMPOSE_NAME" =~ ^[A-Za-z0-9._-]+$ ]]

key_file="$RUNNER_TEMP/deploy-key"
known_hosts="$RUNNER_TEMP/deploy-known-hosts"
printf '%s\n' "$N100_SSH_PRIVATE_KEY" > "$key_file"
printf '%s\n' "$N100_SSH_KNOWN_HOSTS" > "$known_hosts"
chmod 600 "$key_file" "$known_hosts"

ssh_args=(-i "$key_file" -o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts")
target="$N100_SSH_USER@$N100_SSH_HOST"
ssh "${ssh_args[@]}" "$target" true

for command_name in aws openssl sha256sum; do
  command -v "$command_name" >/dev/null || {
    echo "Required command is unavailable: $command_name" >&2
    exit 1
  }
done
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
relay_passphrase="$(printf '%s' "$R2_SECRET_ACCESS_KEY:$BUILD_ID:$R2_OBJECT_KEY" | sha256sum | cut -d ' ' -f 1)"

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
state_volume="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/tailscale"}}{{.Name}}{{end}}{{end}}' "$container_id")"
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
printf '%s\n%s\n%s\n' "$relay_url" "$relay_passphrase" "$R2_ARCHIVE_SHA256" >> "$payload"
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
} < "$REMOTE_PAYLOAD"

curl --fail --silent --show-error --location --retry 3 --output "$relay_archive" "$relay_url"
printf '%s  %s\n' "$relay_sha256" "$relay_archive" | sha256sum -c -
export relay_passphrase
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -pass env:relay_passphrase -in "$relay_archive" \
  | zstd -d --quiet -o "$relay_tar"
unset relay_passphrase
docker load --input "$relay_tar" >/dev/null
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
docker exec "$service_id" node scripts/verify-deployment.mjs
sed -i '/^TS_AUTHKEY=/d' "$envfile"
chmod 0600 "$envfile"
REMOTE

echo "Service deployment verified"
