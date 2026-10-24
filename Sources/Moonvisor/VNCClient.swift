import CoreGraphics
import Foundation
import MoonvisorCore

/// RFB-3.8-Client (VNC) für den lokalen Bildschirm-Socket der VM.
///
/// Unterstützt Raw, CopyRect, DesktopSize und die QEMU-Erweiterung für Scancode-Tastenereignisse,
/// damit jede Mac-Taste positionsgenau im Gast ankommt (unabhängig vom Tastaturlayout).
final class VNCClient: @unchecked Sendable {
    enum Encoding: Int32 {
        case raw = 0
        case copyRect = 1
        case desktopSize = -223
        case qemuExtendedKey = -258
        case extendedDesktopSize = -308
    }

    var onFrame: ((CGImage) -> Void)?
    var onDisconnect: ((Error?) -> Void)?

    private let path: String
    private var socket: UnixSocket?
    private let writeQueue = DispatchQueue(label: "moonvisor.vnc.write")
    private var stopped = false

    private(set) var width = 0
    private(set) var height = 0
    private var framebuffer: UnsafeMutableRawPointer?
    private var supportsExtendedKeys = false
    private(set) var supportsDesktopResize = false
    private let frameLock = NSLock()
    private var framePending = false
    /// Während ein Bild noch auf den Hauptthread wartet, kam ein neueres: danach noch einmal melden.
    private var frameDirty = false
    /// Seit der letzten Größenänderung kamen Bildpunkte. Vorher ist der Puffer nur schwarz.
    private var hasPixels = false
    /// Das zuletzt gemeldete Bild ist QEMUs Ersatzbild (der Gast gibt noch kein Bild aus).
    private(set) var lastFrameIsPlaceholder = false

    init(path: String) {
        self.path = path
    }

    deinit {
        framebuffer?.deallocate()
    }

    func start() {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "moonvisor.vnc"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        stopped = true
        socket?.shutdown()
    }

    // MARK: Empfangen

    private func run() {
        var lastError: Error?
        // Der Socket erscheint erst, wenn QEMU bereit ist; mit -loadvm erst, nachdem der Arbeitsspeicher geladen
        // ist (bei großen VMs weit über zehn Sekunden). Deshalb warten, bis die Sitzung beendet wird.
        while !stopped {
            if let s = try? UnixSocket(path: path) {
                socket = s
                break
            }
            usleep(100_000)
        }
        guard let socket, !stopped else {
            socket?.shutdown()
            return
        }
        do {
            try handshake(socket)
            try receiveLoop(socket)
        } catch {
            lastError = stopped ? nil : error
        }
        socket.shutdown()
        DispatchQueue.main.async { self.onDisconnect?(lastError) }
    }

    private func handshake(_ s: UnixSocket) throws {
        let version = try s.read(exactly: 12)
        guard String(decoding: version, as: UTF8.self).hasPrefix("RFB ") else { throw MoonError.qmp("Kein VNC-Server") }
        try s.write(Data("RFB 003.008\n".utf8))

        let count = Int(try s.read(exactly: 1)[0])
        if count == 0 {
            let len = Int(be32(try s.read(exactly: 4), 0))
            let reason = String(decoding: try s.read(exactly: len), as: UTF8.self)
            throw MoonError.qmp("VNC abgelehnt: \(reason)")
        }
        let types = try s.read(exactly: count)
        guard types.contains(1) else { throw MoonError.qmp("VNC verlangt ein Passwort") }
        try s.write(Data([1]))
        guard be32(try s.read(exactly: 4), 0) == 0 else { throw MoonError.qmp("VNC-Anmeldung fehlgeschlagen") }

        try s.write(Data([1])) // ClientInit: geteilte Sitzung
        let initHeader = try s.read(exactly: 24)
        let w = Int(be16(initHeader, 0)), h = Int(be16(initHeader, 2))
        let nameLength = Int(be32(initHeader, 20))
        _ = try s.read(exactly: nameLength)
        resize(width: w, height: h)

        // 32 Bit BGRX, little endian – passt direkt zu CGImage (byteOrder32Little + noneSkipFirst).
        var pixelFormat: [UInt8] = [0, 0, 0, 0]
        pixelFormat += [32, 24, 0, 1]
        pixelFormat += u16(255)
        pixelFormat += u16(255)
        pixelFormat += u16(255)
        pixelFormat += [16, 8, 0, 0, 0, 0]
        try s.write(Data(pixelFormat))

        let encodings: [Encoding] = [.copyRect, .raw, .extendedDesktopSize, .desktopSize, .qemuExtendedKey]
        var msg: [UInt8] = [2, 0]
        msg += u16(UInt16(encodings.count))
        for e in encodings { msg += u32(UInt32(bitPattern: e.rawValue)) }
        try s.write(Data(msg))
        requestUpdate(incremental: false)
    }

    private func receiveLoop(_ s: UnixSocket) throws {
        while !stopped {
            let type = try s.read(exactly: 1)[0]
            switch type {
            case 0:
                // Aktualisierungen nur mit Pseudo-Rechtecken (Größenänderung, Tastenbestätigung) enthalten kein Bild.
                if try readFramebufferUpdate(s) { publishFrame() }
                requestUpdate(incremental: true)
            case 1:
                let header = try s.read(exactly: 5)
                _ = try s.read(exactly: Int(be16(header, 3)) * 6)
            case 2:
                break // Klingel
            case 3:
                let header = try s.read(exactly: 7)
                _ = try s.read(exactly: Int(be32(header, 3)))
            default:
                throw MoonError.qmp("Unbekannte VNC-Nachricht \(type)")
            }
        }
    }

    /// Gibt zurück, ob die Aktualisierung Bildpunkte enthielt.
    private func readFramebufferUpdate(_ s: UnixSocket) throws -> Bool {
        let header = try s.read(exactly: 3)
        let rects = Int(be16(header, 1))
        var pixels = false
        for _ in 0..<rects {
            let r = try s.read(exactly: 12)
            let x = Int(be16(r, 0)), y = Int(be16(r, 2)), w = Int(be16(r, 4)), h = Int(be16(r, 6))
            let encoding = Int32(bitPattern: be32(r, 8))
            switch encoding {
            case Encoding.raw.rawValue:
                try readRaw(s, x: x, y: y, w: w, h: h)
                pixels = true
            case Encoding.copyRect.rawValue:
                let src = try s.read(exactly: 4)
                copyRect(fromX: Int(be16(src, 0)), fromY: Int(be16(src, 2)), x: x, y: y, w: w, h: h)
                pixels = true
            case Encoding.desktopSize.rawValue:
                resize(width: w, height: h)
            case Encoding.qemuExtendedKey.rawValue:
                supportsExtendedKeys = true
            case Encoding.extendedDesktopSize.rawValue:
                // x = Grund (0 = Server, 1 = unsere Anfrage), y = Status; danach die Bildschirmliste.
                let count = Int(try s.read(exactly: 4)[0])
                _ = try s.read(exactly: count * 16)
                supportsDesktopResize = true
                if w > 0 && h > 0 && (w != width || h != height) { resize(width: w, height: h) }
            default:
                throw MoonError.qmp("Nicht unterstützte VNC-Kodierung \(encoding)")
            }
        }
        if pixels {
            frameLock.lock()
            hasPixels = true
            frameLock.unlock()
        }
        return pixels
    }

    private func readRaw(_ s: UnixSocket, x: Int, y: Int, w: Int, h: Int) throws {
        let stride = width * 4
        frameLock.lock()
        defer { frameLock.unlock() }
        guard let fb = framebuffer, x + w <= width, y + h <= height else {
            frameLock.unlock()
            _ = try s.read(exactly: w * h * 4)
            frameLock.lock()
            return
        }
        if x == 0 && w == width {
            try s.read(into: fb.advanced(by: y * stride), count: w * h * 4)
        } else {
            for row in 0..<h {
                try s.read(into: fb.advanced(by: (y + row) * stride + x * 4), count: w * 4)
            }
        }
    }

    private func copyRect(fromX: Int, fromY: Int, x: Int, y: Int, w: Int, h: Int) {
        frameLock.lock()
        defer { frameLock.unlock() }
        guard let fb = framebuffer else { return }
        let stride = width * 4
        let rows = fromY < y ? Array((0..<h).reversed()) : Array(0..<h)
        for row in rows {
            memmove(fb.advanced(by: (y + row) * stride + x * 4), fb.advanced(by: (fromY + row) * stride + fromX * 4), w * 4)
        }
    }

    private func resize(width w: Int, height h: Int) {
        frameLock.lock()
        defer { frameLock.unlock() }
        framebuffer?.deallocate()
        width = w
        height = h
        framebuffer = UnsafeMutableRawPointer.allocate(byteCount: max(1, w * h * 4), alignment: 16)
        memset(framebuffer!, 0, max(1, w * h * 4))
        hasPixels = false
    }

    /// Erstellt ein Bild vom aktuellen Framebuffer. Nicht abgeholte Bilder werden zusammengefasst.
    private func publishFrame() {
        frameLock.lock()
        if framePending {
            frameDirty = true
            frameLock.unlock()
            return
        }
        guard let fb = framebuffer, width > 0, height > 0, hasPixels else {
            frameLock.unlock()
            return
        }
        let data = Data(bytes: fb, count: width * height * 4)
        let w = width, h = height
        let placeholder = DisplayPlaceholder.matches(fb, width: w, height: h, bytesPerRow: w * 4)
        framePending = true
        frameLock.unlock()

        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else {
            frameLock.lock()
            framePending = false
            frameLock.unlock()
            return
        }
        DispatchQueue.main.async {
            self.frameLock.lock()
            self.framePending = false
            let newer = self.frameDirty
            self.frameDirty = false
            self.frameLock.unlock()
            self.lastFrameIsPlaceholder = placeholder
            self.onFrame?(image)
            // Das neueste Bild nicht verlieren: QEMU schickt erst wieder etwas, wenn sich der Inhalt ändert.
            if newer { DispatchQueue.global(qos: .userInteractive).async { self.publishFrame() } }
        }
    }

    // MARK: Senden

    private func send(_ bytes: [UInt8]) {
        writeQueue.async { [weak self] in
            try? self?.socket?.write(Data(bytes))
        }
    }

    func requestUpdate(incremental: Bool) {
        let w = UInt16(clamping: width), h = UInt16(clamping: height)
        var msg: [UInt8] = [3, incremental ? 1 : 0]
        msg += u16(0)
        msg += u16(0)
        msg += u16(w)
        msg += u16(h)
        send(msg)
    }

    /// Taste per XT-Scancode (Set 1). Erweiterte Tasten (0xE0-Präfix) werden mit gesetztem Bit 7 kodiert.
    func sendKey(scancode: UInt32, down: Bool) {
        var msg: [UInt8] = [255, 0]
        msg += u16(down ? 1 : 0)
        msg += u32(0)
        msg += u32(scancode)
        send(msg)
    }

    var canSendScancodes: Bool { supportsExtendedKeys }

    /// Bittet den Gast um eine neue Auflösung (z. B. nach dem Vergrößern des Fensters).
    func requestDesktopSize(width w: Int, height h: Int) {
        guard supportsDesktopResize, w >= 640, h >= 480 else { return }
        let ww = UInt16(clamping: w & ~7), hh = UInt16(clamping: h)
        // SetDesktopSize: Größe, ein Bildschirm (ID 0) an Position 0/0 mit derselben Größe.
        var msg: [UInt8] = [251, 0]
        msg += u16(ww)
        msg += u16(hh)
        msg += [1, 0]
        msg += u32(0)
        msg += u16(0)
        msg += u16(0)
        msg += u16(ww)
        msg += u16(hh)
        msg += u32(0)
        send(msg)
    }

    func sendPointer(x: Int, y: Int, buttons: UInt8) {
        let px = UInt16(clamping: max(0, min(x, width - 1)))
        let py = UInt16(clamping: max(0, min(y, height - 1)))
        var msg: [UInt8] = [5, buttons]
        msg += u16(px)
        msg += u16(py)
        send(msg)
    }
}

@inline(__always) private func be16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) << 8 | UInt16(b[o + 1]) }
@inline(__always) private func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
}
@inline(__always) private func u16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
@inline(__always) private func u32(_ v: UInt32) -> [UInt8] {
    [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
}
