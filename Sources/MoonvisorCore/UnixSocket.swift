import Foundation

/// Minimaler blockierender Unix-Domain-Socket.
public final class UnixSocket: @unchecked Sendable {
    public let fd: Int32
    private var closed = false
    private let lock = NSLock()

    public init(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MoonError.qmp("socket() fehlgeschlagen") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else {
            close(fd)
            throw MoonError.qmp("Socket-Pfad zu lang: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard result == 0 else {
            close(fd)
            throw MoonError.qmp("Verbindung zu \(path) fehlgeschlagen (\(String(cString: strerror(errno))))")
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        self.fd = fd
    }

    deinit { shutdown() }

    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    public func setReadTimeout(seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw MoonError.qmp("Schreiben fehlgeschlagen")
                }
                offset += n
            }
        }
    }

    /// Liest genau `count` Bytes oder wirft am Verbindungsende.
    public func read(exactly count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
            if n == 0 { throw MoonError.qmp("Verbindung geschlossen") }
            if n < 0 {
                if errno == EINTR { continue }
                throw MoonError.qmp("Lesen fehlgeschlagen (\(String(cString: strerror(errno))))")
            }
            offset += n
        }
        return buffer
    }

    /// Liest direkt in einen vorhandenen Speicherbereich.
    public func read(into pointer: UnsafeMutableRawPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let n = Darwin.read(fd, pointer.advanced(by: offset), count - offset)
            if n == 0 { throw MoonError.qmp("Verbindung geschlossen") }
            if n < 0 {
                if errno == EINTR { continue }
                throw MoonError.qmp("Lesen fehlgeschlagen")
            }
            offset += n
        }
    }

    private var lineBuffer: [UInt8] = []

    /// Bereits durchsuchter Anfang des Puffers (lange Zeilen, z. B. Dateiübertragungen, nicht immer neu durchsuchen).
    private var scanned = 0

    public func readLine() throws -> String {
        while true {
            if let nl = lineBuffer[scanned...].firstIndex(of: 0x0A) {
                let line = Array(lineBuffer[..<nl])
                lineBuffer.removeSubrange(...nl)
                scanned = 0
                return String(decoding: line, as: UTF8.self)
            }
            scanned = lineBuffer.count
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, 65536) }
            if n == 0 { throw MoonError.qmp("Verbindung geschlossen") }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { throw MoonError.timeout("Antwort der VM") }
                throw MoonError.qmp("Lesen fehlgeschlagen")
            }
            lineBuffer.append(contentsOf: chunk[..<n])
        }
    }
}

/// QEMU Machine Protocol: JSON-Befehle zur Steuerung der laufenden VM.
public final class QMPClient: @unchecked Sendable {
    private let socket: UnixSocket
    private let lock = NSLock()

    public init(path: String, timeout: Double = 10) throws {
        socket = try UnixSocket(path: path)
        socket.setReadTimeout(seconds: timeout)
        _ = try socket.readLine() // Begrüßung
        _ = try execute("qmp_capabilities")
    }

    public func close() { socket.shutdown() }

    @discardableResult
    public func execute(_ command: String, _ arguments: [String: Any]? = nil) throws -> Any? {
        lock.lock()
        defer { lock.unlock() }
        var payload: [String: Any] = ["execute": command]
        if let arguments { payload["arguments"] = arguments }
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        try socket.write(data)
        while true {
            let line = try socket.readLine()
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let error = object["error"] as? [String: Any] {
                throw MoonError.qmp(error["desc"] as? String ?? "Unbekannter Fehler")
            }
            if object.keys.contains("return") { return object["return"] }
            // Ereignisse (SHUTDOWN, RESET …) überspringen; den Zustand fragt der Runner separat ab.
        }
    }

    public func status() throws -> String {
        let result = try execute("query-status") as? [String: Any]
        return result?["status"] as? String ?? "unknown"
    }

    public func sendKeys(_ qcodes: [String], holdMillis: Int = 100) throws {
        let keys = qcodes.map { ["type": "qcode", "data": $0] }
        try execute("send-key", ["keys": keys, "hold-time": holdMillis])
    }

    public func screendump(to url: URL) throws {
        try execute("screendump", ["filename": url.path, "format": "png"])
    }
}
