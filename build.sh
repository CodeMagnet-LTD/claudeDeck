#!/bin/sh
# Builds build/ClaudeDeck.app from the Swift package.
#   ./build.sh            release build
#   ./build.sh debug      debug build
#   ./build.sh run        release build, then (re)launch the app
set -eu
cd "$(dirname "$0")"
CONFIG=release
[ "${1:-}" = "debug" ] && CONFIG=debug

swift build -c "$CONFIG" --product ClaudeDeck
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP=build/ClaudeDeck.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ClaudeDeck" "$APP/Contents/MacOS/ClaudeDeck"
cp Support/Info.plist "$APP/Contents/Info.plist"
[ -f Support/AppIcon.icns ] && cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles (e.g. from dependencies) go into Resources.
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"

if [ "${1:-}" = "run" ]; then
  pkill -x ClaudeDeck 2>/dev/null || true
  sleep 0.3
  open "$APP"
fi
