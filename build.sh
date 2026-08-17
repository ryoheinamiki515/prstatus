#!/bin/bash
# Assembles PRStatus.app by hand: no Xcode on this machine, so there is no xcodebuild
# to produce a bundle from a SwiftPM package.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="PRStatus"
BUNDLE_ID="ai.outtake.prstatus"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
BUILD_APP=".build/${APP_NAME}.app"
INSTALLED_APP="${INSTALL_DIR}/${APP_NAME}.app"

echo "==> Tests"
swift build --product SelfTest
./.build/debug/SelfTest

echo "==> Release build"
swift build -c release --product "${APP_NAME}"

echo "==> Assembling bundle"
rm -rf "${BUILD_APP}"
mkdir -p "${BUILD_APP}/Contents/MacOS" "${BUILD_APP}/Contents/Resources"
cp ".build/release/${APP_NAME}" "${BUILD_APP}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${BUILD_APP}/Contents/Info.plist"
printf 'APPL????' > "${BUILD_APP}/Contents/PkgInfo"

# Ad-hoc signature. Required for a locally built bundle to launch on Apple Silicon;
# it is not a Developer ID, so SMAppService may still refuse to register (LaunchAtLogin
# falls back to a LaunchAgent in that case).
echo "==> Signing (ad-hoc)"
codesign --force --sign - --identifier "${BUNDLE_ID}" \
  --options runtime --timestamp=none "${BUILD_APP}"
codesign --verify --verbose=1 "${BUILD_APP}"

echo "==> Installing to ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
# The running copy holds its executable open, so quit before replacing it.
if pgrep -x "${APP_NAME}" > /dev/null; then
  echo "    stopping running instance"
  osascript -e "tell application id \"${BUNDLE_ID}\" to quit" 2>/dev/null || pkill -x "${APP_NAME}" || true
  sleep 1
fi
rm -rf "${INSTALLED_APP}"
cp -R "${BUILD_APP}" "${INSTALLED_APP}"

echo
echo "Installed: ${INSTALLED_APP}"
echo "Launch:    open \"${INSTALLED_APP}\""
