import Foundation

public enum MoonError: LocalizedError {
    case processFailed(String, String)
    case notRunning
    case alreadyRunning
    case invalidBundle(String)
    case qmp(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .processFailed(let tool, let output):
            let tail = output.split(separator: "\n").suffix(6).joined(separator: "\n")
            return "\(tool) ist fehlgeschlagen:\n\(tail)"
        case .notRunning: return "Die VM läuft nicht."
        case .alreadyRunning: return "Die VM läuft bereits."
        case .invalidBundle(let path): return "Keine gültige Moonvisor-VM: \(path)"
        case .qmp(let message): return "VM-Steuerung: \(message)"
        case .timeout(let what): return "Zeitüberschreitung: \(what)"
        }
    }
}

public enum ProcessRunner {
    public struct Result: Sendable {
        public var status: Int32
        public var output: String
    }

    /// Führt ein Programm aus und sammelt stdout und stderr.
    @discardableResult
    public static func run(_ executable: URL, _ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

/// Größe einer Datei, die tatsächlich auf der Festplatte belegt ist (qcow2 ist dünn belegt).
public func allocatedSize(of url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
    return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
}

public func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
