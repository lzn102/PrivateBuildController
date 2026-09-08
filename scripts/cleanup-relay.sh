#!/usr/bin/env bash
set -euo pipefail

: "${R2_BUCKET:?R2_BUCKET is required}"
: "${R2_ENDPOINT:?R2_ENDPOINT is required}"
: "${R2_OBJECT_KEY:?R2_OBJECT_KEY is required}"

[[ "$R2_BUCKET" =~ ^[A-Za-z0-9._-]+$ ]]
[[ "$R2_ENDPOINT" == https://* ]]
[[ "$R2_OBJECT_KEY" =~ ^relay/[A-Za-z0-9._-]+$ ]]

for command_name in aws jq sha256sum; do
  command -v "$command_name" >/dev/null || {
    echo "Required command is unavailable: $command_name" >&2
    exit 1
  }
done

export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
export AWS_EC2_METADATA_DISABLED=true
test -n "$AWS_ACCESS_KEY_ID"
test -n "$AWS_SECRET_ACCESS_KEY"

relay_uri="s3://$R2_BUCKET/$R2_OBJECT_KEY"
while :; do
  multipart_json="$(aws s3api list-multipart-uploads \
    --endpoint-url "$R2_ENDPOINT" \
    --bucket "$R2_BUCKET" \
    --prefix "$R2_OBJECT_KEY" \
    --output json)"
  upload_ids=()
  while IFS= read -r upload_id; do
    test -z "$upload_id" || upload_ids+=("$upload_id")
  done < <(jq -r --arg key "$R2_OBJECT_KEY" \
    '.Uploads[]? | select(.Key == $key) | .UploadId' <<< "$multipart_json")
  (( ${#upload_ids[@]} > 0 )) || break
  for upload_id in "${upload_ids[@]}"; do
    test -n "$upload_id"
    aws s3api abort-multipart-upload \
      --endpoint-url "$R2_ENDPOINT" \
      --bucket "$R2_BUCKET" \
      --key "$R2_OBJECT_KEY" \
      --upload-id "$upload_id"
  done
done
aws s3 rm --only-show-errors --endpoint-url "$R2_ENDPOINT" "$relay_uri" >/dev/null

remaining_objects="$(aws s3api list-objects-v2 \
  --endpoint-url "$R2_ENDPOINT" \
  --bucket "$R2_BUCKET" \
  --prefix "$R2_OBJECT_KEY" \
  --output json \
  | jq --arg key "$R2_OBJECT_KEY" '[.Contents[]? | select(.Key == $key)] | length')"
remaining_uploads="$(aws s3api list-multipart-uploads \
  --endpoint-url "$R2_ENDPOINT" \
  --bucket "$R2_BUCKET" \
  --prefix "$R2_OBJECT_KEY" \
  --output json \
  | jq --arg key "$R2_OBJECT_KEY" '[.Uploads[]? | select(.Key == $key)] | length')"
test "$remaining_objects" = 0 && test "$remaining_uploads" = 0 || {
  echo "Relay cleanup verification failed" >&2
  exit 1
}

evidence_id="$(printf '%s' "$R2_OBJECT_KEY" | sha256sum | cut -c1-12)"
echo "Relay cleanup verified (evidence: $evidence_id)"
if test -n "${GITHUB_STEP_SUMMARY:-}"; then
  {
    echo "### Relay cleanup evidence"
    echo
    echo "- Result: object and multipart uploads verified absent"
    echo "- Scope: one ephemeral relay key"
    echo "- Evidence ID: \`$evidence_id\`"
  } >> "$GITHUB_STEP_SUMMARY"
fi
