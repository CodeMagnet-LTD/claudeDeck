#!/bin/sh
# Builds, Developer ID-signs, notarizes and staples build/ClaudeDeck.app and build/ClaudeDeck.dmg
# for distribution outside the Mac App Store.
#
#   ./notarize.sh
#
# Environment:
#   DEVELOPER_ID     codesign identity (name or SHA-1). Default: first "Developer ID Application"
#                    identity found in the keychain.
#   NOTARY_PROFILE   notarytool keychain profile (default: claudedeck), created once with
#                    `xcrun notarytool store-credentials`.
# Output: build/ClaudeDeck.app and build/ClaudeDeck.dmg (both notarized and stapled).
set -eu
cd "$(dirname "$0")"

APP=build/ClaudeDeck.app
ZIP=build/ClaudeDeck.zip
DMG=build/ClaudeDeck.dmg
PROFILE="${NOTARY_PROFILE:-claudedeck}"
TEAM=$(sed -n 's/^ *DEVELOPMENT_TEAM *= *//p' Config/Local.xcconfig 2>/dev/null || true)
[ -n "$TEAM" ] || TEAM=$(sed -n 's/^ *DEVELOPMENT_TEAM *= *//p' Config/Shared.xcconfig)

fail() { printf '\n❌ %s\n' "$1" >&2; exit 1; }

# 1. Developer ID identity (checked first so nothing is built or uploaded without one).
IDENTITY="${DEVELOPER_ID:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')
fi
if [ -z "$IDENTITY" ]; then
  cat >&2 <<EOF

❌ No "Developer ID Application" certificate found.

"Apple Development" certificates only work for development on this Mac; notarization and
distribution need a "Developer ID Application" certificate.

To get one (requires Apple Developer Program membership and the Account Holder/Admin role):
  • Xcode › Settings › Accounts › select the team › Manage Certificates… › "+" › Developer ID Application
    or developer.apple.com › Certificates › "+" › Developer ID Application (with a CSR).
  • Check:  security find-identity -v -p codesigning | grep "Developer ID Application"
  • If there are several, pick one:  DEVELOPER_ID="Developer ID Application: Name (TEAMID)" ./notarize.sh

Create the notarytool keychain profile once (app-specific password:
appleid.apple.com › Sign-In and Security › App-Specific Passwords):
  xcrun notarytool store-credentials "claudedeck" \\
      --apple-id "<your-apple-id-email>" --team-id "$TEAM" --password "<app-specific-password>"
  (For a different profile name:  NOTARY_PROFILE=<name> ./notarize.sh)

Nothing was built and nothing was sent to Apple.
EOF
  exit 1
fi
echo "Signing identity: $IDENTITY"

# The notary profile must exist before we spend time building.
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || fail "notarytool profile \"$PROFILE\" is missing or invalid. Create it:
   xcrun notarytool store-credentials \"$PROFILE\" --apple-id \"<apple-id>\" --team-id \"$TEAM\" --password \"<app-specific-password>\""

# 2. Build (release).
./build.sh

# 3. Re-sign inside-out with Developer ID, hardened runtime and a secure timestamp.
#    Nested code (widget/app extensions, frameworks, helpers) keeps its own entitlements.
sign() {
  codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
    --sign "$IDENTITY" "$1"
}
for nested in "$APP"/Contents/PlugIns/*.appex "$APP"/Contents/Frameworks/* "$APP"/Contents/Library/LoginItems/*.app; do
  if [ -e "$nested" ]; then sign "$nested"; fi
done
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# 4. Notarize the app (submitted as a zip), then staple the ticket to it.
notarize() {
  echo "Submitting for notarization: $1 (profile: $PROFILE)…"
  OUT=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1) || true
  echo "$OUT"
  # notarytool can exit 0 for an "Invalid" result, so check the final status explicitly.
  echo "$OUT" | grep -q "status: Accepted" || {
    SUB=$(echo "$OUT" | awk '/^ *id:/ {print $2; exit}')
    fail "Notarization failed. Details:  xcrun notarytool log ${SUB:-<submission-id>} --keychain-profile \"$PROFILE\""
  }
}
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv "$APP"
rm -f "$ZIP"

# 5. DMG around the stapled app: sign, notarize, staple (both verify offline).
./make-dmg.sh "$IDENTITY"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -vv -t open --context context:primary-signature "$DMG"
echo "✅ Notarized and stapled: $APP  (distribute: $DMG)"
