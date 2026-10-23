import CryptoKit
import Foundation

/// Lädt die Moonvisor-Engine (QEMU, swtpm, Firmware, 3D-Bausteine) direkt in der App herunter –
/// ohne Homebrew und ohne Terminal. Die Engine wird in CI aus den Quellen gebaut (`engine/`) und als
/// Release `engine-<version>` veröffentlicht. Das Manifest daneben enthält die SHA-256-Prüfsumme.
public enum EngineStore {
    /// Engine-Version, zu der diese App passt.
    /// Muss zu engine/VERSION passen (geprüft im Test).
    public static let requiredVersion = "2"
    public static let repository = "Luna-OS/moonvisor"

    public static var releaseURL: URL {
        URL(string: "https://github.com/\(repository)/releases/download/engine-\(requiredVersion)/")!
    }

    public struct Manifest: Codable, Sendable {
        public var version: String
        public var archive: String
        public var folder: String
        public var sha256: String
        public var size: Int64
        public var unpackedSize: Int64
        public var directX: Bool
    }

    public enum Phase: Sendable, Equatable {
        case checking
        case downloading(Double)
        case verifying
        case unpacking
        case done
    }

    public enum EngineError: LocalizedError {
        case notEnoughSpace(Int64)
        case checksumMismatch
        case incomplete

        public var errorDescription: String? {
            switch self {
            case .notEnoughSpace(let needed):
                return "Nicht genug freier Speicher für die Engine. Benötigt werden etwa \(formatBytes(needed))."
            case .checksumMismatch:
                return "Die heruntergeladene Engine ist beschädigt (Prüfsumme stimmt nicht). Bitte erneut versuchen."
            case .incomplete:
                return "Die Engine ist unvollständig. Bitte erneut herunterladen."
            }
        }
    }

    public static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moonvisor/Engine", isDirectory: true)
    }

    static var versionFolder: URL { folder.appendingPathComponent(requiredVersion, isDirectory: true) }
    static var markerURL: URL { versionFolder.appendingPathComponent(".installed") }

    /// Ordner der installierten Engine (mit `bin/`, `Frameworks/`, `share/`), falls vollständig vorhanden.
    public static var installedURL: URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: markerURL.path),
              fm.isExecutableFile(atPath: versionFolder.appendingPathComponent("bin/qemu-system-aarch64").path) else { return nil }
        return versionFolder
    }

    /// Kann die installierte Engine DirectX (Triton/Neptune über DXMT)?
    public static var supportsDirectX: Bool {
        guard let url = installedURL else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("Frameworks/dxmt-native.framework").path)
    }

    public static func fetchManifest() async throws -> Manifest {
        let url = releaseURL.appendingPathComponent("engine-manifest.json")
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw MoonError.processFailed("Engine-Download", "HTTP \(status) für \(url.lastPathComponent)") }
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Lädt, prüft und entpackt die Engine. Ältere Engine-Versionen werden danach entfernt.
    @discardableResult
    public static func install(progress: @escaping @Sendable (Phase) -> Void) async throws -> URL {
        if let installed = installedURL { return installed }
        let fm = FileManager.default
        progress(.checking)
        let manifest = try await fetchManifest()

        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        let needed = manifest.size + manifest.unpackedSize
        if free < needed { throw EngineError.notEnoughSpace(needed) }

        let archive = folder.appendingPathComponent(manifest.archive)
        defer { try? fm.removeItem(at: archive) }
        _ = try await DriverStore.download(from: releaseURL.appendingPathComponent(manifest.archive), to: archive,
                                           label: "Engine-Download") { progress(.downloading($0)) }

        progress(.verifying)
        guard try sha256(of: archive) == manifest.sha256.lowercased() else { throw EngineError.checksumMismatch }

        progress(.unpacking)
        let staging = folder.appendingPathComponent(".entpacken-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xf", archive.path, "-C", staging.path])
        guard result.status == 0 else { throw MoonError.processFailed("Entpacken", result.output) }
        let unpacked = staging.appendingPathComponent(manifest.folder, isDirectory: true)
        guard fm.isExecutableFile(atPath: unpacked.appendingPathComponent("bin/qemu-system-aarch64").path) else {
            throw EngineError.incomplete
        }
        // Heruntergeladene Dateien nie mit Quarantäne-Markierung starten.
        _ = try? ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", unpacked.path])

        try? fm.removeItem(at: versionFolder)
        try fm.moveItem(at: unpacked, to: versionFolder)
        try Data(manifest.sha256.utf8).write(to: markerURL)
        removeOtherVersions()
        progress(.done)
        return versionFolder
    }

    static func removeOtherVersions() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent != requiredVersion && !item.lastPathComponent.hasSuffix(".tar.xz") {
            try? fm.removeItem(at: item)
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Übersetzt Netzwerkfehler in verständliche Hinweise.
    public static func describe(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return error.localizedDescription }
        switch ns.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "Keine Internetverbindung. Die Engine wird einmalig heruntergeladen."
        case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
            return "GitHub ist gerade nicht erreichbar. Bitte später erneut versuchen."
        default:
            return "Die Engine konnte nicht geladen werden: \(error.localizedDescription)"
        }
    }
}
