#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$repo_root/.github/workflows/development-deploy.yml"

development_scripts=(
  "$repo_root/scripts/build-image.sh"
  "$repo_root/scripts/cleanup-relay.sh"
  "$repo_root/scripts/deploy-development.sh"
  "$repo_root/scripts/finalize-development.sh"
  "$repo_root/scripts/prepare-relay.sh"
  "$repo_root/scripts/recover-development.sh"
  "$repo_root/scripts/release-development-artifact.sh"
  "$repo_root/scripts/rollback-development-artifact.sh"
  "$repo_root/scripts/rollback-development.sh"
  "$repo_root/scripts/verify-development.sh"
)
for script in "${development_scripts[@]}"; do
  bash -n "$script"
done
if command -v ruby >/dev/null; then
  ruby -e 'require "yaml"; YAML.parse_file(ARGV.fetch(0))' "$workflow"
fi
if command -v actionlint >/dev/null; then
  actionlint "$workflow"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/runner" "$tmp/source"

cat > "$tmp/bin/timeout" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
while [[ "${1:-}" == --* ]]; do shift; done
shift
exec "$@"
MOCK
chmod +x "$tmp/bin/timeout"

cat > "$tmp/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_AWS_LOG"
case "$1 $2" in
  "s3 rm")
    : > "$MOCK_AWS_REMOVE_MARKER"
    ;;
  "s3api abort-multipart-upload")
    : > "$MOCK_AWS_ABORT_MARKER"
    ;;
  "s3api list-objects-v2")
    if test -f "$MOCK_AWS_REMOVE_MARKER"; then
      printf '{"Contents":[]}\n'
    else
      printf '{"Contents":[{"Key":"%s"}]}\n' "$R2_OBJECT_KEY"
    fi
    ;;
  "s3api list-multipart-uploads")
    if test -f "$MOCK_AWS_ABORT_MARKER"; then
      printf '{"Uploads":[]}\n'
    else
      printf '{"Uploads":[{"Key":"%s","UploadId":"upload-1"}]}\n' "$R2_OBJECT_KEY"
    fi
    ;;
  *)
    echo "Unexpected aws invocation" >&2
    exit 1
    ;;
esac
MOCK
chmod +x "$tmp/bin/aws"

cat > "$tmp/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
remote_command="${*: -1}"
bash -c "$remote_command"
MOCK

cat > "$tmp/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_DOCKER_LOG"
if test "$1" = compose; then
  case " $* " in
    *" config "*)
      test "${MOCK_CURRENT_CONFIG_INVALID:-false}" != true
      ;;
    *" up -d --pull never --remove-orphans "*)
      : > "$MOCK_RESTORED_MARKER"
      ;;
    *" ps -q application ") printf 'old-service\n' ;;
    *" ps -q network ") printf 'old-network\n' ;;
  esac
elif test "$1 $2" = "image inspect"; then
  exit 0
elif test "$1 $2" = "image tag"; then
  :
elif test "$1" = inspect; then
  case "$3" in
    *State.Health*) printf 'healthy\n' ;;
    *Image*) printf 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' ;;
    *Labels*) printf 'false\n' ;;
  esac
elif test "$1 $2" = "exec old-network"; then
  printf '{"Self":{"Online": true}}\n'
elif test "$1 $2" = "ps -aq"; then
  if ! test -f "$MOCK_REMOVED_MARKER"; then
    printf 'new-service\nnew-network\n'
  fi
elif test "$1 $2" = "rm -f"; then
  : > "$MOCK_REMOVED_MARKER"
fi
MOCK
chmod +x "$tmp/bin/ssh" "$tmp/bin/docker"

output_file="$tmp/output"
summary_file="$tmp/summary"
PATH="$tmp/bin:$PATH" GITHUB_OUTPUT="$output_file" RUNNER_TEMP="$tmp/runner" \
  GITHUB_RUN_ID=100 GITHUB_RUN_ATTEMPT=2 bash "$repo_root/scripts/prepare-relay.sh" >/dev/null
object_key="$(sed -n 's/^object_key=//p' "$output_file")"
[[ "$object_key" =~ ^relay/100-2-[0-9a-f]{32}\.bin$ ]]
test "$(cat "$tmp/runner/relay-object-key")" = "$object_key"

PATH="$tmp/bin:$PATH" \
  MOCK_AWS_ABORT_MARKER="$tmp/abort-called" \
  MOCK_AWS_LOG="$tmp/aws.log" \
  MOCK_AWS_REMOVE_MARKER="$tmp/remove-called" \
  R2_ACCESS_KEY_ID=test-access \
  R2_SECRET_ACCESS_KEY=test-secret \
  R2_BUCKET=example-bucket \
  R2_ENDPOINT=https://storage.invalid \
  R2_OBJECT_KEY="$object_key" \
  GITHUB_STEP_SUMMARY="$summary_file" \
  bash "$repo_root/scripts/cleanup-relay.sh" >/dev/null
test -f "$tmp/abort-called"
test -f "$tmp/remove-called"
grep -Fq 'abort-multipart-upload' "$tmp/aws.log"
grep -Fq 'Result: object and multipart uploads verified absent' "$summary_file"
if grep -Fq 'example-bucket' "$summary_file" || \
  grep -Fq 'storage.invalid' "$summary_file" || \
  grep -Fq "$object_key" "$summary_file"; then
  echo "Cleanup evidence contains relay location details" >&2
  exit 1
fi

validate_line="$(grep -n 'name: Validate source deployment contract' "$workflow" | cut -d: -f1)"
reserve_line="$(grep -n 'name: Reserve relay object' "$workflow" | cut -d: -f1)"
build_line="$(grep -n 'name: Build and relay encrypted service image' "$workflow" | cut -d: -f1)"
deploy_line="$(grep -n 'name: Deploy development service' "$workflow" | cut -d: -f1)"
recover_line="$(grep -n 'name: Recover interrupted development transaction' "$workflow" | cut -d: -f1)"
verify_line="$(grep -n 'name: Verify development service' "$workflow" | cut -d: -f1)"
e2e_line="$(grep -n 'name: Build, test, and publish development artifact' "$workflow" | cut -d: -f1)"
finalize_line="$(grep -n 'name: Finalize verified development deployment' "$workflow" | cut -d: -f1)"
rollback_line="$(grep -n 'name: Roll back failed development deployment' "$workflow" | cut -d: -f1)"
artifact_rollback_line="$(grep -n 'name: Remove artifact from failed development transaction' "$workflow" | cut -d: -f1)"
test "$validate_line" -lt "$reserve_line"
test "$reserve_line" -lt "$build_line"
test "$recover_line" -lt "$deploy_line"
test "$deploy_line" -lt "$verify_line"
test "$verify_line" -lt "$e2e_line"
test "$e2e_line" -lt "$finalize_line"
test "$finalize_line" -lt "$artifact_rollback_line"
test "$artifact_rollback_line" -lt "$rollback_line"
grep -Fq "if: always() && steps.finalize.outcome != 'success' && steps.deploy.outputs.transaction_id != ''" "$workflow"
grep -Fq "if: always() && steps.finalize.outcome != 'success'" "$workflow"
grep -Fq "if: success() && steps.deploy.outputs.transaction_id != ''" "$workflow"
grep -Fq 'id: finalize' "$workflow"
grep -Fq 'run: bash scripts/recover-development.sh' "$workflow"
grep -Fq 'ARTIFACT_E2E_COMMAND_B64: ${{ secrets.DEV_ARTIFACT_E2E_COMMAND_B64 }}' "$workflow"
grep -Fq 'run: bash scripts/rollback-development.sh' "$workflow"
grep -Fq 'run: bash scripts/rollback-development-artifact.sh' "$workflow"
grep -Fq 'if: always() && needs.build.outputs.object_key !=' "$workflow"
grep -Fq "if: always() && steps.image.outcome != 'success' && steps.relay.outputs.object_key != ''" "$workflow"
grep -Fq 'run: bash scripts/cleanup-relay.sh' "$workflow"
persist_line="$(grep -n 'relay-object-key' "$repo_root/scripts/build-image.sh" | head -1 | cut -d: -f1)"
upload_line="$(grep -n 'aws s3 cp' "$repo_root/scripts/build-image.sh" | cut -d: -f1)"
test "$persist_line" -lt "$upload_line"

ready_line="$(grep -n 'touch "$state_dir/ready"' "$repo_root/scripts/deploy-development.sh" | cut -d: -f1)"
active_line="$(grep -n 'ln "$state_dir/active-pointer" "$active_pointer"' "$repo_root/scripts/deploy-development.sh" | cut -d: -f1)"
started_line="$(grep -n 'touch "$state_dir/deployment-started"' "$repo_root/scripts/deploy-development.sh" | cut -d: -f1)"
live_directory_line="$(grep -n 'install -d -m 0700 "$deploy_dir"' "$repo_root/scripts/deploy-development.sh" | cut -d: -f1)"
test "$ready_line" -lt "$active_line"
test "$active_line" -lt "$started_line"
test "$started_line" -lt "$live_directory_line"
grep -Fq 'deploy_directory="$(cat "$state_dir/deploy-directory")"' "$repo_root/scripts/rollback-development.sh"
grep -Fq 'test "$(cat "$active_pointer")" = "$TRANSACTION_ID"' "$repo_root/scripts/finalize-development.sh"
grep -Fq 'test "$(cat "$active_pointer")" = "$TRANSACTION_ID"' "$repo_root/scripts/verify-development.sh"

target_home="$tmp/target-home"
deploy_dir="$target_home/services/development"
transaction_id="restore-existing"
state_dir="$target_home/.development-deploy-transactions/$transaction_id"
mkdir -p "$deploy_dir" "$state_dir/files"
printf 'broken-compose\n' > "$deploy_dir/compose.yml"
printf 'NEW_ENV=value\n' > "$deploy_dir/.env"
printf 'old-compose\n' > "$state_dir/files/compose.yml"
printf 'OLD_ENV=value\n' > "$state_dir/env"
printf 'compose.yml\n' > "$state_dir/files-list"
printf 'services/development' > "$state_dir/deploy-directory"
printf 'compose.yml' > "$state_dir/compose-file"
printf 'development' > "$state_dir/compose-project"
printf 'application' > "$state_dir/service-name"
printf 'network' > "$state_dir/network-service"
printf 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$state_dir/service-image-id"
printf 'registry.invalid/example/service:old\n' > "$state_dir/service-image-ref"
touch "$state_dir/ready" "$state_dir/deployment-started" "$state_dir/had-env" "$state_dir/had-service"
printf '%s\n' "$transaction_id" > "$target_home/.development-deploy-transactions/active"

rollback_summary="$tmp/rollback-summary"
PATH="$tmp/bin:$PATH" \
  HOME="$target_home" \
  MOCK_CURRENT_CONFIG_INVALID=true \
  MOCK_DOCKER_LOG="$tmp/docker.log" \
  MOCK_REMOVED_MARKER="$tmp/containers-removed" \
  MOCK_RESTORED_MARKER="$tmp/service-restored" \
  DEPLOY_COMPOSE_FILE=compose.yml \
  DEPLOY_COMPOSE_PROJECT=development \
  DEPLOY_DIRECTORY=services/development \
  DEPLOY_NETWORK_SERVICE=network \
  DEPLOY_SERVICE_NAME=application \
  DEPLOY_TRANSACTION_ID="$transaction_id" \
  RUNNER_TEMP="$tmp/runner" \
  TARGET_SSH_HOST=host.invalid \
  TARGET_SSH_KNOWN_HOSTS='host.invalid ssh-ed25519 test' \
  TARGET_SSH_PRIVATE_KEY='test-key' \
  TARGET_SSH_USER=runner \
  GITHUB_STEP_SUMMARY="$rollback_summary" \
  bash "$repo_root/scripts/rollback-development.sh" >/dev/null
test "$(cat "$deploy_dir/compose.yml")" = old-compose
test "$(cat "$deploy_dir/.env")" = OLD_ENV=value
test -f "$tmp/containers-removed"
test -f "$tmp/service-restored"
test ! -e "$state_dir"
grep -Fq 'image tag sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa registry.invalid/example/service:old' "$tmp/docker.log"
grep -Fq 'up -d --pull never --remove-orphans' "$tmp/docker.log"
grep -Fq 'Post-rollback health: passed' "$rollback_summary"

rm -f "$tmp/containers-removed" "$tmp/service-restored"
transaction_id="restore-absent"
state_dir="$target_home/.development-deploy-transactions/$transaction_id"
mkdir -p "$state_dir/files"
printf 'compose.yml\n' > "$state_dir/files-list"
printf 'services/development' > "$state_dir/deploy-directory"
printf 'compose.yml' > "$state_dir/compose-file"
printf 'development' > "$state_dir/compose-project"
printf 'application' > "$state_dir/service-name"
printf 'network' > "$state_dir/network-service"
touch "$state_dir/ready" "$state_dir/deployment-started"
printf '%s\n' "$transaction_id" > "$target_home/.development-deploy-transactions/active"
printf 'new-compose\n' > "$deploy_dir/compose.yml"
printf 'NEW_ENV=value\n' > "$deploy_dir/.env"
PATH="$tmp/bin:$PATH" \
  HOME="$target_home" \
  MOCK_CURRENT_CONFIG_INVALID=true \
  MOCK_DOCKER_LOG="$tmp/docker.log" \
  MOCK_REMOVED_MARKER="$tmp/containers-removed" \
  MOCK_RESTORED_MARKER="$tmp/service-restored" \
  DEPLOY_COMPOSE_FILE=compose.yml \
  DEPLOY_COMPOSE_PROJECT=development \
  DEPLOY_DIRECTORY=services/development \
  DEPLOY_NETWORK_SERVICE=network \
  DEPLOY_SERVICE_NAME=application \
  DEPLOY_TRANSACTION_ID="$transaction_id" \
  RUNNER_TEMP="$tmp/runner" \
  TARGET_SSH_HOST=host.invalid \
  TARGET_SSH_KNOWN_HOSTS='host.invalid ssh-ed25519 test' \
  TARGET_SSH_PRIVATE_KEY='test-key' \
  TARGET_SSH_USER=runner \
  bash "$repo_root/scripts/rollback-development.sh" >/dev/null
test ! -e "$deploy_dir/compose.yml"
test ! -e "$deploy_dir/.env"
test ! -e "$state_dir"
test ! -e "$tmp/service-restored"

transaction_id="interrupted-absent"
state_dir="$target_home/.development-deploy-transactions/$transaction_id"
mkdir -p "$state_dir/files"
printf 'compose.yml\n' > "$state_dir/files-list"
printf 'services/development' > "$state_dir/deploy-directory"
printf 'compose.yml' > "$state_dir/compose-file"
printf 'development' > "$state_dir/compose-project"
printf 'application' > "$state_dir/service-name"
printf 'network' > "$state_dir/network-service"
touch "$state_dir/ready" "$state_dir/deployment-started"
printf '%s\n' "$transaction_id" > "$target_home/.development-deploy-transactions/active"
PATH="$tmp/bin:$PATH" \
  HOME="$target_home" \
  MOCK_DOCKER_LOG="$tmp/docker.log" \
  MOCK_REMOVED_MARKER="$tmp/containers-removed" \
  MOCK_RESTORED_MARKER="$tmp/service-restored" \
  RUNNER_TEMP="$tmp/runner" \
  TARGET_SSH_HOST=host.invalid \
  TARGET_SSH_KNOWN_HOSTS='host.invalid ssh-ed25519 test' \
  TARGET_SSH_PRIVATE_KEY='test-key' \
  TARGET_SSH_USER=runner \
  bash "$repo_root/scripts/recover-development.sh" >/dev/null
test ! -e "$state_dir"
test ! -e "$target_home/.development-deploy-transactions/active"

transaction_id="finalize-matching"
state_dir="$target_home/.development-deploy-transactions/$transaction_id"
mkdir -p "$state_dir"
touch "$state_dir/ready" "$state_dir/deployment-started"
printf '%s\n' "$transaction_id" > "$target_home/.development-deploy-transactions/active"
PATH="$tmp/bin:$PATH" \
  HOME="$target_home" \
  DEPLOY_TRANSACTION_ID="$transaction_id" \
  RUNNER_TEMP="$tmp/runner" \
  TARGET_SSH_HOST=host.invalid \
  TARGET_SSH_KNOWN_HOSTS='host.invalid ssh-ed25519 test' \
  TARGET_SSH_PRIVATE_KEY='test-key' \
  TARGET_SSH_USER=runner \
  bash "$repo_root/scripts/finalize-development.sh" >/dev/null
test ! -e "$state_dir"
test ! -e "$target_home/.development-deploy-transactions/active"

transaction_id="finalize-mismatch"
state_dir="$target_home/.development-deploy-transactions/$transaction_id"
mkdir -p "$state_dir"
touch "$state_dir/ready" "$state_dir/deployment-started"
printf '%s\n' 'different-transaction' > "$target_home/.development-deploy-transactions/active"
if PATH="$tmp/bin:$PATH" \
  HOME="$target_home" \
  DEPLOY_TRANSACTION_ID="$transaction_id" \
  RUNNER_TEMP="$tmp/runner" \
  TARGET_SSH_HOST=host.invalid \
  TARGET_SSH_KNOWN_HOSTS='host.invalid ssh-ed25519 test' \
  TARGET_SSH_PRIVATE_KEY='test-key' \
  TARGET_SSH_USER=runner \
  bash "$repo_root/scripts/finalize-development.sh" >/dev/null 2>&1; then
  echo "Finalization accepted a mismatched active transaction" >&2
  exit 1
fi
test -e "$state_dir"
test "$(cat "$target_home/.development-deploy-transactions/active")" = different-transaction
rm -rf "$state_dir"
rm -f "$target_home/.development-deploy-transactions/active"

build_command="$(printf '%s' 'printf artifact > "$DEVELOPMENT_ARTIFACT_PATH"' | base64 | tr -d '\n')"
e2e_command="$(printf '%s' 'exit 23' | base64 | tr -d '\n')"
cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
: > "$MOCK_CURL_MARKER"
exit 1
MOCK
chmod +x "$tmp/bin/curl"
if PATH="$tmp/bin:$PATH" \
  MOCK_CURL_MARKER="$tmp/curl-called" \
  ACCEPTANCE_ADMIN_TOKEN=test-admin \
  ACCEPTANCE_API_TOKEN=test-api \
  ACCEPTANCE_ENDPOINTS=https://service.invalid \
  ARTIFACT_BUILD_COMMAND_B64="$build_command" \
  ARTIFACT_E2E_COMMAND_B64="$e2e_command" \
  ARTIFACT_EXTENSION=zip \
  BUILD_ID=0123456789abcdef0123456789abcdef01234567 \
  REPOSITORY_API_TOKEN=test-repository-token \
  REPOSITORY_API_URL=https://repository.invalid/api/v1/repos/example/project \
  RUNNER_TEMP="$tmp/runner" \
  SOURCE_DIR="$tmp/source" \
  bash "$repo_root/scripts/release-development-artifact.sh" 2>"$tmp/e2e-error"; then
  echo "Failing E2E command unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq 'Development E2E failed' "$tmp/e2e-error"
test ! -e "$tmp/curl-called"

cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
output=/dev/null
method=GET
previous=""
for argument in "$@"; do
  if test "$previous" = -o; then output="$argument"; fi
  if test "$previous" = -X; then method="$argument"; fi
  previous="$argument"
done
url="${*: -1}"
printf '%s %s\n' "$method" "$url" >> "$MOCK_CURL_LOG"
case "$method $url" in
  "GET "*"/releases/tags/ci-dev-0123456789abcdef0123456789abcdef01234567")
    if test "${MOCK_RELEASE_MATCH:-true}" = true; then
      printf '{"id":12,"target_commitish":"0123456789abcdef0123456789abcdef01234567","body":"Action-built development artifact.\\n\\nTransaction: development-publication-test-1"}' > "$output"
    else
      printf '{"id":99,"target_commitish":"ffffffffffffffffffffffffffffffffffffffff","body":"unrelated"}' > "$output"
    fi
    printf 200
    ;;
  "DELETE "*) printf 204 ;;
  *) echo "Unexpected repository request" >&2; exit 1 ;;
esac
MOCK
chmod +x "$tmp/bin/curl"

state="$tmp/runner/development-artifact-state.json"
artifact_state_base='"assetName":"development-artifact-0123456789abcdef0123456789abcdef01234567.zip","buildId":"0123456789abcdef0123456789abcdef01234567","tag":"ci-dev-0123456789abcdef0123456789abcdef01234567","transactionMarker":"development-publication-test-1"'
rm -f "$tmp/artifact-rollback.log"
printf '%s' "{\"assetId\":null,$artifact_state_base,\"assetPending\":false,\"releaseCreated\":true,\"releasePending\":false,\"releaseId\":\"10\",\"tagCreated\":true}" > "$state"
PATH="$tmp/bin:$PATH" \
  MOCK_CURL_LOG="$tmp/artifact-rollback.log" \
  REPOSITORY_API_TOKEN=test-repository-token \
  REPOSITORY_API_URL=https://repository.invalid/api/v1/repos/example/project \
  RUNNER_TEMP="$tmp/runner" \
  bash "$repo_root/scripts/rollback-development-artifact.sh" >/dev/null
grep -Fq 'DELETE https://repository.invalid/api/v1/repos/example/project/releases/10' "$tmp/artifact-rollback.log"
grep -Fq 'DELETE https://repository.invalid/api/v1/repos/example/project/tags/ci-dev-' "$tmp/artifact-rollback.log"
if grep -Fq '/git/refs/' "$tmp/artifact-rollback.log"; then
  echo "Rollback used an unsupported Git reference deletion endpoint" >&2
  exit 1
fi
test ! -e "$state"

rm -f "$tmp/artifact-rollback.log"
printf '%s' "{\"assetId\":null,$artifact_state_base,\"assetPending\":false,\"releaseCreated\":true,\"releasePending\":false,\"releaseId\":\"10\",\"tagCreated\":false}" > "$state"
PATH="$tmp/bin:$PATH" \
  MOCK_CURL_LOG="$tmp/artifact-rollback.log" \
  REPOSITORY_API_TOKEN=test-repository-token \
  REPOSITORY_API_URL=https://repository.invalid/api/v1/repos/example/project \
  RUNNER_TEMP="$tmp/runner" \
  bash "$repo_root/scripts/rollback-development-artifact.sh" >/dev/null
grep -Fq '/releases/10' "$tmp/artifact-rollback.log"
if grep -Fq '/tags/' "$tmp/artifact-rollback.log"; then
  echo "Rollback deleted a pre-existing tag" >&2
  exit 1
fi
test ! -e "$state"

rm -f "$tmp/artifact-rollback.log"
printf '%s' "{\"assetId\":null,$artifact_state_base,\"assetPending\":true,\"releaseCreated\":true,\"releasePending\":false,\"releaseId\":\"11\",\"tagCreated\":true}" > "$state"
PATH="$tmp/bin:$PATH" \
  MOCK_CURL_LOG="$tmp/artifact-rollback.log" \
  REPOSITORY_API_TOKEN=test-repository-token \
  REPOSITORY_API_URL=https://repository.invalid/api/v1/repos/example/project \
  RUNNER_TEMP="$tmp/runner" \
  bash "$repo_root/scripts/rollback-development-artifact.sh" >/dev/null
test ! -s "$tmp/artifact-rollback.log"
test ! -e "$state"

rm -f "$tmp/artifact-rollback.log"
printf '%s' "{\"assetId\":\"44\",$artifact_state_base,\"assetPending\":false,\"releaseCreated\":false,\"releasePending\":false,\"releaseId\":\"11\",\"tagCreated\":false}" > "$state"
PATH="$tmp/bin:$PATH" \
  MOCK_CURL_LOG="$tmp/artifact-rollback.log" \
  REPOSITORY_API_TOKEN=test-repository-token \
  REPOSITORY_API_URL=https://repository.invalid/api/v1/repos/example/project \
  RUNNER_TEMP="$tmp/runner" \
  bash "$repo_root/scripts/rollback-development-artifact.sh" >/dev/null
grep -Fq '/releases/11/assets/44' "$tmp/artifact-rollback.log"

rm -f "$tmp/artifact-rollback.log"
printf '%s' "{\"assetId\":null,$artifact_state_base,\"assetPending\":false,\"releaseCreated\":false,\"releasePending\":true,\"releaseId\":null,\"tagCreated\":true}" > "$state"
PATH="$tmp/bin:$PATH" \
  MOCK_CURL_LOG="$tmp/artifact-rollback.log" \
  REPOSITORY_API_TOKEN=test-repository-token \
  REPOSITORY_API_URL=https://repository.invalid/api/v1/repos/example/project \
  RUNNER_TEMP="$tmp/runner" \
  bash "$repo_root/scripts/rollback-development-artifact.sh" >/dev/null
grep -Fq '/releases/tags/ci-dev-' "$tmp/artifact-rollback.log"
grep -Fq '/releases/12' "$tmp/artifact-rollback.log"
grep -Fq '/tags/ci-dev-' "$tmp/artifact-rollback.log"

rm -f "$tmp/artifact-rollback.log"
printf '%s' "{\"assetId\":null,$artifact_state_base,\"assetPending\":false,\"releaseCreated\":false,\"releasePending\":true,\"releaseId\":null,\"tagCreated\":true}" > "$state"
PATH="$tmp/bin:$PATH" \
  MOCK_CURL_LOG="$tmp/artifact-rollback.log" \
  MOCK_RELEASE_MATCH=false \
  REPOSITORY_API_TOKEN=test-repository-token \
  REPOSITORY_API_URL=https://repository.invalid/api/v1/repos/example/project \
  RUNNER_TEMP="$tmp/runner" \
  bash "$repo_root/scripts/rollback-development-artifact.sh" >/dev/null
if grep -Fq 'DELETE ' "$tmp/artifact-rollback.log"; then
  echo "Rollback deleted a release without matching SHA and transaction marker" >&2
  exit 1
fi

grep -Fq 'request DELETE "/tags/$encoded_tag"' "$repo_root/scripts/rollback-development-artifact.sh"
if grep -Eq 'request DELETE .*/git/refs/' "$repo_root/scripts/rollback-development-artifact.sh"; then
  echo "Rollback contains an unsupported Git reference deletion endpoint" >&2
  exit 1
fi
release_pending_line="$(grep -n 'write_state "" true false' "$repo_root/scripts/release-development-artifact.sh" | cut -d: -f1)"
release_post_line="$(grep -n 'request POST "/releases"' "$repo_root/scripts/release-development-artifact.sh" | cut -d: -f1)"
test "$release_pending_line" -lt "$release_post_line"
grep -Fq 'Development artifact is immutable and its checksum does not match' "$repo_root/scripts/release-development-artifact.sh"
if grep -Fq 'request DELETE' "$repo_root/scripts/release-development-artifact.sh"; then
  echo "Artifact publisher contains a destructive replacement path" >&2
  exit 1
fi

public_files=(
  "$repo_root/.github/workflows/development-deploy.yml"
  "$repo_root/.github/workflows/ephemeral-build.yml"
)
while IFS= read -r public_file; do
  public_files+=("$public_file")
done < <(find "$repo_root/scripts" "$repo_root/docs" -type f -print)

if test -n "${PRIVATE_MARKERS_B64:-}"; then
  private_markers="$(printf '%s' "$PRIVATE_MARKERS_B64" | base64 -d)"
  while IFS= read -r marker; do
    test -z "$marker" && continue
    if rg -F -i "$marker" "${public_files[@]}"; then
      echo "Development implementation contains a private marker" >&2
      exit 1
    fi
  done <<< "$private_markers"
fi
if rg -n -i 'tskey-|[[:alnum:]_.+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}|https?://[[:alnum:]]|(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)' "${public_files[@]}"; then
  echo "Development implementation contains credential, email, endpoint, or IP literals" >&2
  exit 1
fi
if rg -n -P '\b(?!TARGET_)[A-Z][A-Z0-9]*_SSH_(?:HOST|KNOWN_HOSTS|PRIVATE_KEY|USER)\b' \
    "$repo_root/.github/workflows" "$repo_root/scripts"; then
  echo "Controller still exposes a target-specific SSH variable name" >&2
  exit 1
fi
grep -Fq 'TARGET_SSH_HOST: ${{ secrets.TARGET_SSH_HOST }}' "$repo_root/.github/workflows/ephemeral-build.yml"
grep -Fq ': "${TARGET_SSH_HOST:?TARGET_SSH_HOST is required}"' "$repo_root/scripts/deploy-service.sh"

echo "Development deployment safety tests passed"
