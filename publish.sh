#!/bin/sh
# Publishes the draft GitHub release made by `./release.sh --draft`, then offers it to existing
# users: adds it to the Sparkle feed (docs/appcast.xml) and pushes that to main (GitHub Pages).
#
#   ./publish.sh
set -eu
cd "$(dirname "$0")"

fail() { printf '\n❌ %s\n' "$1" >&2; exit 1; }

VERSION=$(sed -n 's/^ *MARKETING_VERSION *= *//p' Config/Shared.xcconfig | tail -1)
TAG="v$VERSION"

[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || fail "Run from the main branch."
[ -z "$(git status --porcelain)" ] || fail "Working tree is not clean; commit first."
git fetch --quiet origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main differs from origin/main; push or pull first."

DRAFT=$(gh release view "$TAG" --json isDraft -q .isDraft 2>/dev/null) || fail "No release $TAG; run ./release.sh --draft first."
if [ "$DRAFT" = "true" ]; then
  gh release edit "$TAG" --draft=false --latest >/dev/null
  echo "Published $TAG on GitHub."
else
  echo "$TAG is already published; updating the appcast only."
fi

tools/update-appcast.sh
if [ -n "$(git status --porcelain docs/appcast.xml)" ]; then
  git add docs/appcast.xml
  git commit -q -m "Appcast: ClaudeDeck $VERSION"
  git push -q origin main
fi
echo "✅ $TAG is live; installed copies will offer it (GitHub Pages can take a minute to update)."
