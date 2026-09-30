#!/bin/bash
# Script to build NetBird iOS/tvOS bindings using gomobile
# Usage: ./build-go-lib.sh [--tvos] [version]
#   --tvos    Build for tvOS (uses gomobile-netbird fork, adds tvos/tvossimulator targets)
#   version   Optional version override
#
# Version resolution (first match wins):
#   1. explicit argument            -> the argument ('v' prefix stripped)
#   2. local build (any HEAD)       -> dev-<sha>
#   3. CI, HEAD on a release tag    -> that tag, e.g. 0.77.0
#   4. CI, commits on top of a tag  -> 0.77.0+<sha>
#   5. CI, no reachable tag         -> ci-<sha>
#
# The base tag is the last stable release tag (vX.Y.Z, no pre-release) found
# walking back HEAD's ancestry in the netbird-core submodule — the last tag on
# this branch, not the newest tag in the repository. <sha> is the submodule
# commit.
#
# The version resolution is copied from the Android client's
# build-android-lib.sh; keep the two in sync.

set -euo pipefail

# The tvOS fork is not a dependency of the submodule, so its revision cannot be
# read from go.mod the way the upstream gomobile pin is; this constant is the
# single place it is pinned. The CI cache keys follow it through the hash of
# this script.
tvos_fork_module="github.com/netbirdio/gomobile-tvos-fork"
tvos_fork_version="v0.0.0-20260129172842-a56582c0e7c9"

# Stable release tags only ("v" + digits, no pre-release suffix): a pre-release
# base such as "0.75.0-rc.2" would land in SemVer pre-release position, which
# the management server compares differently from a plain release.
readonly RELEASE_TAG_MATCH='v[0-9]*'
readonly RELEASE_TAG_EXCLUDE='*-*'

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

describe_release_tag() {
  git describe --tags "$@" --match "$RELEASE_TAG_MATCH" --exclude "$RELEASE_TAG_EXCLUDE" 2>/dev/null || true
}

get_version() {
  if [ -n "${1:-}" ]; then
    normalize_version "$1"
    return
  fi

  local short_hash
  short_hash=$(git rev-parse --short HEAD)

  if [ "${GITHUB_ACTIONS:-}" != "true" ]; then
    echo "dev-$short_hash"
    return
  fi

  local tag
  tag=$(describe_release_tag --exact-match)
  if [ -n "$tag" ]; then
    normalize_version "$tag"
    return
  fi

  # Walks HEAD's ancestry, so this is the last release tag on this branch,
  # not the most recently created tag in the repository.
  tag=$(describe_release_tag --abbrev=0)
  if [ -n "$tag" ]; then
    echo "$(normalize_version "$tag")+$short_hash"
    return
  fi

  echo "WARNING: no release tag reachable from HEAD; using ci-$short_hash" >&2
  if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
    echo "WARNING: the submodule is a shallow clone; the tag lookup needs full history" >&2
  fi
  echo "ci-$short_hash"
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
