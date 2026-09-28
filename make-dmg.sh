#!/bin/sh
# Packs build/ClaudeDeck.app into build/ClaudeDeck.dmg (drag-to-Applications layout).
#
#   ./make-dmg.sh              unsigned DMG (fine for testing)
#   ./make-dmg.sh <identity>   DMG signed with that codesign identity (notarize.sh passes its
#                              Developer ID; notarization and stapling happen there)
set -eu
cd "$(dirname "$0")"

APP=build/ClaudeDeck.app
DMG=build/ClaudeDeck.dmg
STAGE=build/dmg-stage

[ -d "$APP" ] || { echo "❌ $APP not found; run ./build.sh first" >&2; exit 1; }

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/ClaudeDeck.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname ClaudeDeck -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" -quiet
rm -rf "$STAGE"

if [ -n "${1:-}" ]; then
  codesign --force --timestamp --sign "$1" "$DMG"
  codesign --verify --verbose=2 "$DMG"
fi
echo "DMG: $DMG"
