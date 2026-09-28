#!/bin/sh
# Publishes a GitHub release with the notarized DMG.
#
#   ./release.sh            version from Config/Shared.xcconfig (MARKETING_VERSION), tag v<version>
#   ./release.sh --draft    creates the release as a draft (review on GitHub, then publish)
#
# Needs: a clean main branch pushed to the GitHub remote, `gh auth login`, and everything
# notarize.sh needs (Developer ID certificate + notarytool profile).
# Output: build/ClaudeDeck-<version>.dmg and .sha256, uploaded to the release.
set -eu
cd "$(dirname "$0")"

fail() { printf '\n❌ %s\n' "$1" >&2; exit 1; }

DRAFT=""
[ "${1:-}" = "--draft" ] && DRAFT="--draft"

VERSION=$(sed -n 's/^ *MARKETING_VERSION *= *//p' Config/Shared.xcconfig | tail -1)
[ -n "$VERSION" ] || fail "MARKETING_VERSION not found in Config/Shared.xcconfig."
TAG="v$VERSION"

# 1. Preconditions, before anything slow happens.
command -v gh >/dev/null || fail "gh is not installed:  brew install gh"
gh auth status >/dev/null 2>&1 || fail "gh is not logged in:  gh auth login"
[ -z "$(git status --porcelain)" ] || fail "Working tree is not clean; commit first."
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || fail "Releases are made from the main branch only."
git fetch --quiet --tags origin || fail "Could not reach origin."
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main differs from origin/main; push or pull first."
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "Tag $TAG already exists; bump MARKETING_VERSION in Config/Shared.xcconfig."

# 2. Build, sign, notarize, staple (app + DMG).
./notarize.sh

DMG="build/ClaudeDeck-$VERSION.dmg"
mv -f build/ClaudeDeck.dmg "$DMG"
(cd build && shasum -a 256 "ClaudeDeck-$VERSION.dmg" > "ClaudeDeck-$VERSION.dmg.sha256")

# 3. Last check before going public.
echo
echo "About to publish: $TAG  ($(gh repo view --json nameWithOwner -q .nameWithOwner))  ${DRAFT:+[draft]}"
echo "  $DMG  $(cut -d' ' -f1 "$DMG.sha256")"
printf "Continue? [y/N] "
read -r ANSWER
case "$ANSWER" in y|Y|yes|YES) ;; *) fail "Cancelled; no tag or release was created." ;; esac

# 4. Tag and release.
git tag -a "$TAG" -m "ClaudeDeck $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$DMG" "$DMG.sha256" --title "ClaudeDeck $VERSION" --generate-notes --verify-tag $DRAFT
echo "✅ Published $TAG."
