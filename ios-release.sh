#!/bin/sh
# Archives ClaudeDeckRemote (iPhone/iPad) and uploads it to App Store Connect for TestFlight.
#
#   ./ios-release.sh            version and build from Config/Shared.xcconfig, like the Mac app
#
# Signs and uploads with an App Store Connect API key (no Xcode account or keychain login needed):
#   ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8     the key file (never in the repo)
#   ~/.appstoreconnect/claudedeck.env                       ASC_KEY_ID=…  ASC_ISSUER_ID=…
# (or ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH in the environment).
# App Store Connect gives the upload the next free build number (CURRENT_PROJECT_VERSION is only a start).
set -eu
cd "$(dirname "$0")"

fail() { printf '\n❌ %s\n' "$1" >&2; exit 1; }

CONFIG="$HOME/.appstoreconnect/claudedeck.env"
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
: "${ASC_KEY_ID:?set ASC_KEY_ID in $CONFIG (App Store Connect › Users and Access › Integrations › Keys)}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID in $CONFIG}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
[ -f "$ASC_KEY_PATH" ] || fail "API key not found: $ASC_KEY_PATH"

VERSION=$(sed -n 's/^ *MARKETING_VERSION *= *//p' Config/Shared.xcconfig | tail -1)
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION *= *//p' Config/Shared.xcconfig | tail -1)
TEAM=$(sed -n 's/^ *DEVELOPMENT_TEAM *= *//p' Config/Shared.xcconfig | tail -1)
[ -n "$VERSION" ] && [ -n "$BUILD" ] || fail "MARKETING_VERSION / CURRENT_PROJECT_VERSION not found in Config/Shared.xcconfig."
[ -n "$TEAM" ] || TEAM=V6G4B5T63L

[ -z "$(git status --porcelain)" ] || fail "Working tree is not clean; commit first."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
AUTH="-allowProvisioningUpdates -authenticationKeyPath $ASC_KEY_PATH -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"
OUT=build/ios-release
ARCHIVE="$OUT/ClaudeDeckRemote-$VERSION-$BUILD.xcarchive"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "▸ Archiving ClaudeDeckRemote $VERSION ($BUILD)…"
# shellcheck disable=SC2086
xcodebuild archive -scheme ClaudeDeckRemote -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" -derivedDataPath build/xcode-ios-archive \
  -skipPackagePluginValidation -skipMacroValidation $AUTH > "$OUT/archive.log" 2>&1 \
  || { grep -E "error:" "$OUT/archive.log" | head -20 >&2; fail "Archive failed (log: $OUT/archive.log)."; }

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><true/>
</dict></plist>
EOF

echo "▸ Uploading to App Store Connect…"
# System tools only: a Homebrew rsync earlier in PATH breaks Xcode's IPA packaging ("Copy failed").
# shellcheck disable=SC2086
PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export" $AUTH > "$OUT/upload.log" 2>&1 \
  || { grep -iE "error" "$OUT/upload.log" | grep -v DVTDeveloperAccountManager | head -20 >&2; fail "Upload failed (log: $OUT/upload.log)."; }

echo "✅ ClaudeDeckRemote $VERSION uploaded (App Store Connect sets the build number). It processes it for a few minutes, then it shows in TestFlight."
