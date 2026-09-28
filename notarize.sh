#!/bin/sh
# Builds, Developer ID-signs, notarizes and staples build/ClaudeDeck.app for distribution
# outside the Mac App Store.
#
#   ./notarize.sh
#
# Environment:
#   DEVELOPER_ID     codesign identity (name or SHA-1). Default: first "Developer ID Application"
#                    identity found in the keychain.
#   NOTARY_PROFILE   notarytool keychain profile (default: claudedeck), created once with
#                    `xcrun notarytool store-credentials`.
# Output: build/ClaudeDeck.app (stapled) and build/ClaudeDeck.zip (the notarized upload).
set -eu
cd "$(dirname "$0")"

APP=build/ClaudeDeck.app
ZIP=build/ClaudeDeck.zip
PROFILE="${NOTARY_PROFILE:-claudedeck}"

fail() { printf '\n❌ %s\n' "$1" >&2; exit 1; }

# 1. Developer ID identity (checked first so nothing is built or uploaded without one).
IDENTITY="${DEVELOPER_ID:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')
fi
if [ -z "$IDENTITY" ]; then
  cat >&2 <<'EOF'

❌ "Developer ID Application" sertifikası bulunamadı.

Anahtar zincirinde yalnızca "Apple Development" sertifikaları var; bunlar yalnızca bu Mac'te
geliştirme içindir, notarization ve dağıtım için "Developer ID Application" sertifikası gerekir.

Sertifikayı almak için (Apple Developer Program üyeliği ve takımda Account Holder/Admin rolü gerekir):
  • Xcode › Settings › Accounts › takımı seç › Manage Certificates… › "+" › Developer ID Application
    ya da developer.apple.com › Certificates › "+" › Developer ID Application (CSR ile).
  • Kontrol:  security find-identity -v -p codesigning | grep "Developer ID Application"
  • Birden fazla varsa seçmek için:  DEVELOPER_ID="Developer ID Application: Ad (TAKIMID)" ./notarize.sh

notarytool için anahtar zinciri profilini bir kez oluştur (app-specific password:
appleid.apple.com › Sign-In and Security › App-Specific Passwords):
  xcrun notarytool store-credentials "claudedeck" \
      --apple-id "<apple-id-e-postan>" --team-id "V6G4B5T63L" --password "<app-specific-password>"
  (Farklı bir profil adı kullanırsan:  NOTARY_PROFILE=<ad> ./notarize.sh)

Hiçbir şey derlenmedi ve Apple'a hiçbir şey gönderilmedi.
EOF
  exit 1
fi
echo "İmza kimliği: $IDENTITY"

# The notary profile must exist before we spend time building.
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || fail "notarytool profili \"$PROFILE\" bulunamadı ya da geçersiz. Oluştur:
   xcrun notarytool store-credentials \"$PROFILE\" --apple-id \"<apple-id>\" --team-id \"<TAKIMID>\" --password \"<app-specific-password>\""

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

# 4. Zip and submit.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Notarization için gönderiliyor (profil: $PROFILE)…"
OUT=$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 2>&1) || true
echo "$OUT"
# notarytool can exit 0 for an "Invalid" result, so check the final status explicitly.
echo "$OUT" | grep -q "status: Accepted" || {
  SUB=$(echo "$OUT" | awk '/^ *id:/ {print $2; exit}')
  fail "Notarization başarısız. Ayrıntı:  xcrun notarytool log ${SUB:-<submission-id>} --keychain-profile \"$PROFILE\""
}

# 5. Staple and verify Gatekeeper acceptance.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv "$APP"

# Re-zip so the distributable carries the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✅ Notarize edildi ve zımbalandı: $APP  (dağıtım: $ZIP)"
