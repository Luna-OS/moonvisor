#!/bin/bash
# Baut Moonvisor.app (Apple Silicon) und packt sie als ZIP und DMG nach dist/.
# Aufruf: scripts/build-app.sh [version]
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
DIST="dist"
APP="$DIST/Moonvisor.app"

echo "▸ Kompiliere (release, arm64) …"
swift build -c release --arch arm64 --product Moonvisor
swift build -c release --arch arm64 --product moonctl
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

echo "▸ Erzeuge App-Bundle $VERSION ($BUILD) …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN/Moonvisor" "$APP/Contents/MacOS/Moonvisor"
cp "$BIN/moonctl" "$APP/Contents/Resources/bin/moonctl"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

ICONSET="$DIST/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "▸ Signiere (ad hoc) …"
xattr -cr "$APP"
codesign --force --sign - --options runtime "$APP/Contents/Resources/bin/moonctl"
codesign --force --sign - --options runtime "$APP"
codesign --verify --strict "$APP"

echo "▸ Packe …"
rm -f "$DIST"/Moonvisor-*.zip "$DIST"/Moonvisor-*.dmg
ditto -c -k --keepParent "$APP" "$DIST/Moonvisor-$VERSION-arm64.zip"

STAGE="$DIST/dmg"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Programme"
hdiutil create -quiet -volname "Moonvisor $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/Moonvisor-$VERSION-arm64.dmg"
rm -rf "$STAGE"

(cd "$DIST" && shasum -a 256 Moonvisor-"$VERSION"-arm64.* > SHA256SUMS.txt)
echo "✓ Fertig:"
ls -lh "$DIST"
