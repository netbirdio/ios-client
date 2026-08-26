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

# The tvOS fork is not a dependency of the submodule, so its revision cannot be
# read from go.mod the way the upstream gomobile pin is; this constant is the
# single place it is pinned. The CI cache keys follow it through the hash of
# this script.
tvos_fork_module="github.com/netbirdio/gomobile-tvos-fork"
tvos_fork_version="v0.0.0-20260129172842-a56582c0e7c9"

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

# The gomobile driver shells out to gobind, and gobind is the tool that
# actually generates the ObjC bindings and glue. Its own suggestion for a
# missing gobind is `gomobile init`, which installs it from @latest — that
# would let the generator float even though the driver is pinned, changing the
# generated API without a commit here. So both tools are held to the wanted
# revision: the module version embedded in each binary (go version -m) is
# compared to the pin, and a missing or diverging tool is reinstalled at the
# pin.
#
# GOBIN is prepended to PATH so the binary this function verified or installed
# is the one the bind driver (and its PATH lookup of the generator) actually
# runs, even when another copy sits earlier on the caller's PATH.
ensure_gomobile_tools() {
  local module="$1" want="$2"
  shift 2

  local gobin
  gobin=$(go env GOBIN)
  [ -n "$gobin" ] || gobin="$(go env GOPATH)/bin"
  export PATH="$gobin:$PATH"

  local tool path have
  for tool in "$@"; do
    have=""
    if path=$(command -v "$tool"); then
      # `|| true`: go version fails on binaries without build info, and set -e
      # would abort instead of letting the reinstall below repair the tool.
      have=$(go version -m "$path" 2>/dev/null \
        | awk -v mod="$module" '$1 == "mod" && $2 == mod {print $3}') || true
    fi
    if [ "$have" != "$want" ]; then
      echo "Installing $tool at the pin $want (found: ${have:-none})"
      go install "$module/cmd/$tool@$want"
    fi
  done
}

cd netbird-core

version=$(get_version "${1:-}")
echo "Using version: $version"

if [ "$tvos" = true ]; then
  echo "Building for tvOS (using gomobile-netbird fork)"
  GOPROXY=direct ensure_gomobile_tools "$tvos_fork_module" "$tvos_fork_version" \
    gomobile-netbird gobind-netbird
  go get "$tvos_fork_module@$tvos_fork_version"

  gomobile-netbird bind \
    -target=ios,iossimulator,tvos,tvossimulator \
    -bundleid=io.netbird.framework \
    -ldflags="-X github.com/netbirdio/netbird/version.version=$version" \
    -o "$app_path/NetBirdSDK.xcframework" \
    "$(pwd)/client/ios/NetBirdSDK"
else
  echo "Building for iOS"
  ensure_gomobile_tools golang.org/x/mobile \
    "$(go list -m -f '{{.Version}}' golang.org/x/mobile)" \
    gomobile gobind

  gomobile bind \
    -target=ios,iossimulator \
    -bundleid=io.netbird.framework \
    -ldflags="-X github.com/netbirdio/netbird/version.version=$version" \
    -o "$app_path/NetBirdSDK.xcframework" \
    "$(pwd)/client/ios/NetBirdSDK"
fi

cd - > /dev/null
