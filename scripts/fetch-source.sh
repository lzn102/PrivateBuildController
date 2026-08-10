#!/usr/bin/env bash
set -euo pipefail

: "${BUILD_ID:?BUILD_ID is required}"
: "${GITEA_SOURCE_TOKEN:?GITEA_SOURCE_TOKEN is required}"
: "${SOURCE_DIR:?SOURCE_DIR is required}"
: "${SOURCE_REPO_URL:?SOURCE_REPO_URL is required}"

[[ "$BUILD_ID" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid build identifier" >&2; exit 2; }
[[ "$SOURCE_REPO_URL" == https://* ]] || { echo "Source endpoint must use HTTPS" >&2; exit 2; }

askpass_dir="$(mktemp -d "$RUNNER_TEMP/source-auth.XXXXXX")"
askpass="$askpass_dir/askpass.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case "$1" in' \
  '  *Username*) printf "%s\\n" "oauth2" ;;' \
  '  *Password*) printf "%s\\n" "$GITEA_SOURCE_TOKEN" ;;' \
  '  *) exit 1 ;;' \
  'esac' > "$askpass"
chmod 700 "$askpass"

git init --quiet "$SOURCE_DIR"
git -C "$SOURCE_DIR" remote add source "$SOURCE_REPO_URL"
GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \
  git -C "$SOURCE_DIR" fetch --quiet --depth=1 source "$BUILD_ID"
git -C "$SOURCE_DIR" checkout --quiet --detach FETCH_HEAD
git -C "$SOURCE_DIR" remote remove source
rm -rf "$askpass_dir"

test "$(git -C "$SOURCE_DIR" rev-parse HEAD)" = "$BUILD_ID"
echo "Private source prepared"
