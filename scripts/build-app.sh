#!/usr/bin/env bash
# Builds build/Moonvisor.app (and with --dmg also build/Moonvisor-<version>.dmg).
#   VERSION        marketing version, default 0.0.0-dev
#   BUILD_NUMBER   CFBundleVersion, default 1
#   SIGN_IDENTITY  codesign identity, default "-" (ad-hoc)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0-dev}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP=build/Moonvisor.app

swift build -c release --arch arm64
BIN_DIR=$(swift build -c release --arch arm64 --show-bin-path)

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Moonvisor" "$APP/Contents/MacOS/Moonvisor"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"

ICON_DIR=build/icon
mkdir -p "$ICON_DIR/AppIcon.iconset"
swift scripts/make-icon.swift "$ICON_DIR/icon_1024.png"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$ICON_DIR/icon_1024.png" --out "$ICON_DIR/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" "$ICON_DIR/icon_1024.png" --out "$ICON_DIR/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --entitlements Resources/Moonvisor.entitlements)
if [[ "$SIGN_IDENTITY" != "-" ]]; then SIGN_ARGS+=(--options runtime --timestamp); fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --verbose "$APP"
echo "Built $APP ($VERSION)"

if [[ "${1:-}" == "--dmg" ]]; then
  STAGING=build/dmg
  mkdir -p "$STAGING"
  cp -R "$APP" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"
  hdiutil create -volname Moonvisor -srcfolder "$STAGING" -ov -format UDZO "build/Moonvisor-$VERSION.dmg"
  echo "Built build/Moonvisor-$VERSION.dmg"
fi
