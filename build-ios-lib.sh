#!/bin/bash
# Script to build NetBird iOS/tvOS bindings using gomobile
# Usage: ./build-go-lib.sh [version]
# - If a version is provided, it will be used (with leading 'v' stripped if present).
# - If no version is provided:
#     * Uses the latest Git tag if available (with leading 'v' stripped if present).
#     * Otherwise, defaults to "dev-<short-hash>".
# - When running in GitHub Actions, uses "ci-<short-hash>" instead of "dev-<short-hash>".

set -euo pipefail

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

# Checkout a git tag in the specified repository path
# Tries the tag as provided, then with 'v' prefix if needed
checkout_tag() {
  local tag="$1"
  local repo_path="$2"

  if git -C "$repo_path" rev-parse "refs/tags/$tag" >/dev/null 2>&1; then
    git -C "$repo_path" checkout "$tag"
    return 0
  fi

  # Try with 'v' prefix if not provided
  if [[ ! "$tag" =~ ^v ]] && git -C "$repo_path" rev-parse "refs/tags/v$tag" >/dev/null 2>&1; then
    git -C "$repo_path" checkout "v$tag"
    return 0
  fi

  echo "Error: Tag '$tag' does not exist" >&2
  exit 1
}

# Get version string, optionally checking out a tag if provided
get_version() {
  local version_arg="${1:-}"
  local repo_path="$2"

  if [ -n "$version_arg" ]; then
    # Version provided - validate and checkout the tag
    checkout_tag "$version_arg" "$repo_path"
    normalize_version "$version_arg"
    return
  fi

  # No version provided - try to get the latest tag
  local tag
  tag=$(git -C "$repo_path" describe --tags --exact-match 2>/dev/null || true)

  if [ -n "$tag" ]; then
    normalize_version "$tag"
    return
  fi

  # Fallback to dev/ci prefix with short hash
  local short_hash
  short_hash=$(git -C "$repo_path" rev-parse --short HEAD)

  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    echo "ci-$short_hash"
  else
    echo "dev-$short_hash"
  fi
}

rn_app_path=$(pwd)
netbirdPath=$rn_app_path/libs/netbird

version=$(get_version "${1:-}" "$netbirdPath")

cd "$netbirdPath"

echo "Using version: $version"

#~/go/bin_gomobile_tvos/gomobile init
#~/go/bin_gomobile_tvos/gomobile bind -target=ios,iossimulator,tvos,tvossimulator -bundleid=io.netbird.framework -ldflags="-X github.com/netbirdio/netbird/version.version=$version" -o $rn_app_path/NetBirdSDK.xcframework $netbirdPath/client/ios/NetBirdSDK

gomobile init
gomobile bind -target=ios,iossimulator -bundleid=io.netbird.framework -ldflags="-X github.com/netbirdio/netbird/version.version=$version" -o $rn_app_path/NetBirdSDK.xcframework $netbirdPath/client/ios/NetBirdSDK

cd - > /dev/null
