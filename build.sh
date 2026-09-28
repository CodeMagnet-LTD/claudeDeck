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

# Sign with a stable Apple Development identity of the project's team so macOS keeps
# granted permissions (folders, notifications) across rebuilds. Override with CODESIGN_IDENTITY;
# falls back to ad-hoc signing when no matching certificate is installed.
TEAM=$(sed -n 's/^ *DEVELOPMENT_TEAM: *//p' project.yml | head -1)
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
echo "Built $APP"

if [ "${1:-}" = "run" ]; then
  pkill -x ClaudeDeck 2>/dev/null || true
  sleep 0.3
  open "$APP"
fi
