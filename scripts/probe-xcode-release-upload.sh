#!/usr/bin/env bash
set -euo pipefail
base='https://gitea.kudu-wall.ts.net/api/v1/repos/XCode/ZCode/releases/324/assets'
probe_name="xcode-ci-upload-probe-${GITHUB_RUN_ID}.bin"
probe_path="$RUNNER_TEMP/$probe_name"
response_path="$RUNNER_TEMP/xcode-ci-probe-response.json"
cleanup_probe() {
  curl --fail --silent --show-error --max-time 15 --header "Authorization: token $GITEA_RELEASE_TOKEN" "$base" > "$response_path" || return 0
  PROBE_NAME="$probe_name" RESPONSE_PATH="$response_path" node -e 'const fs=require("fs");for(const a of JSON.parse(fs.readFileSync(process.env.RESPONSE_PATH)))if(a.name===process.env.PROBE_NAME)console.log(a.id)' | while read -r asset_id; do
    curl --fail --silent --show-error --max-time 15 --request DELETE --header "Authorization: token $GITEA_RELEASE_TOKEN" "$base/$asset_id"
  done
  rm -f "$probe_path" "$response_path"
}
trap cleanup_probe EXIT
dd if=/dev/zero of="$probe_path" bs=1048576 count=16 2>/dev/null
curl --fail --silent --show-error --max-time 60 --header "Authorization: token $GITEA_RELEASE_TOKEN" --form "attachment=@$probe_path" --output "$response_path" --write-out 'http=%{http_code} size=%{size_upload} speed=%{speed_upload} duration=%{time_total}\n' "$base?name=$probe_name"
