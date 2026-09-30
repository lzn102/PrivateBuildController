#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bash -n "$root/scripts/deploy-development.sh"
ruby -e 'require "yaml"; YAML.parse_file(ARGV.fetch(0))' "$root/.github/workflows/development-deploy.yml"
grep -Fq "if: inputs.image_transport != 'registry'" "$root/.github/workflows/development-deploy.yml"
grep -Fq 'REGISTRY_SOURCE_IMAGE: ${{ secrets.DEV_WSL_REGISTRY_IMAGE }}' "$root/.github/workflows/development-deploy.yml"
grep -Fq 'docker pull "$source_ref"' "$root/scripts/deploy-development.sh"
grep -Fq 'test "$image_revision" = "$build_id"' "$root/scripts/deploy-development.sh"
grep -Fq '[[ "$REGISTRY_SOURCE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]' "$root/scripts/deploy-development.sh"
if IMAGE_TRANSPORT=invalid bash "$root/scripts/deploy-development.sh" 2>/dev/null; then
  echo 'Invalid transport was accepted' >&2
  exit 1
fi
echo 'Registry transport syntax, guards, and workflow checks passed'
