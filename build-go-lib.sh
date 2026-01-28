#!/bin/bash
set -e

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

rn_app_path=$(pwd)
netbirdPath=$rn_app_path/libs/netbird

if [ -n "$1" ]; then
    checkout_tag "$1" "$netbirdPath"
    version=$(normalize_version "$1")
else
    version=development
fi

cd "$netbirdPath"

echo "Building NetBirdSDK version: $version"

gomobile-netbird init
CGO_ENABLED=0 gomobile-netbird bind -target=ios,iossimulator,tvos,tvossimulator -bundleid=io.netbird.framework -ldflags="-X github.com/netbirdio/netbird/version.version=$version" -o $rn_app_path/NetBirdSDK.xcframework $netbirdPath/client/ios/NetBirdSDK

cd -
