#!/bin/bash
# Builds UsageMeter.app -- a menu-bar app showing Claude & Codex usage limits.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="UsageMeter"
BUNDLE_ID="com.erichermanson.usagemeter"
CONFIG="release"

echo "==> Compiling (${CONFIG})..."
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"
APP_DIR="build/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"

echo "==> Assembling ${APP_DIR} ..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"
cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"

HELPER_PATH="$(pwd)/helpers/claude-usage.mjs"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>     <string>Usage Meter</string>
    <key>CFBundleIdentifier</key>      <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>      <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>ClaudeHelperPath</key>        <string>${HELPER_PATH}</string>
    <key>NSHumanReadableCopyright</key><string>Personal use</string>
</dict>
</plist>
PLIST

# Ad-hoc codesign so macOS will run it without quarantine hassles.
codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || true

echo "Built ${APP_DIR}"
echo
echo "Run it:      open \"${APP_DIR}\""
echo "Install it:  cp -R \"${APP_DIR}\" /Applications/"
