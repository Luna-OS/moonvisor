#!/bin/bash
# Baut Moonvisor.app (Apple Silicon) und packt sie als ZIP und DMG nach dist/.
# Aufruf: scripts/build-app.sh [version]
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
DIST="$(pwd)/dist"
# Bundle außerhalb von iCloud-synchronisierten Ordnern bauen: iCloud hängt Datei-Attribute an,
# die die Signaturprüfung scheitern lassen („App ist beschädigt“).
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Moonvisor.app"
mkdir -p "$DIST"

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

ICONSET="$WORK/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "▸ Signiere (ad hoc) …"
xattr -cr "$APP"
codesign --force --sign - "$APP/Contents/Resources/bin/moonctl"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

# hdiutil scheitert auf den macOS-Runnern von GitHub gelegentlich mit „Resource busy“: kurz warten, neu versuchen.
hdiutil_retry() {
  local attempt
  for attempt in 1 2 3 4 5; do
    hdiutil "$@" && return 0
    echo "hdiutil $1 fehlgeschlagen (Versuch $attempt von 5)" >&2
    [ "$attempt" -lt 5 ] && sleep $((attempt * 5))
  done
  return 1
}

echo "▸ Packe …"
rm -f "$DIST"/Moonvisor-*.zip "$DIST"/Moonvisor-*.dmg
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$DIST/Moonvisor-$VERSION-arm64.zip"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto --norsrc --noextattr "$APP" "$STAGE/Moonvisor.app"
ln -s /Applications "$STAGE/Programme"
hdiutil_retry create -volname "Moonvisor $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DIST/Moonvisor-$VERSION-arm64.dmg"

# Gegenprobe: App im fertigen DMG muss strikt gültig signiert sein.
MOUNT="$(hdiutil_retry attach -readonly -nobrowse "$DIST/Moonvisor-$VERSION-arm64.dmg" | tail -1 | awk -F'\t' '{print $NF}')"
test -d "$MOUNT/Moonvisor.app"
codesign --verify --strict "$MOUNT/Moonvisor.app"
hdiutil_retry detach -quiet "$MOUNT"

rm -rf "$DIST/Moonvisor.app"
ditto "$APP" "$DIST/Moonvisor.app"
(cd "$DIST" && shasum -a 256 Moonvisor-"$VERSION"-arm64.* > SHA256SUMS.txt)
echo "✓ Fertig:"
ls -lh "$DIST"
