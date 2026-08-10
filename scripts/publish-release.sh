#!/usr/bin/env bash
set -euo pipefail

: "${GITEA_RELEASE_TOKEN:?GITEA_RELEASE_TOKEN is required}"
: "${REPOSITORY_API_URL:?REPOSITORY_API_URL is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
SOURCE_DIR="${SOURCE_DIR:-$RUNNER_TEMP/private-source}"

version="$(node -p "require('$SOURCE_DIR/package.json').version")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]
tag="v$version"
response="$RUNNER_TEMP/release-response.json"

status="$(curl --silent --show-error -o "$response" -w '%{http_code}' \
  -H "Authorization: token $GITEA_RELEASE_TOKEN" \
  "$REPOSITORY_API_URL/releases/tags/$tag")"
[[ "$status" = 200 ]]
jq -e '.assets[]? | select(.name | endswith(".zip"))' "$response" >/dev/null

if [[ "$(jq -r .draft "$response")" = true ]]; then
  release_id="$(jq -er .id "$response")"
  status="$(curl --silent --show-error -o "$response" -w '%{http_code}' \
    -X PATCH \
    -H "Authorization: token $GITEA_RELEASE_TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"draft":false}' \
    "$REPOSITORY_API_URL/releases/$release_id")"
  [[ "$status" = 200 ]]
fi

echo "Release published"
