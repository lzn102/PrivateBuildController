#!/usr/bin/env bash
set -euo pipefail

: "${PRIVATE_HOST:?PRIVATE_HOST is required}"
: "${PRIVATE_IP:?PRIVATE_IP is required}"

[[ "$PRIVATE_HOST" =~ ^[A-Za-z0-9.-]+$ ]]
[[ "$PRIVATE_IP" =~ ^[0-9a-fA-F:.]+$ ]]
printf '%s %s\n' "$PRIVATE_IP" "$PRIVATE_HOST" | sudo tee -a /etc/hosts >/dev/null
curl --fail --silent --connect-timeout 10 --max-time 20 "https://$PRIVATE_HOST/api/v1/version" >/dev/null
echo "Private endpoint reachable"
