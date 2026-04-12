#!/bin/bash
# Script to build NetBird iOS/tvOS bindings using gomobile
# Usage: ./build-go-lib.sh [--tvos] [version]
#   --tvos    Build for tvOS (uses gomobile-netbird fork, adds tvos/tvossimulator targets)
#   version   Optional version override
#
# Version resolution:
# - If a version is provided, it will be used (with leading 'v' stripped if present).
# - If no version is provided:
#     * Uses the latest Git tag if available (with leading 'v' stripped if present).
#     * Otherwise, defaults to "dev-<short-hash>".
# - When running in GitHub Actions, uses "ci-<short-hash>" instead of "dev-<short-hash>".

set -euo pipefail

app_path=$(pwd)
tvos=false

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tvos)
      tvos=true
      shift
      ;;
    *)
      break
      ;;
  esac
done

# Normalize semantic versions to drop a leading 'v' (e.g., v1.2.3 -> 1.2.3).
# Only strips if the string starts with 'v' followed by a digit, so it won't affect
# dev/ci strings or other non-semver values.
normalize_version() {
  local ver="$1"
  if [[ "$ver" =~ ^v[0-9] ]]; then
    ver="${ver#v}"
  fi
  echo "$ver"
}

get_version() {
  if [ -n "${1:-}" ]; then
    normalize_version "$1"
    return
  fi

  # Try to get an exact tag
  local tag
  tag=$(git describe --tags --exact-match 2>/dev/null || true)

  if [ -n "$tag" ]; then
    normalize_version "$tag"
    return
  fi

  # Fallback to "<prefix>-<short-hash>"
  local short_hash
  short_hash=$(git rev-parse --short HEAD)

  local new_version
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    new_version="ci-$short_hash"
  else
    new_version="dev-$short_hash"
  fi

  echo "$new_version"
}

cd netbird-core

version=$(get_version "${1:-}")
echo "Using version: $version"

if [ "$tvos" = true ]; then
  echo "Building for tvOS (using gomobile-netbird fork)"
  gomobile-netbird init
  go get github.com/netbirdio/gomobile-tvos-fork@latest

  CGO_ENABLED=0 gomobile-netbird bind \
    -target=ios,iossimulator,tvos,tvossimulator \
    -bundleid=io.netbird.framework \
    -ldflags="-X github.com/netbirdio/netbird/version.version=$version" \
    -o "$app_path/NetBirdSDK.xcframework" \
    "$(pwd)/client/ios/NetBirdSDK"
else
  echo "Building for iOS"
  gomobile init

  CGO_ENABLED=0 gomobile bind \
    -target=ios,iossimulator \
    -bundleid=io.netbird.framework \
    -ldflags="-X github.com/netbirdio/netbird/version.version=$version" \
    -o "$app_path/NetBirdSDK.xcframework" \
    "$(pwd)/client/ios/NetBirdSDK"
fi

cd - > /dev/null
