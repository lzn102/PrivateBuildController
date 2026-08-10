#!/usr/bin/env bash
set -euo pipefail

: "${BUILD_ID:?BUILD_ID is required}"
: "${GITEA_RELEASE_TOKEN:?GITEA_RELEASE_TOKEN is required}"
: "${REPOSITORY_API_URL:?REPOSITORY_API_URL is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
SOURCE_DIR="${SOURCE_DIR:-$RUNNER_TEMP/private-source}"

log="$RUNNER_TEMP/extension-build.log"
response="$RUNNER_TEMP/release-response.json"

if ! (
  cd "$SOURCE_DIR"
  npm ci --no-audit --no-fund --silent
  npm run package --silent
) >"$log" 2>&1; then
  echo "Extension validation or packaging failed" >&2
  exit 1
fi

version="$(node -p "require('$SOURCE_DIR/package.json').version")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]
tag="v$version"
mapfile -t assets < <(find "$SOURCE_DIR/packages" -maxdepth 1 -type f -name '*.zip' -print)
[[ "${#assets[@]}" = 1 ]]
asset="${assets[0]}"
asset_name="$(basename "$asset")"

status="$(curl --silent --show-error -o "$response" -w '%{http_code}' \
  -H "Authorization: token $GITEA_RELEASE_TOKEN" \
  "$REPOSITORY_API_URL/releases/tags/$tag")"

if [[ "$status" = 404 ]]; then
  payload="$(jq -cn --arg tag "$tag" --arg sha "$BUILD_ID" '{tag_name:$tag,target_commitish:$sha,name:$tag,body:"Automated private release.",draft:true,prerelease:false}')"
  status="$(curl --silent --show-error -o "$response" -w '%{http_code}' \
    -X POST \
    -H "Authorization: token $GITEA_RELEASE_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    "$REPOSITORY_API_URL/releases")"
  [[ "$status" = 201 ]]
else
  [[ "$status" = 200 ]]
fi

release_id="$(jq -er .id "$response")"
if [[ "$(jq -r .draft "$response")" != true ]]; then
  jq -e --arg name "$asset_name" '.assets[]? | select(.name == $name)' "$response" >/dev/null
  echo "Extension release already published"
  exit 0
fi

while IFS= read -r asset_id; do
  status="$(curl --silent --show-error -o /dev/null -w '%{http_code}' \
    -X DELETE \
    -H "Authorization: token $GITEA_RELEASE_TOKEN" \
    "$REPOSITORY_API_URL/releases/$release_id/assets/$asset_id")"
  [[ "$status" = 204 ]]
done < <(jq -r --arg name "$asset_name" '.assets[]? | select(.name == $name) | .id' "$response")

encoded_name="$(jq -nr --arg value "$asset_name" '$value | @uri')"
status="$(curl --silent --show-error -o "$response" -w '%{http_code}' \
  -X POST \
  -H "Authorization: token $GITEA_RELEASE_TOKEN" \
  -F "attachment=@$asset;type=application/zip" \
  "$REPOSITORY_API_URL/releases/$release_id/assets?name=$encoded_name")"
[[ "$status" = 201 ]]

echo "Extension release draft delivered"
