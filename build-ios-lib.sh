#!/bin/bash
# Script to build NetBird iOS/tvOS bindings using gomobile
#
# Usage: ./build-ios-lib.sh [platform] [version]
#
# Parameters:
#   1. platform (optional): Target platform(s) to build for
#      - ios   : Build for iOS and iOS Simulator only (uses standard gomobile)
#      - tvos  : Build for tvOS and tvOS Simulator only (uses gomobile-netbird)
#      - both  : Build for all platforms (uses gomobile-netbird) [default]
#
#   2. version (optional): Git tag to build
#      - If provided, validates the tag exists in the submodule and checks it out
#      - If omitted and current commit is exactly tagged, uses that tag
#      - Otherwise, uses "dev-<short-hash>" (or "ci-<short-hash>" in GitHub Actions)
#      - Leading 'v' is stripped from semver tags (v1.2.3 -> 1.2.3)
#
# Examples:
#   ./build-ios-lib.sh              # Build both platforms using current commit
#   ./build-ios-lib.sh ios          # Build iOS only using current commit
#   ./build-ios-lib.sh tvos v0.64.1 # Build tvOS only using tag v0.64.1
#   ./build-ios-lib.sh both v0.64.1 # Build both platforms using tag v0.64.1
#
# Output:
#   Creates NetBirdSDK.xcframework in the current directory

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

  # No version provided - try to get an exact tag for current commit
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

# Parse arguments
platform="${1:-both}"
version_arg="${2:-}"

# Validate platform argument
case "$platform" in
  ios|tvos|both)
    ;;
  *)
    echo "Error: Invalid platform '$platform'. Must be 'ios', 'tvos', or 'both'." >&2
    exit 1
    ;;
esac

# Get version (this also checks out the tag if provided)
version=$(get_version "$version_arg" "$netbirdPath")

cd "$netbirdPath"

echo "Using version: $version"
echo "Building for platform: $platform"

# Set targets and gomobile command based on platform
case "$platform" in
  ios)
    targets="ios,iossimulator"
    gomobile_cmd="gomobile"
    ;;
  tvos)
    targets="tvos,tvossimulator"
    gomobile_cmd="gomobile-netbird"
    ;;
  both)
    targets="ios,iossimulator,tvos,tvossimulator"
    gomobile_cmd="gomobile-netbird"
    ;;
esac

# Initialize gomobile
$gomobile_cmd init

# Build
CGO_ENABLED=0 $gomobile_cmd bind \
  -target="$targets" \
  -bundleid=io.netbird.framework \
  -ldflags="-X github.com/netbirdio/netbird/version.version=$version" \
  -o "$rn_app_path/NetBirdSDK.xcframework" \
  "$netbirdPath/client/ios/NetBirdSDK"

cd - > /dev/null
