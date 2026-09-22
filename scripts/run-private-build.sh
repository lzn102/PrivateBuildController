#!/usr/bin/env bash
set -euo pipefail

: "${SOURCE_DIR:?SOURCE_DIR is required}"
: "${OUTPUT_DIR:?OUTPUT_DIR is required}"
: "${BUILD_TARGET:?BUILD_TARGET is required}"

build_script="$SOURCE_DIR/ci/build.sh"
if [[ ! -x "$build_script" ]]; then
  echo "Private source must provide executable ci/build.sh" >&2
  exit 2
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
bash "$build_script" "$BUILD_TARGET" "$OUTPUT_DIR"

if [[ -z "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "Build completed without distributable output" >&2
  exit 3
fi

echo "Private build completed for $BUILD_TARGET"
