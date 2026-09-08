#!/usr/bin/env bash
set -euo pipefail

required=(
  ACCEPTANCE_ADMIN_TOKEN ACCEPTANCE_API_TOKEN ACCEPTANCE_ENDPOINTS
  ARTIFACT_BUILD_COMMAND_B64 ARTIFACT_E2E_COMMAND_B64 BUILD_ID
  REPOSITORY_API_TOKEN REPOSITORY_API_URL RUNNER_TEMP
)
for name in "${required[@]}"; do
  test -n "${!name:-}" || { echo "$name is required" >&2; exit 2; }
done
SOURCE_DIR="${SOURCE_DIR:-$RUNNER_TEMP/private-source}"
ARTIFACT_EXTENSION="${ARTIFACT_EXTENSION:-bin}"

[[ "$BUILD_ID" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid build identifier" >&2; exit 2; }
[[ "$ARTIFACT_EXTENSION" =~ ^[A-Za-z0-9]{1,12}$ ]] || {
  echo "Artifact extension is invalid" >&2
  exit 2
}
[[ "$ARTIFACT_BUILD_COMMAND_B64" =~ ^[A-Za-z0-9+/=]+$ ]]
[[ "$ARTIFACT_E2E_COMMAND_B64" =~ ^[A-Za-z0-9+/=]+$ ]]
[[ "$REPOSITORY_API_URL" == https://*/api/v1/repos/*/* ]] || {
  echo "Repository API endpoint is invalid" >&2
  exit 2
}
test -d "$SOURCE_DIR" || { echo "Prepared source is unavailable" >&2; exit 2; }

for command_name in base64 curl jq openssl sha256sum timeout; do
  command -v "$command_name" >/dev/null || {
    echo "Required command is unavailable: $command_name" >&2
    exit 1
  }
done

decode_command() {
  local encoded="$1" label="$2" decoded
  decoded="$(printf '%s' "$encoded" | base64 -d)" || {
    echo "$label command is not valid base64" >&2
    exit 2
  }
  test -n "$decoded" || { echo "$label command is empty" >&2; exit 2; }
  printf '%s' "$decoded"
}

artifact="$RUNNER_TEMP/development-artifact.$ARTIFACT_EXTENSION"
downloaded="$RUNNER_TEMP/development-artifact.download"
log="$RUNNER_TEMP/development-acceptance.log"
response="$RUNNER_TEMP/development-release-response.json"
state="$RUNNER_TEMP/development-artifact-state.json"
rm -f "$artifact" "$downloaded" "$log" "$response" "$state"

export DEVELOPMENT_ADMIN_TOKEN="$ACCEPTANCE_ADMIN_TOKEN"
export DEVELOPMENT_API_TOKEN="$ACCEPTANCE_API_TOKEN"
export DEVELOPMENT_ARTIFACT_PATH="$artifact"
export DEVELOPMENT_BUILD_ID="$BUILD_ID"
export DEVELOPMENT_ENDPOINTS="$ACCEPTANCE_ENDPOINTS"

build_command="$(decode_command "$ARTIFACT_BUILD_COMMAND_B64" Build)"
if ! (cd "$SOURCE_DIR" && timeout --signal=TERM --kill-after=30s 15m \
    bash -euo pipefail -c "$build_command") >"$log" 2>&1; then
  echo "Development artifact build failed" >&2
  exit 1
fi
test -s "$artifact" || { echo "Development artifact was not produced" >&2; exit 1; }

e2e_command="$(decode_command "$ARTIFACT_E2E_COMMAND_B64" E2E)"
if ! (cd "$SOURCE_DIR" && timeout --signal=TERM --kill-after=30s 20m \
    bash -euo pipefail -c "$e2e_command") >>"$log" 2>&1; then
  echo "Development E2E failed" >&2
  grep -E '^\[PassKeyExt E2E (scenario|error|cleanup)\]' "$log" >&2 || true
  evidence_line="$(grep -E '^\{.*\}$' "$log" | tail -1 || true)"
  if test -n "$evidence_line" && jq -e \
      --arg build_id "$BUILD_ID" \
      '.buildId == $build_id and (.ok | type == "boolean") and (.scenarios | type == "array")' \
      >/dev/null 2>&1 <<< "$evidence_line"; then
    jq -c '{buildId,ok,failure:(.failure | if type == "object" then {code,name,stage} else null end),
      scenarios:[.scenarios[] | {label,ok,error:(.error | if type == "object" then {code,name} else null end)}],
      cleanup:{profileRemoved:.cleanup.profileRemoved,testSiteAccountsRemoved:.cleanup.testSiteAccountsRemoved,
        controlPlane:{residualActiveSessions:.cleanup.controlPlane.residualActiveSessions,
          residualClients:.cleanup.controlPlane.residualClients,residualPolicies:.cleanup.controlPlane.residualPolicies},
        extensionCache:{cleared:.cleanup.extensionCache.cleared},
        vault:{residualActiveItems:.cleanup.vault.residualActiveItems,
          trashedItems:.cleanup.vault.trashedItems}}}' <<< "$evidence_line" >&2
  fi
  exit 1
fi

request() {
  local method="$1" path="$2" output="$3"
  shift 3
  local retry_args=()
  if [[ "$method" != POST ]]; then
    retry_args=(--retry 3 --retry-all-errors)
  fi
  curl --silent --show-error -o "$output" -w '%{http_code}' \
    --connect-timeout 10 --max-time 120 "${retry_args[@]}" \
    -X "$method" \
    -H "Authorization: token $REPOSITORY_API_TOKEN" \
    "$@" \
    "$REPOSITORY_API_URL$path"
}

asset_name="development-artifact-$BUILD_ID.$ARTIFACT_EXTENSION"
tag="ci-dev-$BUILD_ID"
encoded_tag="$(jq -nr --arg value "$tag" '$value | @uri')"
transaction_marker="development-publication-${GITHUB_RUN_ID:-manual}-${GITHUB_RUN_ATTEMPT:-1}-$(openssl rand -hex 16)"
[[ "$transaction_marker" =~ ^development-publication-[A-Za-z0-9._-]+$ ]]
release_body="Action-built development artifact.

Transaction: $transaction_marker"

write_state() {
  local release_id="$1" release_pending="$2" release_created="$3"
  local tag_created="$4" asset_id="$5" asset_pending="$6"
  jq -cn \
    --arg assetId "$asset_id" \
    --arg assetName "$asset_name" \
    --arg buildId "$BUILD_ID" \
    --argjson assetPending "$asset_pending" \
    --arg releaseId "$release_id" \
    --argjson releasePending "$release_pending" \
    --argjson releaseCreated "$release_created" \
    --arg tag "$tag" \
    --argjson tagCreated "$tag_created" \
    --arg transactionMarker "$transaction_marker" \
    '{assetId:(if $assetId == "" then null else $assetId end),assetName:$assetName,
      assetPending:$assetPending,buildId:$buildId,
      releaseId:(if $releaseId == "" then null else $releaseId end),
      releasePending:$releasePending,releaseCreated:$releaseCreated,tag:$tag,
      tagCreated:$tagCreated,transactionMarker:$transactionMarker}' > "$state"
  chmod 600 "$state"
}

status="$(request GET "/releases/tags/$encoded_tag" "$response")"
release_created=false
tag_created=false
if [[ "$status" = 404 ]]; then
  tag_response="$RUNNER_TEMP/development-tag-response.json"
  tag_status="$(request GET "/git/refs/tags/$encoded_tag" "$tag_response")"
  if [[ "$tag_status" = 200 ]]; then
    [[ "$(jq -er '.object.sha' "$tag_response")" = "$BUILD_ID" ]] || {
      echo "Existing development tag does not reference the requested revision" >&2
      exit 1
    }
  elif [[ "$tag_status" = 404 ]]; then
    tag_created=true
  else
    echo "Development tag lookup failed ($tag_status)" >&2
    exit 1
  fi

  # Persist rollback ownership before release creation can also create the tag.
  write_state "" true false "$tag_created" "" false
  payload="$(jq -cn --arg tag "$tag" --arg sha "$BUILD_ID" --arg body "$release_body" \
    '{tag_name:$tag,target_commitish:$sha,name:("Development " + $sha),body:$body,draft:false,prerelease:true}')"
  status="$(request POST "/releases" "$response" -H 'Content-Type: application/json' -d "$payload")"
  [[ "$status" = 201 ]] || { echo "Development release creation failed ($status)" >&2; exit 1; }
  release_id="$(jq -er '.id | numbers' "$response")"
  [[ "$(jq -r .target_commitish "$response")" = "$BUILD_ID" ]] || {
    echo "Development release revision verification failed" >&2
    exit 1
  }
  [[ "$(jq -r .body "$response")" = "$release_body" ]] || {
    echo "Development release transaction verification failed" >&2
    exit 1
  }
  release_created=true
  write_state "$release_id" false true "$tag_created" "" false
else
  [[ "$status" = 200 ]] || { echo "Development release lookup failed ($status)" >&2; exit 1; }
  release_id="$(jq -er '.id | numbers' "$response")"
  [[ "$(jq -r .target_commitish "$response")" = "$BUILD_ID" ]] || {
    echo "Development release revision verification failed" >&2
    exit 1
  }
  write_state "$release_id" false false false "" false
fi

uploaded_sha="$(sha256sum "$artifact" | cut -d ' ' -f 1)"
existing_asset="$(jq -c --arg name "$asset_name" '[.assets[]? | select(.name == $name)] | if length == 1 then .[0] elif length == 0 then null else error("duplicate development assets") end' "$response")"
if [[ "$existing_asset" != null ]]; then
  download_url="$(jq -er .browser_download_url <<< "$existing_asset")"
else
  write_state "$release_id" false "$release_created" "$tag_created" "" true
  encoded_name="$(jq -nr --arg value "$asset_name" '$value | @uri')"
  status="$(request POST "/releases/$release_id/assets?name=$encoded_name" "$response" \
    -F "attachment=@$artifact;type=application/octet-stream")"
  [[ "$status" = 201 ]] || { echo "Development asset upload failed ($status)" >&2; exit 1; }
  [[ "$(jq -r .name "$response")" = "$asset_name" ]] || {
    echo "Development asset name verification failed" >&2
    exit 1
  }
  asset_id="$(jq -er .id "$response")"
  download_url="$(jq -er .browser_download_url "$response")"
  write_state "$release_id" false "$release_created" "$tag_created" "$asset_id" false
fi
curl --fail --silent --show-error --location \
  --connect-timeout 10 --max-time 120 --retry 3 --retry-all-errors \
  -o "$downloaded" -H "Authorization: token $REPOSITORY_API_TOKEN" "$download_url"
[[ "$(sha256sum "$downloaded" | cut -d ' ' -f 1)" = "$uploaded_sha" ]] || {
  echo "Development artifact is immutable and its checksum does not match" >&2
  exit 1
}

unset DEVELOPMENT_ADMIN_TOKEN DEVELOPMENT_API_TOKEN DEVELOPMENT_ENDPOINTS
echo "Development E2E passed and artifact publication was verified"
