#!/usr/bin/env bash
set -euo pipefail
umask 077

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITEA_SOURCE_TOKEN:?GITEA_SOURCE_TOKEN is required}"
ZCODE_CUA_HELPER_APP_URL="${ZCODE_CUA_HELPER_APP_URL:-https://gitea.kudu-wall.ts.net/XCode/ZCode-CUA-Helper-Private/releases/download/v3.14.3/ZCode-Computer-Use-Helper-3.14.3.zip}"
ZCODE_CUA_HELPER_APP_SHA256="${ZCODE_CUA_HELPER_APP_SHA256:-b386364aa7a8e551101fc653eb4eb1484fda78fa741b4182581af9be2c28661a}"
ZCODE_CUA_HELPER_EXPECTED_SIGNING_SHA1="${ZCODE_CUA_HELPER_EXPECTED_SIGNING_SHA1:-14D3F724965D89C9E1DF1223B6E06B328BFF99F1}"
export ZCODE_CUA_HELPER_EXPECTED_SIGNING_SHA1
SOURCE_DIR="${SOURCE_DIR:-$RUNNER_TEMP/private-source}"

allowed_prefix="https://gitea.kudu-wall.ts.net/XCode/ZCode-CUA-Helper-Private/releases/download/"
if [[ "$ZCODE_CUA_HELPER_APP_URL" != "$allowed_prefix"* ]]; then
  echo "Refusing to send the Gitea source token outside the private CUA Helper release path" >&2
  exit 2
fi
if [[ ! "$ZCODE_CUA_HELPER_APP_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "Pinned CUA Helper SHA-256 must contain 64 hexadecimal characters" >&2
  exit 2
fi

archive_path="$RUNNER_TEMP/zcode-cua-helper-app.zip"
extract_path="$RUNNER_TEMP/zcode-cua-helper-app"
if [[ -e "$extract_path" || -e "$archive_path" ]]; then
  echo "CUA Helper download destination already exists" >&2
  exit 2
fi
mkdir -p "$extract_path"
curl --fail --location --silent --show-error --retry 3 \
  --header "Authorization: token $GITEA_SOURCE_TOKEN" \
  --output "$archive_path" "$ZCODE_CUA_HELPER_APP_URL"
actual_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
expected_sha256="$(printf '%s' "$ZCODE_CUA_HELPER_APP_SHA256" | tr '[:upper:]' '[:lower:]')"
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
  echo "Downloaded CUA Helper archive does not match its pinned SHA-256" >&2
  exit 1
fi
ditto -x -k "$archive_path" "$extract_path"
if [[ ! -d "$extract_path/ZCode Computer Use.app/Contents" ]]; then
  echo "Private CUA Helper archive did not contain the expected app bundle" >&2
  exit 1
fi
SOURCE_ROOT="$SOURCE_DIR" HELPER_BUNDLE="$extract_path/ZCode Computer Use.app" node --input-type=module <<'NODE'
import { readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
const sourceRoot = resolve(process.env.SOURCE_ROOT);
const pkg = JSON.parse(await readFile(join(sourceRoot, "package.json"), "utf8"));
const { verifyPrebuiltProductCuaHelper } = await import(
  pathToFileURL(join(sourceRoot, "packages/desktop/scripts/cua-helper-assets.mjs"))
);
const result = await verifyPrebuiltProductCuaHelper({
  appPath: process.env.HELPER_BUNDLE,
  expectedSigningIdentitySha1: process.env.ZCODE_CUA_HELPER_EXPECTED_SIGNING_SHA1,
  expectedVersion: pkg.version,
});
console.log(`Verified pre-signed CUA Helper ${result.bundleVersion} (${result.signingIdentitySha1})`);
NODE
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'ZCODE_CUA_HELPER_APP_PATH=%s\n' "$extract_path/ZCode Computer Use.app" >> "$GITHUB_ENV"
  printf 'ZCODE_CUA_HELPER_EXPECTED_SIGNING_SHA1=%s\n' "$ZCODE_CUA_HELPER_EXPECTED_SIGNING_SHA1" >> "$GITHUB_ENV"
fi
echo "Pinned private CUA Helper archive downloaded and verified"
