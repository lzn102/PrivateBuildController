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
: "${REGISTRY_READ_TOKEN:?REGISTRY_READ_TOKEN is required}"
: "${REGISTRY_USERNAME:?REGISTRY_USERNAME is required}"
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

tar -C "$SOURCE_DIR" -czf - docker-compose.yml tailscale-serve.json \
  | ssh "${ssh_args[@]}" "$target" \
      "set -eu; deploy_dir=\"\$HOME/$DEPLOY_DIRECTORY\"; install -d -m 0700 \"\$deploy_dir\"; tar -xzf - -C \"\$deploy_dir\"; test -f \"\$deploy_dir/.env\""

auth_key=""
if ! ssh "${ssh_args[@]}" "$target" \
  "DEPLOY_DIRECTORY='$DEPLOY_DIRECTORY' TAILSCALE_COMPOSE_NAME='$TAILSCALE_COMPOSE_NAME' bash -s" <<'REMOTE'
set -eu
cd "$HOME/$DEPLOY_DIRECTORY"
container_id="$(docker compose ps -aq "$TAILSCALE_COMPOSE_NAME" 2>/dev/null || true)"
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
  "$REGISTRY_READ_TOKEN" "$REGISTRY_HOST" "$REGISTRY_USERNAME" "$IMAGE_REF" "$auth_key" > "$payload"
chmod 600 "$payload"
scp "${ssh_args[@]}" "$payload" "$target:$remote_payload"

ssh "${ssh_args[@]}" "$target" \
  "DEPLOY_DIRECTORY='$DEPLOY_DIRECTORY' SERVICE_COMPOSE_NAME='$SERVICE_COMPOSE_NAME' SERVICE_IMAGE_VARIABLE='$SERVICE_IMAGE_VARIABLE' TAILSCALE_COMPOSE_NAME='$TAILSCALE_COMPOSE_NAME' REMOTE_PAYLOAD='$remote_payload' bash -s" <<'REMOTE'
set -eu
registry_host=""
trap 'rm -f "$REMOTE_PAYLOAD"; if [ -n "$registry_host" ]; then docker logout "$registry_host" >/dev/null 2>&1 || true; fi' EXIT
chmod 0600 "$REMOTE_PAYLOAD"
{
  IFS= read -r registry_token
  IFS= read -r registry_host
  IFS= read -r registry_user
  IFS= read -r image_ref
  IFS= read -r auth_key
} < "$REMOTE_PAYLOAD"

deploy_dir="$HOME/$DEPLOY_DIRECTORY"
envfile="$deploy_dir/.env"
cd "$deploy_dir"
printf '%s' "$registry_token" | docker login "$registry_host" --username "$registry_user" --password-stdin >/dev/null
sed -i "/^${SERVICE_IMAGE_VARIABLE}=/d;/^TS_AUTHKEY=/d" "$envfile"
printf '\n%s=%s\n' "$SERVICE_IMAGE_VARIABLE" "$image_ref" >> "$envfile"
if [ -n "$auth_key" ]; then
  printf 'TS_AUTHKEY=%s\n' "$auth_key" >> "$envfile"
fi
chmod 0600 "$envfile"

docker compose pull "$SERVICE_COMPOSE_NAME"
docker compose up -d --remove-orphans
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
