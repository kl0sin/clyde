#!/usr/bin/env bash
# Stamp the freshly built DMG into Casks/clyde.rb and push the result
# to the public Homebrew tap so `brew install --cask clyde` picks up
# the new version.
#
# Required env vars:
#   HOMEBREW_TAP_TOKEN   — GitHub token with write access to the tap repo.
#                          Locally: omit and the script will rely on the
#                          ambient `gh auth setup-git` credential helper.
# Optional env vars:
#   HOMEBREW_TAP_REPO    — defaults to "kl0sin/homebrew-tap"
#   RELEASE_VERSION      — overrides the version read from Info.plist.
#                          The release workflow MUST pass this because the
#                          "Commit appcast back to main" step reverts the
#                          stamped Info.plist before this script runs, so
#                          PlistBuddy would otherwise read the dev-time
#                          placeholder version.
#
# Usage:
#   scripts/release/update-cask.sh path/to/Clyde-0.2.1.dmg
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INFO_PLIST="$PROJECT_ROOT/Clyde/Info.plist"
LOCAL_CASK="$PROJECT_ROOT/Casks/clyde.rb"
TAP_REPO="${HOMEBREW_TAP_REPO:-kl0sin/homebrew-tap}"

DMG="${1:-}"
if [[ -z "$DMG" || ! -f "$DMG" ]]; then
    echo "Usage: $0 path/to/Clyde-x.y.z.dmg" >&2
    exit 1
fi

if [[ -n "${RELEASE_VERSION:-}" ]]; then
    VERSION="$RELEASE_VERSION"
else
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
fi
SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"

if [[ -z "$VERSION" || -z "$SHA256" ]]; then
    echo "ERROR: failed to read version ($VERSION) or sha256 ($SHA256)" >&2
    exit 1
fi

# Rewrite the local cask in place. The two lines we touch live next to
# each other right after `cask "clyde" do`, so we anchor on the keyword
# at the start of the line. BSD sed (the macOS default) needs the empty
# string after -i.
sed -i '' -E "s|^([[:space:]]*version )\".*\"|\\1\"${VERSION}\"|" "$LOCAL_CASK"
sed -i '' -E "s|^([[:space:]]*sha256 )\".*\"|\\1\"${SHA256}\"|" "$LOCAL_CASK"

echo "==> Local cask stamped: version=${VERSION} sha256=${SHA256}"

# Mirror the stamped cask into the public tap.
TAP_DIR="$(mktemp -d)"
trap 'rm -rf "$TAP_DIR"' EXIT

if [[ -n "${HOMEBREW_TAP_TOKEN:-}" ]]; then
    CLONE_URL="https://x-access-token:${HOMEBREW_TAP_TOKEN}@github.com/${TAP_REPO}.git"
else
    CLONE_URL="https://github.com/${TAP_REPO}.git"
fi

git clone --depth 1 "$CLONE_URL" "$TAP_DIR"

mkdir -p "$TAP_DIR/Casks"
cp "$LOCAL_CASK" "$TAP_DIR/Casks/clyde.rb"

cd "$TAP_DIR"

if git diff --quiet --exit-code Casks/clyde.rb; then
    echo "==> Tap already at version ${VERSION} — nothing to push"
    exit 0
fi

git -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit -am "Bump clyde to ${VERSION}"

git push origin HEAD

echo "==> Pushed Clyde ${VERSION} cask to ${TAP_REPO}"
