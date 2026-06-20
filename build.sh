#!/bin/bash
# Builds UsageMeter.app — a menu-bar app showing Claude, Codex & Gemini usage.
#
# The resulting .app is self-contained: the Claude Node helper and its
# node_modules are copied inside Contents/Resources/helpers, so the bundle keeps
# working when moved or installed to /Applications (it still needs Node.js, the
# codex CLI, and the relevant sign-ins present on the machine to read usage).
#
# Signing:
#   - default: ad-hoc (`-`), fine for running locally;
#   - set CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" to produce a
#     hardened-runtime, Developer ID-signed bundle ready for notarization
#     (see scripts/notarize.sh).
#
# Version: derived from the latest git tag (e.g. v1.2.0 -> 1.2.0) unless VERSION
# is set; build number from the commit count unless BUILD_NUMBER is set.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="UsageMeter"
BUNDLE_ID="com.erichermanson.usagemeter"
CONFIG="release"
ENTITLEMENTS="UsageMeter.entitlements"

# --- Version -----------------------------------------------------------------
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

echo "==> Compiling ${APP_NAME} ${VERSION} (build ${BUILD_NUMBER}, ${CONFIG})..."
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"
APP_DIR="build/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"
BIN_DIR="$(dirname "${BIN_PATH}")"
ICON_FILE="Sources/UsageMeter/Resources/UsageMeter.icns"

echo "==> Assembling ${APP_DIR} ..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"
cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"

if [ -f "${ICON_FILE}" ]; then
    cp "${ICON_FILE}" "${RES_DIR}/${APP_NAME}.icns"
fi

# Bundle the SwiftPM resource bundle (brand logos, etc.) so Bundle.module resolves.
for bundle in "${BIN_DIR}"/*.bundle; do
    [ -e "${bundle}" ] && cp -R "${bundle}" "${RES_DIR}/"
done

# --- Bundle the Claude Node helper (self-contained) --------------------------
echo "==> Bundling Claude helper + node_modules ..."
if [ ! -d "helpers/node_modules" ]; then
    echo "    installing helper dependencies (npm ci)..."
    (cd helpers && npm ci --omit=dev)
fi
HELPER_DEST="${RES_DIR}/helpers"
mkdir -p "${HELPER_DEST}"
cp helpers/claude-usage.mjs helpers/package.json "${HELPER_DEST}/"
[ -f helpers/package-lock.json ] && cp helpers/package-lock.json "${HELPER_DEST}/"
# -c uses clonefile on APFS, so copying node_modules is cheap.
cp -Rc helpers/node_modules "${HELPER_DEST}/node_modules"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>     <string>Usage Meter</string>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>      <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>        <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>         <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Eric Hermanson. MIT License.</string>
</dict>
</plist>
PLIST

# --- Code signing ------------------------------------------------------------
IDENTITY="${CODESIGN_IDENTITY:--}"
if [ "${IDENTITY}" = "-" ]; then
    echo "==> Ad-hoc signing (set CODESIGN_IDENTITY for a Developer ID build)..."
    codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || true
else
    echo "==> Signing with hardened runtime: ${IDENTITY}"
    # Sign inner Mach-O first (helper native modules, nested code), then the app,
    # all with the hardened runtime that notarization requires.
    SIGN_ARGS=(--force --options runtime --timestamp --sign "${IDENTITY}")
    [ -f "${ENTITLEMENTS}" ] && SIGN_ARGS+=(--entitlements "${ENTITLEMENTS}")
    # Native node addons, if any, must be signed individually.
    while IFS= read -r -d '' macho; do
        codesign "${SIGN_ARGS[@]}" "${macho}"
    done < <(find "${HELPER_DEST}" -name '*.node' -type f -print0)
    codesign "${SIGN_ARGS[@]}" "${APP_DIR}"
    echo "==> Verifying signature..."
    codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
fi

echo "Built ${APP_DIR} (v${VERSION}, build ${BUILD_NUMBER})"
echo
echo "Run it:      open \"${APP_DIR}\""
echo "Install it:  cp -R \"${APP_DIR}\" /Applications/"
