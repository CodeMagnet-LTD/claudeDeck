#!/bin/sh
# Adds the current version to docs/appcast.xml (the Sparkle update feed served by GitHub Pages).
#
#   tools/update-appcast.sh          version from Config/Shared.xcconfig
#
# Needs build/ClaudeDeck-<version>.dmg (made by release.sh) and the Sparkle EdDSA private key in
# the login keychain (account "codemagnet"; created once with Sparkle's generate_keys). The
# DMG must match the one attached to the GitHub release: its SHA-256 is checked against the
# release's .sha256 asset. Release notes come from the GitHub release body (Markdown).
# Only run this once the release is published: the feed points users at its download URL.
set -eu
cd "$(dirname "$0")/.."

fail() { printf '\n❌ %s\n' "$1" >&2; exit 1; }

VERSION=$(sed -n 's/^ *MARKETING_VERSION *= *//p' Config/Shared.xcconfig | tail -1)
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION *= *//p' Config/Shared.xcconfig | tail -1)
TAG="v$VERSION"
DMG="build/ClaudeDeck-$VERSION.dmg"
KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-codemagnet}"
SIGN_UPDATE=$(find .build/artifacts -path '*Sparkle/bin/sign_update' -type f 2>/dev/null | head -1)

[ -f "$DMG" ] || fail "$DMG not found; run ./release.sh first."
[ -n "$SIGN_UPDATE" ] || fail "Sparkle's sign_update not found; run: swift package resolve"
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner) || fail "gh could not read the repository."

# The local DMG must be the released one.
REMOTE_SHA=$(gh release download "$TAG" -p "ClaudeDeck-$VERSION.dmg.sha256" -O - 2>/dev/null | cut -d' ' -f1) \
  || fail "Could not download the .sha256 asset of $TAG."
LOCAL_SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
[ "$REMOTE_SHA" = "$LOCAL_SHA" ] || fail "$DMG differs from the DMG attached to $TAG."

SIGNATURE=$("$SIGN_UPDATE" --account "$KEY_ACCOUNT" "$DMG") || fail "sign_update failed (is the Sparkle key in the keychain?)."
NOTES=$(gh release view "$TAG" --json body -q .body)

VERSION="$VERSION" BUILD="$BUILD" TAG="$TAG" REPO="$REPO" SIGNATURE="$SIGNATURE" NOTES="$NOTES" \
  python3 tools/appcast.py docs/appcast.xml
echo "✅ docs/appcast.xml now offers $VERSION ($BUILD)."
