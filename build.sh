#!/usr/bin/env bash
# Builds KnockSense.app into ./build
#   ./build.sh            build only
#   ./build.sh --run      build and launch
#   ./build.sh --install  build, copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="KnockSense"
APP="build/${APP_NAME}.app"

if ! command -v swift >/dev/null 2>&1; then
  echo "ERROR: Swift not found. Install Xcode or run: xcode-select --install" >&2
  exit 1
fi

echo "==> Compiling (release)..."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> Assembling ${APP}..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_DIR}/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
mkdir -p "${APP}/Contents/Helpers"
cp "${BIN_DIR}/KnockSenseIMU" "${APP}/Contents/Helpers/knocksense-imu"
cp Resources/com.knocksense.imu.plist "${APP}/Contents/Resources/"
cp Resources/Info.plist "${APP}/Contents/Info.plist"
# CI passes the build number so the in-app updater can tell versions apart (local builds stay 0).
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${APP}/Contents/Info.plist"
fi

# App icon: build AppIcon.icns from Resources/AppIcon.png (1024x1024) if present.
if [[ -f Resources/AppIcon.png ]]; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "${ICONSET}" && mkdir -p "${ICONSET}"
  for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
    sips -z $((size*2)) $((size*2)) Resources/AppIcon.png --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "${ICONSET}" -o "${APP}/Contents/Resources/AppIcon.icns"
  rm -rf "${ICONSET}"
fi

# Ad-hoc signature (or your Developer ID: SIGN_IDENTITY="Developer ID Application: ........." ./build.sh)
if [[ -z "${SIGN_IDENTITY:-}" || "${SIGN_IDENTITY}" == "-" ]]; then
  # Ad-hoc signing normally ties macOS permissions (microphone, accessibility) to this exact build,
  # so every update would silently lose them. A designated requirement based on the bundle
  # identifier keeps the app's identity stable across builds, so permissions survive updates.
  codesign --force --sign - --identifier com.knocksense.imu \
    -r='designated => identifier "com.knocksense.imu"' "${APP}/Contents/Helpers/knocksense-imu"
  codesign --force --sign - -r='designated => identifier "com.knocksense.app"' "${APP}"
else
  codesign --force --sign "${SIGN_IDENTITY}" "${APP}/Contents/Helpers/knocksense-imu"
  codesign --force --sign "${SIGN_IDENTITY}" "${APP}"
fi
codesign -d -r- "${APP}" 2>&1 | grep designated || true
# Fail the build if either signature doesn't satisfy its own requirement.
codesign --verify --strict --verbose=1 "${APP}/Contents/Helpers/knocksense-imu"
codesign --verify --deep --strict --verbose=1 "${APP}"
echo "==> Built ${APP}"

case "${1:-}" in
  --run)
    open "${APP}" ;;
  --install)
    pkill -x "${APP_NAME}" 2>/dev/null || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "${APP}" /Applications/
    echo "==> Installed to /Applications/${APP_NAME}.app"
    open "/Applications/${APP_NAME}.app" ;;
esac
