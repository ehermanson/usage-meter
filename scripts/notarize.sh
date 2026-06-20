#!/bin/bash
# Builds, signs, notarizes, and staples UsageMeter.app, then produces a
# distributable zip (and DMG if create-dmg is installed).
#
# Prerequisites (one-time):
#   1. An Apple Developer account + a "Developer ID Application" certificate
#      installed in your login keychain.
#   2. A notarytool credential profile stored in the keychain:
#        xcrun notarytool store-credentials usage-meter-notary \
#          --apple-id "you@example.com" \
#          --team-id "TEAMID" \
#          --password "app-specific-password"   # from appleid.apple.com
#
# Usage:
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="usage-meter-notary" \
#   ./scripts/notarize.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="UsageMeter"
APP_DIR="build/${APP_NAME}.app"
ZIP_PATH="build/${APP_NAME}.zip"
NOTARY_PROFILE="${NOTARY_PROFILE:-usage-meter-notary}"

if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    echo "error: set CODESIGN_IDENTITY to your 'Developer ID Application' identity." >&2
    echo "       list candidates with: security find-identity -v -p codesigning" >&2
    exit 1
fi

# 1. Build + hardened-runtime sign (build.sh reads CODESIGN_IDENTITY).
./build.sh

# 2. Zip for submission (ditto preserves the signature + bundle structure).
echo "==> Zipping ${APP_DIR} -> ${ZIP_PATH}"
rm -f "${ZIP_PATH}"
/usr/bin/ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"

# 3. Submit to Apple and wait for the verdict.
echo "==> Submitting to notarization service (this can take a few minutes)..."
xcrun notarytool submit "${ZIP_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait

# 4. Staple the ticket so the app validates offline, then re-zip the stapled app.
echo "==> Stapling ticket..."
xcrun stapler staple "${APP_DIR}"
xcrun stapler validate "${APP_DIR}"
rm -f "${ZIP_PATH}"
/usr/bin/ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"

# 5. Optional DMG (nicer install UX) if create-dmg is available.
if command -v create-dmg >/dev/null 2>&1; then
    DMG_PATH="build/${APP_NAME}.dmg"
    echo "==> Building ${DMG_PATH}"
    rm -f "${DMG_PATH}"
    create-dmg \
        --volname "${APP_NAME}" \
        --app-drop-link 420 180 \
        --icon "${APP_NAME}.app" 140 180 \
        --window-size 600 360 \
        "${DMG_PATH}" "${APP_DIR}" >/dev/null
    xcrun stapler staple "${DMG_PATH}" || true
    echo "==> ${DMG_PATH} ready"
else
    echo "==> (install create-dmg for a DMG: brew install create-dmg)"
fi

echo
echo "Notarized & stapled: ${APP_DIR}"
echo "Distributable:       ${ZIP_PATH}"
