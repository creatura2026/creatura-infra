#!/usr/bin/env bash
# Read manifests by digest, never build, copy or select a floating tag.
set -euo pipefail
: "${GHCR_READ_TOKEN:?Set GHCR_READ_TOKEN with read:packages access}"
: "${GHCR_USERNAME:?Set GHCR_USERNAME}"
export DOCKER_CONFIG
DOCKER_CONFIG=$(mktemp -d)
trap 'rm -rf "$DOCKER_CONFIG"' EXIT
printf '%s' "$GHCR_READ_TOKEN" | docker login ghcr.io --username "$GHCR_USERNAME" --password-stdin
for name in creatura-backend creatura-db; do
  image=$(jq -r --arg name "$name" '.images[$name]' .deploy/release/release.json)
  docker manifest inspect "$image" > /dev/null
done
