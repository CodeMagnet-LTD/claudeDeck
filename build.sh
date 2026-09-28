#!/bin/sh
# Builds build/ClaudeDeck.app (with the desktop widget extension) via XcodeGen + xcodebuild.
# Without xcodegen it falls back to packaging the Swift package binary (no widget).
#   ./build.sh            release build
#   ./build.sh debug      debug build
#   ./build.sh run        release build, then (re)launch the app
#   ./build.sh install    release build, copy to /Applications and launch from there
set -eu
cd "$(dirname "$0")"
CONFIG=release
[ "${1:-}" = "debug" ] && CONFIG=debug
APP=build/ClaudeDeck.app

# A setting from Config/Local.xcconfig, else Config/Shared.xcconfig (same precedence as Xcode).
setting() {
  for f in Config/Local.xcconfig Config/Shared.xcconfig; do
    [ -f "$f" ] || continue
    v=$(sed -n "s/^ *$1 *= *//p" "$f" | tail -1)
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  done
  return 0
}

if command -v xcodegen >/dev/null 2>&1; then
  # SwiftPM can't build app extensions: the Xcode project (generated from project.yml) builds the
  # app + widget and signs both automatically with the team in Config/*.xcconfig.
  XCONFIG=Release
  [ "$CONFIG" = "debug" ] && XCONFIG=Debug
  xcodegen generate --quiet
  xcodebuild -project ClaudeDeck.xcodeproj -scheme ClaudeDeck -configuration "$XCONFIG" \
    -destination "generic/platform=macOS" -derivedDataPath build/xcode -skipPackagePluginValidation -quiet build
  rm -rf "$APP"
  ditto "build/xcode/Build/Products/$XCONFIG/ClaudeDeck.app" "$APP"
  echo "Signed by xcodebuild: $(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
else
echo "xcodegen not found — SwiftPM build without the widget (brew install xcodegen)"
swift build -c "$CONFIG" --product ClaudeDeck
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ClaudeDeck" "$APP/Contents/MacOS/ClaudeDeck"
cp Support/Info.plist "$APP/Contents/Info.plist"
# Xcode expands these build settings; do it by hand here.
BUNDLE_ID="$(setting DECK_BUNDLE_PREFIX).ClaudeDeck"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
plutil -replace CFBundleURLTypes.0.CFBundleURLName -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$(setting MARKETING_VERSION)" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$(setting CURRENT_PROJECT_VERSION)" "$APP/Contents/Info.plist"
cp Support/THIRD_PARTY_LICENSES.txt "$APP/Contents/Resources/"
[ -f Support/AppIcon.icns ] && cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles (e.g. from dependencies) go into Resources.
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done

# Sign with a stable Apple Development identity of the project's team so macOS keeps
# granted permissions (folders, notifications) across rebuilds. Override with CODESIGN_IDENTITY;
# falls back to ad-hoc signing when no matching certificate is installed.
TEAM=$(setting DEVELOPMENT_TEAM)
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && [ -n "$TEAM" ]; then
  for hash in $(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2}'); do
    if security find-certificate -a -Z -p 2>/dev/null \
        | awk -v h="$hash" '/SHA-1 hash:/{p=($3==h)} p' \
        | sed -n '/BEGIN CERT/,/END CERT/p' | openssl x509 -noout -subject 2>/dev/null \
        | grep -q "OU *= *$TEAM"; then
      IDENTITY=$hash; break
    fi
  done
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --options runtime --sign "$IDENTITY" "$APP" >/dev/null
  echo "Signed with $(security find-identity -v -p codesigning | grep "$IDENTITY" | sed 's/.*"\(.*\)"/\1/')"
else
  codesign --force --deep --sign - "$APP" >/dev/null
  echo "Signed ad-hoc (no Apple Development certificate for team ${TEAM:-?})"
fi
fi
echo "Built $APP"

if [ "${1:-}" = "install" ]; then
  pkill -x ClaudeDeck 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/ClaudeDeck.app
  cp -R "$APP" /Applications/ClaudeDeck.app
  echo "Installed /Applications/ClaudeDeck.app"
  open /Applications/ClaudeDeck.app
fi

if [ "${1:-}" = "run" ]; then
  pkill -x ClaudeDeck 2>/dev/null || true
  sleep 0.3
  open "$APP"
fi
