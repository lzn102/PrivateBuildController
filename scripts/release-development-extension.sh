#!/usr/bin/env bash
set -euo pipefail

: "${BUILD_ID:?BUILD_ID is required}"
: "${GITEA_RELEASE_TOKEN:?GITEA_RELEASE_TOKEN is required}"
: "${REPOSITORY_API_URL:?REPOSITORY_API_URL is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
SOURCE_DIR="${SOURCE_DIR:-$RUNNER_TEMP/private-source}"

[[ "$BUILD_ID" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid build identifier" >&2; exit 2; }
[[ "$REPOSITORY_API_URL" == https://*/api/v1/repos/*/* ]] || {
  echo "Repository API endpoint is invalid" >&2
  exit 2
}

log="$RUNNER_TEMP/extension-build.log"
response="$RUNNER_TEMP/release-response.json"
if ! (
  cd "$SOURCE_DIR"
  export PASSKEYEXT_BUILD_ID="$BUILD_ID"
  npm ci --no-audit --no-fund --silent
  npm run package --silent
) >"$log" 2>&1; then
  echo "Development extension validation or packaging failed" >&2
  exit 1
fi

mapfile -t assets < <(find "$SOURCE_DIR/packages" -maxdepth 1 -type f -name '*.zip' -print)
[[ "${#assets[@]}" = 1 ]] || { echo "Exactly one extension archive is required" >&2; exit 1; }
asset="${assets[0]}"
asset_name="development-extension-$BUILD_ID.zip"
tag="ci-dev-$BUILD_ID"
unzip -p "$asset" manifest.json | jq -e --arg build_id "$BUILD_ID" \
  '.version_name == (.version + " (" + $build_id + ")")' >/dev/null || {
    echo "Development extension build metadata is missing" >&2
    exit 1
  }
bundled_config="$RUNNER_TEMP/development-bundled-config.mjs"
unzip -p "$asset" src/shared/bundled-config.js > "$bundled_config"
BUNDLED_CONFIG_PATH="$bundled_config" node --input-type=module <<'NODE'
import { pathToFileURL } from "node:url";

const { bundledDefaults } = await import(pathToFileURL(process.env.BUNDLED_CONFIG_PATH));
const expectedUrls = String(process.env.BUNDLED_PROXY_URLS || "")
  .split(/[\r\n,]+/u)
  .map((value) => value.trim().replace(/\/+$/u, ""))
  .filter(Boolean);
const valid = bundledDefaults.apiToken === process.env.BUNDLED_API_TOKEN
  && bundledDefaults.defaultCollectionId === ""
  && bundledDefaults.defaultOrganizationId === ""
  && JSON.stringify(bundledDefaults.proxyUrls) === JSON.stringify(expectedUrls);
if (!valid) throw new Error("Development extension bundled configuration does not match its isolated environment");
NODE

extension_directory="$RUNNER_TEMP/development-extension"
rm -rf "$extension_directory"
mkdir -p "$extension_directory"
unzip -q "$asset" -d "$extension_directory"
proxy_url="$(printf '%s' "$BUNDLED_PROXY_URLS" | tr ',\r' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sed -e '/^$/d' | head -1)"
[[ "$proxy_url" == https://* ]] || { echo "Development proxy URL is invalid" >&2; exit 1; }
(
  cd "$SOURCE_DIR"
  timeout 10m npx --no-install playwright install --with-deps chromium
  PASSKEYEXT_BUILD_ID="$BUILD_ID" \
    PASSKEYEXT_E2E_API_TOKEN="$BUNDLED_API_TOKEN" \
    PASSKEYEXT_E2E_EXTENSION_DIRECTORY="$extension_directory" \
    PASSKEYEXT_E2E_PROXY_URL="$proxy_url" \
    PASSKEYEXT_E2E_SITE_URL="${proxy_url%/}/__passkeyext-test/" \
    timeout 8m node scripts/development-browser-e2e.mjs
)

request() {
  local method="$1" path="$2" output="$3"
  shift 3
  curl --silent --show-error -o "$output" -w '%{http_code}' \
    -X "$method" \
    -H "Authorization: token $GITEA_RELEASE_TOKEN" \
    "$@" \
    "$REPOSITORY_API_URL$path"
}

status="$(request GET "/releases/tags/$tag" "$response")"
if [[ "$status" = 404 ]]; then
  payload="$(jq -cn --arg tag "$tag" --arg sha "$BUILD_ID" \
    '{tag_name:$tag,target_commitish:$sha,name:("Development " + $sha),body:"Action-built development extension artifact.",draft:false,prerelease:true}')"
  status="$(request POST "/releases" "$response" -H 'Content-Type: application/json' -d "$payload")"
  [[ "$status" = 201 ]] || { echo "Development release creation failed ($status)" >&2; exit 1; }
else
  [[ "$status" = 200 ]] || { echo "Development release lookup failed ($status)" >&2; exit 1; }
fi

release_id="$(jq -er .id "$response")"
[[ "$(jq -r .target_commitish "$response")" = "$BUILD_ID" ]] || {
  echo "Development release revision verification failed" >&2
  exit 1
}
while IFS= read -r existing_id; do
  status="$(request DELETE "/releases/$release_id/assets/$existing_id" /dev/null)"
  [[ "$status" = 204 ]] || { echo "Development asset replacement failed ($status)" >&2; exit 1; }
done < <(jq -r --arg name "$asset_name" '.assets[]? | select(.name == $name) | .id' "$response")

encoded_name="$(jq -nr --arg value "$asset_name" '$value | @uri')"
status="$(request POST "/releases/$release_id/assets?name=$encoded_name" "$response" \
  -F "attachment=@$asset;type=application/zip")"
[[ "$status" = 201 ]] || { echo "Development asset upload failed ($status)" >&2; exit 1; }
[[ "$(jq -r .name "$response")" = "$asset_name" ]] || {
  echo "Development asset name verification failed" >&2
  exit 1
}

uploaded_sha="$(sha256sum "$asset" | cut -d ' ' -f 1)"
downloaded="$RUNNER_TEMP/development-extension.zip"
download_url="$(jq -er .browser_download_url "$response")"
curl --fail --silent --show-error -o "$downloaded" \
  -H "Authorization: token $GITEA_RELEASE_TOKEN" "$download_url"
[[ "$(sha256sum "$downloaded" | cut -d ' ' -f 1)" = "$uploaded_sha" ]] || {
  echo "Development asset checksum verification failed" >&2
  exit 1
}

echo "Development extension artifact published for $BUILD_ID"
