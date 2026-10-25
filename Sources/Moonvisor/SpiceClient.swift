import AppKit
import Foundation
import IOSurface
import MoonvisorCore
import Security

/// Gemeinsame Schnittstelle der Bildschirm-Clients (VNC für 2D, SPICE für DirectX).
protocol DisplayClient: AnyObject {
    var width: Int { get }
    var height: Int { get }
    func sendKey(scancode: UInt32, down: Bool)
    func sendPointer(x: Int, y: Int, buttons: UInt8)
    func requestDesktopSize(width: Int, height: Int)
    func stop()
}

extension VNCClient: DisplayClient {}

/// SPICE-Client für den DirectX-Modus.
///
/// Mit `gl=es` rendert QEMU jedes Bild (2D wie 3D) in eine IOSurface und meldet sie per
/// `GL_SCANOUT_UNIX`: über den Socket kommt das Leseende einer Pipe, in der die IOSurface-ID steht.
/// Jede neue Bildfolge kündigt `GL_DRAW` an; der Client bestätigt sofort mit `GL_DRAW_DONE` und zeigt sie.
/// Umgesetzt sind nur die Kanäle, die Moonvisor braucht: Haupt-, Bild-, Eingabe- und Mauszeigerkanal.
final class SpiceClient: @unchecked Sendable, DisplayClient {
    /// Neue Bildfläche (Main-Thread).
    var onScanout: ((IOSurfaceRef) -> Void)?
    /// Bildinhalt hat sich geändert (Main-Thread).
    var onDraw: (() -> Void)?
    /// Mauszeiger des Gasts; nil = unsichtbar (Main-Thread).
    var onCursor: ((NSCursor?) -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    /// Diagnosezeilen (beliebiger Thread), landen in `spice.log` im VM-Ordner.
    var log: ((String) -> Void)?

    private(set) var width = 0
    private(set) var height = 0

    private let path: String
    private let lock = NSLock()
    private var stopped = false
    private var channels: [SpiceChannel] = []
    private var inputs: SpiceChannel?
    private var lastButtons: UInt8 = 0
    private var unackedMotion = 0
    /// Ein `onDraw` wartet schon auf den Hauptthread.
    private var drawQueued = false
    private var cursorCache: [UInt64: NSCursor] = [:]

    init(path: String) {
        self.path = path
    }

    func start() {
        let thread = Thread { [weak self] in self?.runMain() }
        thread.name = "moonvisor.spice.main"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        let all = channels
        lock.unlock()
        all.forEach { $0.close() }
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func register(_ channel: SpiceChannel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if stopped { channel.close(); return false }
        channels.append(channel)
        return true
    }

    private func fail(_ error: Error?) {
        if let error { log?("Fehler: \(error.localizedDescription)") }
        lock.lock()
        let wasStopped = stopped
        stopped = true
        let all = channels
        lock.unlock()
        all.forEach { $0.close() }
        if !wasStopped {
            DispatchQueue.main.async { self.onDisconnect?(error) }
        }
    }

    // MARK: Kanäle

    private func runMain() {
        var main: SpiceChannel?
        // Der Socket erscheint erst, wenn QEMU bereit ist; mit -loadvm erst, nachdem der Arbeitsspeicher geladen
        // ist (bei großen VMs weit über zehn Sekunden). Deshalb warten, bis die Sitzung beendet wird.
        while !isStopped {
            if let channel = try? SpiceChannel(path: path, type: .main, connectionID: 0, channelCaps: []) {
                main = channel
                break
            }
            usleep(100_000)
        }
        guard let main, register(main) else {
            fail(isStopped ? nil : MoonError.qmp("Bildschirm (SPICE) nicht erreichbar"))
            return
        }
        do {
            while !isStopped {
                let (type, data) = try main.readMessage()
                switch type {
                case SpiceMsg.mainInit where data.count >= 16:
                    let session = le32(data, 0)
                    let mouseModes = le32(data, 8)
                    log?("Hauptkanal verbunden, Sitzung \(session), Mausmodi \(mouseModes)")
                    main.send(SpiceMsg.mainAttachChannels)
                    if mouseModes & 2 != 0 { main.send(SpiceMsg.mainMouseModeRequest, le16(2)) }
                    openChannels(session: session)
                case SpiceMsg.mainMouseMode where data.count >= 4:
                    // Absolute Mauspositionen (Client-Modus), sobald das USB-Tablet im Gast aktiv ist.
                    let supported = le16(data, 0), current = le16(data, 2)
                    if supported & 2 != 0 && current != 2 { main.send(SpiceMsg.mainMouseModeRequest, le16(2)) }
                default:
                    break
                }
            }
        } catch {
            fail(isStopped ? nil : error)
        }
    }

    private func openChannels(session: UInt32) {
        spawn("display") { [weak self] in
            guard let self else { return }
            // MONITORS_CONFIG (1), GL_SCANOUT (7)
            let channel = try SpiceChannel(path: self.path, type: .display, connectionID: session, channelCaps: [1 << 1 | 1 << 7])
            guard self.register(channel) else { return }
            self.log?("Bildkanal verbunden")
            channel.send(SpiceMsg.displayInit, [0] + le64(0) + [0] + le32(0))
            try self.runDisplay(channel)
        }
        spawn("inputs") { [weak self] in
            guard let self else { return }
            let channel = try SpiceChannel(path: self.path, type: .inputs, connectionID: session, channelCaps: [])
            guard self.register(channel) else { return }
            self.lock.lock(); self.inputs = channel; self.lock.unlock()
            while !self.isStopped {
                let (type, _) = try channel.readMessage()
                if type == SpiceMsg.inputsMotionAck {
                    self.lock.lock(); self.unackedMotion = max(0, self.unackedMotion - 4); self.lock.unlock()
                }
            }
        }
        spawn("cursor") { [weak self] in
            guard let self else { return }
            let channel = try SpiceChannel(path: self.path, type: .cursor, connectionID: session, channelCaps: [])
            guard self.register(channel) else { return }
            while !self.isStopped {
                let (type, data) = try channel.readMessage()
                self.handleCursor(type, data)
            }
        }
    }

    private func spawn(_ name: String, _ body: @escaping () throws -> Void) {
        let thread = Thread { [weak self] in
            do {
                try body()
            } catch {
                guard let self else { return }
                self.fail(self.isStopped ? nil : error)
            }
        }
        thread.name = "moonvisor.spice.\(name)"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func runDisplay(_ channel: SpiceChannel) throws {
        var seen = 0
        // Spiele im Vollbild wechseln bei jedem Bild die Fläche: nur Größenwechsel und jeden 500. Wechsel protokollieren.
        var scanouts = 0
        var loggedSize = (0, 0)
        while !isStopped {
            let (type, data) = try channel.readMessage()
            if seen < 40 {
                seen += 1
                log?("Bildkanal: Nachricht \(type), \(data.count) Bytes")
            }
            switch type {
            case SpiceMsg.displayGLScanoutUnix where data.count >= 20:
                let w = Int(le32(data, 0)), h = Int(le32(data, 4))
                guard let fd = try channel.readPassedFD() else {
                    log?("Scanout \(w)×\(h) ohne Dateideskriptor")
                    continue
                }
                defer { Darwin.close(fd) }
                guard w > 0, h > 0, let surface = Self.surface(from: fd) else {
                    log?("Scanout \(w)×\(h): IOSurface nicht lesbar")
                    continue
                }
                scanouts += 1
                if loggedSize != (w, h) || scanouts % 500 == 0 {
                    loggedSize = (w, h)
                    log?("Scanout \(w)×\(h), IOSurface \(IOSurfaceGetID(surface)) (\(scanouts) bisher)")
                }
                DispatchQueue.main.async {
                    self.width = w
                    self.height = h
                    self.onScanout?(surface)
                }
            case SpiceMsg.displayGLDraw:
                // Sofort bestätigen: Bis GL_DRAW_DONE kommt, hält QEMU die Grafik der VM an. Wartete die Bestätigung
                // auf den Hauptthread, würde jede kurze Pause der App (Fenster aufbauen, Vorschaubild) zum Hänger
                // im Spiel. Core Animation liest die IOSurface ohnehin erst beim Zusammensetzen (wie UTM).
                channel.send(SpiceMsg.displayGLDrawDone)
                lock.lock()
                let queued = drawQueued
                drawQueued = true
                lock.unlock()
                // Bilder, die schneller kommen, als der Hauptthread sie zeigt, zusammenfassen.
                if !queued {
                    DispatchQueue.main.async {
                        self.lock.lock(); self.drawQueued = false; self.lock.unlock()
                        self.onDraw?()
                    }
                }
            default:
                break
            }
        }
    }

    /// Liest die IOSurface-ID aus der Pipe. POLLHUP heißt: die Fläche gibt es nicht mehr.
    static func surface(from fd: Int32) -> IOSurfaceRef? {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, 0) >= 0, poller.revents & Int16(POLLIN | POLLHUP) == Int16(POLLIN) else { return nil }
        var id: IOSurfaceID = 0
        guard Darwin.read(fd, &id, MemoryLayout<IOSurfaceID>.size) == MemoryLayout<IOSurfaceID>.size else { return nil }
        return IOSurfaceLookup(id)
    }

    // MARK: Mauszeiger

    private func handleCursor(_ type: UInt16, _ data: [UInt8]) {
        switch type {
        case SpiceMsg.cursorInit where data.count >= 9:
            applyCursor(visible: data[8] != 0, data, at: 9)
        case SpiceMsg.cursorSet where data.count >= 5:
            applyCursor(visible: data[4] != 0, data, at: 5)
        case SpiceMsg.cursorHide:
            DispatchQueue.main.async { self.onCursor?(nil) }
        case SpiceMsg.cursorReset, SpiceMsg.cursorInvalAll:
            lock.lock(); cursorCache.removeAll(); lock.unlock()
        default:
            break
        }
    }

    private func applyCursor(visible: Bool, _ data: [UInt8], at offset: Int) {
        let cursor = visible ? parseCursor(data, at: offset) : nil
        DispatchQueue.main.async { self.onCursor?(visible ? (cursor ?? .arrow) : nil) }
    }

    /// SpiceCursor: Flags, Kopf (ID, Typ, Größe, Hotspot), danach die Bilddaten. Unterstützt ARGB-Zeiger.
    private func parseCursor(_ data: [UInt8], at offset: Int) -> NSCursor? {
        guard data.count >= offset + 2 else { return nil }
        let flags = le16(data, offset)
        guard flags & 1 == 0, data.count >= offset + 19 else { return nil } // NONE
        let unique = le64value(data, offset + 2)
        let type = data[offset + 10]
        let w = Int(le16(data, offset + 11)), h = Int(le16(data, offset + 13))
        let hotX = Int(le16(data, offset + 15)), hotY = Int(le16(data, offset + 17))
        if flags & 4 != 0 { // FROM_CACHE
            lock.lock(); defer { lock.unlock() }
            return cursorCache[unique]
        }
        let pixels = offset + 19
        guard type == 0, w > 0, h > 0, w <= 512, h <= 512, data.count >= pixels + w * h * 4 else { return nil }
        let bytes = Data(data[pixels..<(pixels + w * h * 4)])
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let cursor = NSCursor(image: NSImage(cgImage: image, size: NSSize(width: w, height: h)), hotSpot: NSPoint(x: hotX, y: hotY))
        if flags & 2 != 0 { // CACHE_ME
            lock.lock(); cursorCache[unique] = cursor; lock.unlock()
        }
        return cursor
    }

    // MARK: Eingaben

    /// Scancodes wie bei VNC (XT, erweiterte Tasten mit Bit 7). SPICE schickt sie mit 0xE0-Präfix im unteren Byte.
    func sendKey(scancode: UInt32, down: Bool) {
        let code: UInt32
        if scancode & 0x80 != 0 {
            code = 0xE0 | ((scancode & 0x7F) | (down ? 0 : 0x80)) << 8
        } else {
            code = down ? scancode : scancode | 0x80
        }
        currentInputs()?.send(down ? SpiceMsg.inputsKeyDown : SpiceMsg.inputsKeyUp, le32(code))
    }

    /// Absolute Position und Tastenzustand wie bei VNC (Bit 0 links, 1 Mitte, 2 rechts, 3/4 Rad).
    func sendPointer(x: Int, y: Int, buttons: UInt8) {
        guard let inputs = currentInputs() else { return }
        let px = UInt32(clamping: max(0, min(x, width - 1))), py = UInt32(clamping: max(0, min(y, height - 1)))
        let state = UInt16(buttons & 7)
        lock.lock()
        let previous = lastButtons
        lastButtons = buttons & 7
        let canMove = unackedMotion < 8
        if canMove { unackedMotion += 1 }
        lock.unlock()
        if canMove || previous != buttons & 7 || buttons & 0x18 != 0 {
            inputs.send(SpiceMsg.inputsMousePosition, le32(px) + le32(py) + le16(UInt16(previous)) + [0])
        }
        // Tasten: VNC-Bit → SPICE-Taste (1 links, 2 Mitte, 3 rechts).
        for (bit, button) in [(UInt8(1), UInt8(1)), (2, 2), (4, 3)] where (previous ^ buttons) & bit != 0 {
            let pressed = buttons & bit != 0
            inputs.send(pressed ? SpiceMsg.inputsMousePress : SpiceMsg.inputsMouseRelease, [button] + le16(state))
        }
        // Mausrad: Tasten 4 (hoch) und 5 (runter) kurz drücken.
        for (bit, button) in [(UInt8(8), UInt8(4)), (16, 5)] where buttons & bit != 0 {
            inputs.send(SpiceMsg.inputsMousePress, [button] + le16(state))
            inputs.send(SpiceMsg.inputsMouseRelease, [button] + le16(state))
        }
    }

    /// Die Auflösung stellen im DirectX-Modus die Moonvisor Tools ein.
    func requestDesktopSize(width: Int, height: Int) {}

    private func currentInputs() -> SpiceChannel? {
        lock.lock(); defer { lock.unlock() }
        return inputs
    }
}

/// Nachrichtentypen aus spice-protocol (enums.h).
enum SpiceMsg {
    static let setAck: UInt16 = 3
    static let ping: UInt16 = 4
    static let ackSync: UInt16 = 1
    static let ack: UInt16 = 2
    static let pong: UInt16 = 3

    static let mainInit: UInt16 = 103
    static let mainMouseMode: UInt16 = 105
    static let mainAttachChannels: UInt16 = 104
    static let mainMouseModeRequest: UInt16 = 105

    static let displayGLScanoutUnix: UInt16 = 320
    static let displayGLDraw: UInt16 = 321
    static let displayInit: UInt16 = 101
    static let displayGLDrawDone: UInt16 = 104

    static let inputsMotionAck: UInt16 = 111
    static let inputsKeyDown: UInt16 = 101
    static let inputsKeyUp: UInt16 = 102
    static let inputsMousePosition: UInt16 = 112
    static let inputsMousePress: UInt16 = 113
    static let inputsMouseRelease: UInt16 = 114

    static let cursorInit: UInt16 = 101
    static let cursorReset: UInt16 = 102
    static let cursorSet: UInt16 = 103
    static let cursorHide: UInt16 = 105
    static let cursorInvalAll: UInt16 = 108
}

enum SpiceError: LocalizedError {
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .protocolError(let message): return "SPICE: \(message)"
        }
    }
}

/// Ein SPICE-Kanal über den Unix-Socket von QEMU, mit Empfang von Dateideskriptoren (SCM_RIGHTS).
final class SpiceChannel: @unchecked Sendable {
    enum Kind: UInt8 {
        case main = 1, display = 2, inputs = 3, cursor = 4
    }

    private let fd: Int32
    private let writeLock = NSLock()
    private var receivedFDs: [Int32] = []
    private var ackWindow: UInt32 = 0
    private var ackCount: UInt32 = 0

    init(path: String, type: Kind, connectionID: UInt32, channelCaps: [UInt32]) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SpiceError.protocolError("Socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        // Ab hier schließt deinit den Socket, auch wenn init scheitert.
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw SpiceError.protocolError("Pfad zu lang") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw SpiceError.protocolError("Verbindung fehlgeschlagen") }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        try link(type: type, connectionID: connectionID, channelCaps: channelCaps)
    }

    deinit {
        if fd >= 0 { Darwin.close(fd) }
        receivedFDs.forEach { Darwin.close($0) }
    }

    func close() {
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    // MARK: Verbindungsaufbau

    private func link(type: Kind, connectionID: UInt32, channelCaps: [UInt32]) throws {
        // Gemeinsame Fähigkeiten: Wahl des Anmeldeverfahrens, SPICE-Anmeldung, kurzer Nachrichtenkopf.
        let commonCaps: UInt32 = 1 << 0 | 1 << 1 | 1 << 3
        var body = le32(connectionID) + [type.rawValue, 0] + le32(1) + le32(UInt32(channelCaps.count)) + le32(18)
        body += le32(commonCaps)
        for cap in channelCaps { body += le32(cap) }
        try write(Array("REDQ".utf8) + le32(2) + le32(2) + le32(UInt32(body.count)) + body)

        let header = try read(exactly: 16)
        guard Array(header[0..<4]) == Array("REDQ".utf8) else { throw SpiceError.protocolError("Kein SPICE-Server") }
        let reply = try read(exactly: Int(le32(header, 12)))
        guard reply.count >= 178 else { throw SpiceError.protocolError("Antwort zu kurz") }
        guard le32(reply, 0) == 0 else { throw SpiceError.protocolError("Verbindung abgelehnt (\(le32(reply, 0)))") }
        let publicKey = Array(reply[4..<166])
        let commonCount = le32(reply, 166), capsOffset = Int(le32(reply, 174))
        let serverCommon = commonCount > 0 && reply.count >= capsOffset + 4 ? le32(reply, capsOffset) : 0
        guard serverCommon & (1 << 3) != 0 else { throw SpiceError.protocolError("Server ohne kurzen Nachrichtenkopf") }
        if serverCommon & 1 != 0 { try write(le32(1)) } // SPICE-Anmeldung
        // Ohne Passwort (disable-ticketing) erwartet der Server trotzdem ein verschlüsseltes, leeres Ticket.
        try write(Self.encryptTicket(publicKey: publicKey))
        let result = le32(try read(exactly: 4), 0)
        guard result == 0 else { throw SpiceError.protocolError("Anmeldung fehlgeschlagen (\(result))") }
    }

    static func encryptTicket(publicKey spki: [UInt8]) throws -> [UInt8] {
        guard let pkcs1 = rsaPublicKey(fromSPKI: spki) else { throw SpiceError.protocolError("Unbekannter Schlüssel") }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, &error),
              let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, Data([0]) as CFData, &error) else {
            throw SpiceError.protocolError("Ticket nicht verschlüsselbar")
        }
        return [UInt8](encrypted as Data)
    }

    /// SubjectPublicKeyInfo (DER) → RSAPublicKey (PKCS#1), wie Security.framework ihn erwartet.
    static func rsaPublicKey(fromSPKI der: [UInt8]) -> [UInt8]? {
        func element(_ bytes: [UInt8], at index: Int) -> (tag: UInt8, start: Int, end: Int)? {
            guard index + 2 <= bytes.count else { return nil }
            var length = Int(bytes[index + 1]), start = index + 2
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count <= 4, start + count <= bytes.count else { return nil }
                length = bytes[start..<(start + count)].reduce(0) { $0 << 8 | Int($1) }
                start += count
            }
            guard start + length <= bytes.count else { return nil }
            return (bytes[index], start, start + length)
        }
        guard let outer = element(der, at: 0), outer.tag == 0x30,
              let algorithm = element(der, at: outer.start), algorithm.tag == 0x30,
              let bits = element(der, at: algorithm.end), bits.tag == 0x03,
              bits.end - bits.start > 1, der[bits.start] == 0 else { return nil }
        return Array(der[(bits.start + 1)..<bits.end])
    }

    // MARK: Nachrichten

    /// Liest die nächste Nachricht. Bestätigungen (ACK) und PING beantwortet der Kanal selbst.
    func readMessage() throws -> (UInt16, [UInt8]) {
        let header = try read(exactly: 6)
        let type = le16(header, 0)
        let size = Int(le32(header, 2))
        let data = size > 0 ? try read(exactly: size) : []
        switch type {
        case SpiceMsg.setAck where data.count >= 8:
            ackWindow = le32(data, 4)
            ackCount = 0
            send(SpiceMsg.ackSync, Array(data[0..<4]))
        case SpiceMsg.ping where data.count >= 12:
            send(SpiceMsg.pong, Array(data[0..<12]))
        default:
            break
        }
        if ackWindow > 0 {
            ackCount += 1
            if ackCount >= ackWindow {
                ackCount = 0
                send(SpiceMsg.ack)
            }
        }
        return (type, data)
    }

    func send(_ type: UInt16, _ payload: [UInt8] = []) {
        try? write(le16(type) + le32(UInt32(payload.count)) + payload)
    }

    /// Liest den Dateideskriptor, den der Server direkt nach einer Nachricht wie `GL_SCANOUT_UNIX` schickt:
    /// ein eigenes Byte („@“), an dem der Deskriptor hängt. Er gehört dann dem Aufrufer.
    func readPassedFD() throws -> Int32? {
        _ = try read(exactly: 1)
        return receivedFDs.isEmpty ? nil : receivedFDs.removeFirst()
    }

    private func write(_ bytes: [UInt8]) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + sent, bytes.count - sent) }
            if n < 0 {
                if errno == EINTR { continue }
                throw SpiceError.protocolError("Schreiben fehlgeschlagen")
            }
            sent += n
        }
    }

    /// Liest genau `count` Bytes und sammelt mitgeschickte Dateideskriptoren ein.
    private func read(exactly count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        var control = [UInt8](repeating: 0, count: 256)
        while got < count {
            let n = buffer.withUnsafeMutableBytes { data -> Int in
                control.withUnsafeMutableBytes { controlBytes -> Int in
                    var vector = iovec(iov_base: data.baseAddress! + got, iov_len: count - got)
                    return withUnsafeMutablePointer(to: &vector) { vectorPointer -> Int in
                        var message = msghdr()
                        message.msg_iov = vectorPointer
                        message.msg_iovlen = 1
                        message.msg_control = controlBytes.baseAddress
                        message.msg_controllen = socklen_t(controlBytes.count)
                        let received = recvmsg(fd, &message, 0)
                        if received > 0 { collectFDs(controlBytes, length: Int(message.msg_controllen)) }
                        return received
                    }
                }
            }
            if n == 0 { throw SpiceError.protocolError("Verbindung geschlossen") }
            if n < 0 {
                if errno == EINTR { continue }
                throw SpiceError.protocolError("Lesen fehlgeschlagen")
            }
            got += n
        }
        return buffer
    }

    /// cmsghdr: Länge (UInt32), Ebene (Int32), Typ (Int32), Daten auf 4 Byte ausgerichtet.
    private func collectFDs(_ control: UnsafeMutableRawBufferPointer, length: Int) {
        let headerSize = 12
        var offset = 0
        while offset + headerSize <= length {
            let cmsgLength = Int(control.load(fromByteOffset: offset, as: UInt32.self))
            let level = control.load(fromByteOffset: offset + 4, as: Int32.self)
            let type = control.load(fromByteOffset: offset + 8, as: Int32.self)
            guard cmsgLength >= headerSize, offset + cmsgLength <= length else { break }
            if level == SOL_SOCKET && type == SCM_RIGHTS {
                var position = offset + headerSize
                while position + 4 <= offset + cmsgLength {
                    receivedFDs.append(control.load(fromByteOffset: position, as: Int32.self))
                    position += 4
                }
            }
            offset += (cmsgLength + 3) & ~3
        }
    }
}

@inline(__always) private func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
@inline(__always) private func le32(_ value: UInt32) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
}
@inline(__always) private func le64(_ value: Int64) -> [UInt8] {
    let v = UInt64(bitPattern: value)
    return (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) }
}
@inline(__always) private func le16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
@inline(__always) private func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
}
@inline(__always) private func le64value(_ b: [UInt8], _ o: Int) -> UInt64 {
    (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[o + $1]) << (8 * UInt64($1)) }
}
