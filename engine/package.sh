#!/bin/bash
# Packt die Moonvisor-Engine aus einem fertigen UTM-Sysroot (scripts/build_dependencies.sh -p macos -a arm64).
#
# Aufbau der Engine:
#   bin/qemu-system-aarch64, bin/qemu-img, bin/swtpm   kleine Startprogramme (engine/launcher.c)
#   Frameworks/                                        QEMU, swtpm, virglrenderer, ANGLE, DXMT … als Frameworks
#   libexec/                                           virgl_render_server, socket_vmnet
#   share/qemu/                                        UEFI-Firmware und Option-ROMs
#
# Aufruf: engine/package.sh <sysroot> <socket_vmnet-ordner> <ausgabeordner> <version>
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SYSROOT="$(cd "$1" && pwd)"
VMNET="$(cd "$2" && pwd)"
OUT="$3"
VERSION="$4"
NAME="moonvisor-engine-$VERSION-arm64"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
STAGE="$OUT/$NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/libexec" "$STAGE/share/qemu"

echo "▸ Frameworks"
rsync -a "$SYSROOT/Frameworks/" "$STAGE/Frameworks/"

echo "▸ Firmware und ROMs"
# Firmware anderer Architekturen wird nicht gebraucht und macht den Großteil der Größe aus.
rsync -a \
    --exclude 'edk2-x86_64-*' --exclude 'edk2-i386-*' --exclude 'edk2-riscv*' --exclude 'edk2-loongarch64-*' \
    --exclude 'firmware/*x86_64*' --exclude 'firmware/*i386*' --exclude 'firmware/*riscv*' --exclude 'firmware/*loongarch*' \
    "$SYSROOT/share/qemu/" "$STAGE/share/qemu/"
for required in edk2-aarch64-code.fd edk2-arm-vars.fd efi-virtio.rom; do
    [ -f "$STAGE/share/qemu/$required" ] || { echo "✗ share/qemu/$required fehlt" >&2; exit 1; }
done

echo "▸ Hilfsprogramme"
if [ -d "$SYSROOT/libexec" ]; then
    find "$SYSROOT/libexec" -maxdepth 1 -type f -perm +111 -exec cp {} "$STAGE/libexec/" \;
fi
cp "$VMNET/socket_vmnet" "$STAGE/libexec/socket_vmnet"
for tool in "$STAGE"/libexec/*; do
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$tool" 2>/dev/null || true
done

framework_named () {
    local pattern="$1"
    local found
    found="$(cd "$STAGE/Frameworks" && ls -d *.framework | sed 's/\.framework$//' | grep -E "$pattern" | head -1)"
    if [ -z "$found" ]; then
        echo "✗ Kein Framework passt zu '$pattern'. Vorhanden:" >&2
        ls "$STAGE/Frameworks" >&2
        exit 1
    fi
    echo "$found"
}

echo "▸ Startprogramme"
build_launcher () {
    local tool="$1" framework="$2"
    echo "  $tool → $framework.framework"
    clang -O2 -arch arm64 -mmacosx-version-min=12.0 \
        -DENGINE_FRAMEWORK="\"$framework\"" \
        -Wl,-rpath,@executable_path/../Frameworks \
        "$HERE/launcher.c" -o "$STAGE/bin/$tool"
}
# Erst zuweisen: so bricht `set -e` ab, wenn ein Framework fehlt.
QEMU_FW="$(framework_named '^qemu-aarch64-softmmu$')"
IMG_FW="$(framework_named '^qemu-img$')"
SWTPM_FW="$(framework_named '^swtpm')"
build_launcher qemu-system-aarch64 "$QEMU_FW"
build_launcher qemu-img "$IMG_FW"
build_launcher swtpm "$SWTPM_FW"

echo "▸ Prüfe Abhängigkeiten"
bad=0
while IFS= read -r -d '' file; do
    if file -b "$file" | grep -q 'Mach-O'; then
        if otool -L "$file" | tail -n +2 | awk '{print $1}' | grep -E "^($SYSROOT|/opt/homebrew|/usr/local)" ; then
            echo "✗ $file verweist auf einen Pfad außerhalb der Engine" >&2
            bad=1
        fi
    fi
done < <(find "$STAGE" -type f -print0)
[ "$bad" -eq 0 ] || exit 1

echo "▸ Signiere (ad hoc)"
xattr -cr "$STAGE"
find "$STAGE/Frameworks" -maxdepth 1 -name '*.framework' -print0 | while IFS= read -r -d '' fw; do
    codesign --force --sign - --timestamp=none "$fw"
done
for tool in "$STAGE"/libexec/*; do
    codesign --force --sign - --timestamp=none "$tool"
done
for tool in "$STAGE"/bin/*; do
    codesign --force --sign - --timestamp=none --entitlements "$HERE/hypervisor.entitlements" "$tool"
done

echo "▸ Packe"
ARCHIVE="$OUT/$NAME.tar.xz"
rm -f "$ARCHIVE"
tar -C "$OUT" -cf - "$NAME" | xz -T0 -6 > "$ARCHIVE"
SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
SIZE="$(stat -f %z "$ARCHIVE")"
UNPACKED="$(du -sk "$STAGE" | awk '{print $1 * 1024}')"
DIRECTX=false
[ -d "$STAGE/Frameworks/dxmt-native.framework" ] && DIRECTX=true
cat > "$OUT/engine-manifest.json" <<EOF
{
  "version": "$VERSION",
  "archive": "$NAME.tar.xz",
  "folder": "$NAME",
  "sha256": "$SHA",
  "size": $SIZE,
  "unpackedSize": $UNPACKED,
  "directX": $DIRECTX
}
EOF
cat "$OUT/engine-manifest.json"
echo "✓ $ARCHIVE"
