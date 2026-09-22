#!/usr/bin/env bash
set -euo pipefail

: "${OUTPUT_DIR:?OUTPUT_DIR is required}"
: "${PACKAGE_PATH:?PACKAGE_PATH is required}"

rm -f "$PACKAGE_PATH" "$PACKAGE_PATH.sha256"
case "$PACKAGE_PATH" in
  *.tar.gz)
    tar -C "$OUTPUT_DIR" -czf "$PACKAGE_PATH" .
    ;;
  *.zip)
    if command -v 7z >/dev/null 2>&1; then
      (cd "$OUTPUT_DIR" && 7z a -bd -y "$PACKAGE_PATH" . >/dev/null)
    else
      (cd "$OUTPUT_DIR" && zip -q -r "$PACKAGE_PATH" .)
    fi
    ;;
  *)
    echo "PACKAGE_PATH must end in .zip or .tar.gz" >&2
    exit 2
    ;;
esac

if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$PACKAGE_PATH" > "$PACKAGE_PATH.sha256"
else
  sha256sum "$PACKAGE_PATH" > "$PACKAGE_PATH.sha256"
fi
