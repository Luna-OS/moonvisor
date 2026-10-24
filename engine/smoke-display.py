#!/usr/bin/env python3
"""Prüft die Bildausgabe der Engine: Firmware über virtio-ramfb, auch wenn QEMU das Bild ständig neu abholt.

Ohne den Moonvisor-Patch für virtio-ramfb bleibt das Fenster dabei auf „Display output is not active“ stehen:
Die Firmware setzt virtio-gpu direkt nach dem Einrichten von ramfb zurück. Aufruf:
    smoke-display.py <engine-ordner> <arbeitsordner>
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import time

engine, work = sys.argv[1], sys.argv[2]
share = os.path.join(engine, "share", "qemu")
os.makedirs(work, exist_ok=True)
qmp_path = os.path.join(work, "qmp.sock")
for stale in ("qmp.sock", "vnc.sock"):
    if os.path.exists(os.path.join(work, stale)):
        os.remove(os.path.join(work, stale))
vars_path = os.path.join(work, "vars.qcow2")
shutil.copy(os.path.join(share, "edk2-arm-vars.fd"), vars_path)

qemu = subprocess.Popen([
    os.path.join(engine, "bin", "qemu-system-aarch64"), "-L", share, "-nodefaults",
    "-machine", "virt", "-accel", "tcg", "-cpu", "max", "-m", "512",
    "-drive", f"if=pflash,format=raw,readonly=on,file={share}/edk2-aarch64-code.fd",
    "-drive", f"if=pflash,format=qcow2,file={vars_path}",
    "-device", "virtio-ramfb",
    "-display", "none", "-vnc", "unix:" + os.path.join(work, "vnc.sock"),
    "-qmp", f"unix:{qmp_path},server=on,wait=off",
])


def qmp():
    for _ in range(100):
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(30)
        try:
            s.connect(qmp_path)
            break
        except OSError:
            s.close()
            time.sleep(0.1)
    else:
        sys.exit("QEMU startet nicht")
    f = s.makefile("rwb")
    f.readline()

    def cmd(name, args=None):
        msg = {"execute": name}
        if args:
            msg["arguments"] = args
        f.write(json.dumps(msg).encode() + b"\n")
        f.flush()
        while True:
            reply = json.loads(f.readline())
            if "return" in reply or "error" in reply:
                return reply

    cmd("qmp_capabilities")
    return s, cmd


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    # P6, Breite, Höhe, Maximalwert, dann RGB-Bytes.
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    return int(fields[1]), int(fields[2]), data[pos + 1:]


def is_placeholder(width, height, pixels):
    """QEMUs Ersatzbild: schwarz, eine Zeile grauer Schrift (0xAA) in der Bildmitte (wie DisplayPlaceholder)."""
    top = (height // 16 - 1) // 2 * 16
    text = 0
    for y in range(height):
        row = pixels[y * width * 3:(y + 1) * width * 3]
        if not row.strip(b"\0"):
            continue
        for x in range(width):
            p = row[x * 3:x * 3 + 3]
            if p == b"\0\0\0":
                continue
            if top <= y < top + 16 and p == b"\xaa\xaa\xaa":
                text += 1
                continue
            return False
    return text > 0


try:
    sock, cmd = qmp()
    dump = os.path.join(work, "screen.ppm")
    # Bild ständig abholen: So trifft die Bildauffrischung das Zurücksetzen durch die Firmware zuverlässig.
    deadline = time.time() + 20
    while time.time() < deadline:
        cmd("screendump", {"filename": dump})
    time.sleep(2)
    cmd("screendump", {"filename": dump})
    width, height, pixels = read_ppm(dump)
    placeholder = is_placeholder(width, height, pixels)
    print(f"Bild {width}x{height}, Ersatzbild: {'ja' if placeholder else 'nein'}")
    sock.close()
    if placeholder:
        sys.exit("virtio-ramfb zeigt kein Firmware-Bild, nur QEMUs Ersatzbild")
finally:
    qemu.kill()
