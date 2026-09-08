#!/usr/bin/env bash
set -euo pipefail

: "${REPOSITORY_API_TOKEN:?REPOSITORY_API_TOKEN is required}"
: "${REPOSITORY_API_URL:?REPOSITORY_API_URL is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

state="$RUNNER_TEMP/development-artifact-state.json"
test -f "$state" || {
  echo "No development artifact mutation requires rollback"
  exit 0
}

[[ "$REPOSITORY_API_URL" == https://*/api/v1/repos/*/* ]] || {
  echo "Repository API endpoint is invalid" >&2
  exit 2
}
for command_name in curl jq; do
  command -v "$command_name" >/dev/null || {
    echo "Required command is unavailable: $command_name" >&2
    exit 1
  }
done

release_id="$(jq -r '.releaseId // empty' "$state")"
asset_id="$(jq -r '.assetId // empty' "$state")"
asset_name="$(jq -er '.assetName | strings | select(test("^development-artifact-[0-9a-f]{40}\\.[A-Za-z0-9]{1,12}$"))' "$state")"
build_id="$(jq -er '.buildId | strings | select(test("^[0-9a-f]{40}$"))' "$state")"
asset_pending="$(jq -er '.assetPending | booleans | tostring' "$state")"
release_pending="$(jq -er '.releasePending | booleans | tostring' "$state")"
release_created="$(jq -er '.releaseCreated | booleans | tostring' "$state")"
tag="$(jq -er '.tag | strings | select(test("^ci-dev-[0-9a-f]{40}$"))' "$state")"
tag_created="$(jq -er '.tagCreated | booleans | tostring' "$state")"
transaction_marker="$(jq -er '.transactionMarker | strings | select(test("^development-publication-[A-Za-z0-9._-]+$"))' "$state")"
[[ -z "$release_id" || "$release_id" =~ ^[0-9]+$ ]]
[[ -z "$asset_id" || "$asset_id" =~ ^[0-9]+$ ]]
[[ "$tag" == "ci-dev-$build_id" ]]
[[ "$asset_name" == "development-artifact-$build_id."* ]]

request() {
  local method="$1" path="$2" output="${3:-/dev/null}"
  curl --silent --show-error -o "$output" -w '%{http_code}' \
    --connect-timeout 10 --max-time 120 --retry 3 --retry-all-errors \
    -X "$method" \
    -H "Authorization: token $REPOSITORY_API_TOKEN" \
    "$REPOSITORY_API_URL$path"
}

encoded_tag="$(jq -nr --arg value "$tag" '$value | @uri')"
release_owned=false
owned_release_id=""
if [[ "$asset_pending" == true && -z "$asset_id" ]]; then
  # A lost upload response does not prove ownership. Retain the release and asset.
  echo "Pending development asset retained because ownership is unknown"
elif [[ "$release_created" == true ]]; then
  test -n "$release_id"
  release_owned=true
  owned_release_id="$release_id"
elif [[ "$release_pending" == true ]]; then
  lookup="$RUNNER_TEMP/development-artifact-rollback-release.json"
  status="$(request GET "/releases/tags/$encoded_tag" "$lookup")"
  if [[ "$status" == 200 ]]; then
    candidate_id="$(jq -er '.id | numbers' "$lookup")"
    candidate_sha="$(jq -er '.target_commitish | strings' "$lookup")"
    candidate_body="$(jq -er '.body | strings' "$lookup")"
    if [[ "$candidate_sha" == "$build_id" && "$candidate_body" == *"Transaction: $transaction_marker"* ]]; then
      release_owned=true
      owned_release_id="$candidate_id"
    fi
  elif [[ "$status" != 404 ]]; then
    echo "Development release rollback lookup failed ($status)" >&2
    exit 1
  fi
  rm -f "$lookup"
fi

if [[ "$asset_pending" == true && -z "$asset_id" ]]; then
  :
elif [[ "$release_owned" == true ]]; then
  status="$(request DELETE "/releases/$owned_release_id")"
  [[ "$status" == 204 || "$status" == 404 ]] || {
    echo "Development release rollback failed ($status)" >&2
    exit 1
  }
  if [[ "$tag_created" == true ]]; then
    status="$(request DELETE "/tags/$encoded_tag")"
    [[ "$status" == 204 || "$status" == 404 ]] || {
      echo "Development release tag rollback failed ($status)" >&2
      exit 1
    }
  fi
elif [[ -n "$asset_id" ]]; then
  test -n "$release_id"
  status="$(request DELETE "/releases/$release_id/assets/$asset_id")"
  [[ "$status" == 204 || "$status" == 404 ]] || {
    echo "Development asset rollback failed ($status)" >&2
    exit 1
  }
fi

rm -f "$state"
echo "Failed development artifact publication rollback completed"
