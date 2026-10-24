import Foundation

/// Hält Moonvisor aktuell: sucht neue Versionen auf GitHub, lädt das ZIP, prüft es gegen SHA256SUMS.txt
/// und ersetzt die App, sobald sie beendet wird. Laufende VMs laufen dabei weiter; die neue Version
/// verbindet sich wieder mit ihnen.
public enum AppUpdater {
    public struct Release: Sendable, Equatable {
        public var version: String
        public var notes: String
        public var archiveURL: URL
        public var checksumsURL: URL
        public var pageURL: URL
    }

    public enum UpdateError: LocalizedError {
        case checksumMissing
        case checksumMismatch
        case invalidApp
        case notWritable(String)

        public var errorDescription: String? {
            switch self {
            case .checksumMissing:
                return "Zum Update fehlt die Prüfsumme. Bitte später erneut versuchen."
            case .checksumMismatch:
                return "Das heruntergeladene Update ist beschädigt (Prüfsumme stimmt nicht). Bitte erneut versuchen."
            case .invalidApp:
                return "Das heruntergeladene Update ist keine gültige Moonvisor-App."
            case .notWritable(let path):
                return "Moonvisor darf sich in „\(path)“ nicht selbst ersetzen. Lade die neue Version von GitHub und ziehe sie in den Programme-Ordner."
            }
        }
    }

    static let latestURL = URL(string: "https://api.github.com/repos/\(EngineStore.repository)/releases/latest")!

    /// Version der laufenden App (`CFBundleShortVersionString`), nil bei `swift run`.
    public static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Die laufende App, falls sie sich selbst ersetzen kann: nicht aus einem DMG und nicht aus einem
    /// von macOS verschobenen Ort (App Translocation, z. B. direkt aus „Downloads“ gestartet).
    public static var installedApp: URL? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app", !url.path.contains("/AppTranslocation/"), !url.path.hasPrefix("/Volumes/") else { return nil }
        return url
    }

    public static var stagingFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moonvisor/Update", isDirectory: true)
    }

    /// Vergleicht Versionen wie „0.2.18“ Stelle für Stelle; Zusätze wie „-ci“ zählen nicht.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Prüfsumme einer Datei aus einer `shasum -a 256`-Ausgabe.
    public static func checksum(for file: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { continue }
            var name = String(fields[fields.count - 1])
            if name.hasPrefix("*") { name.removeFirst() }
            if name == file { return fields[0].lowercased() }
        }
        return nil
    }

    /// Liest die Antwort von `releases/latest`. Nil, wenn sie keine vollständige App-Version beschreibt
    /// (Engine-Releases sind Vorabversionen und erscheinen dort nicht).
    public static func parseRelease(_ data: Data) throws -> Release? {
        struct Asset: Decodable {
            var name: String
            var browserDownloadUrl: URL
        }
        struct Payload: Decodable {
            var tagName: String
            var body: String?
            var htmlUrl: URL
            var draft: Bool?
            var prerelease: Bool?
            var assets: [Asset]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(Payload.self, from: data)
        guard payload.tagName.hasPrefix("v"), payload.draft != true, payload.prerelease != true else { return nil }
        let version = String(payload.tagName.dropFirst())
        guard let archive = payload.assets.first(where: { $0.name == "Moonvisor-\(version)-arm64.zip" }),
              let sums = payload.assets.first(where: { $0.name == "SHA256SUMS.txt" }) else { return nil }
        return Release(version: version, notes: payload.body ?? "", archiveURL: archive.browserDownloadUrl,
                       checksumsURL: sums.browserDownloadUrl, pageURL: payload.htmlUrl)
    }

    /// Neueste veröffentlichte Version.
    public static func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Moonvisor/\(currentVersion ?? "0")", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw MoonError.processFailed("Update-Suche", "HTTP \(status)") }
        return try parseRelease(data)
    }

    /// Lädt das Update, prüft Prüfsumme und Signatur und gibt die entpackte App zurück.
    public static func download(_ release: Release, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        let folder = stagingFolder
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let archive = folder.appendingPathComponent(release.archiveURL.lastPathComponent)
        let (sums, response) = try await URLSession.shared.data(from: release.checksumsURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let expected = checksum(for: archive.lastPathComponent, in: String(decoding: sums, as: UTF8.self)) else {
            throw UpdateError.checksumMissing
        }
        _ = try await DriverStore.download(from: release.archiveURL, to: archive, label: "Update", progress: progress)
        defer { try? fm.removeItem(at: archive) }
        guard try EngineStore.sha256(of: archive) == expected else { throw UpdateError.checksumMismatch }

        let unpacked = folder.appendingPathComponent("neu", isDirectory: true)
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", archive.path, unpacked.path])
        guard result.status == 0 else { throw MoonError.processFailed("Entpacken", result.output) }
        let app = unpacked.appendingPathComponent("Moonvisor.app", isDirectory: true)
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleShortVersionString"] as? String == release.version,
              info?["CFBundleIdentifier"] as? String == (Bundle.main.bundleIdentifier ?? "io.github.luna-os.moonvisor"),
              try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--strict", app.path]).status == 0 else {
            throw UpdateError.invalidApp
        }
        // Wie bei der Engine: Die App selbst geladen, nie mit Quarantäne-Markierung starten.
        _ = try? ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// Übersetzt Netzwerkfehler in verständliche Hinweise.
    public static func describe(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return error.localizedDescription }
        switch ns.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "Keine Internetverbindung. Moonvisor sucht später erneut nach Updates."
        case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
            return "GitHub ist gerade nicht erreichbar. Moonvisor sucht später erneut nach Updates."
        default:
            return "Das Update konnte nicht geladen werden: \(error.localizedDescription)"
        }
    }

    /// Ersetzt `target` durch `newApp`, sobald dieser Prozess beendet ist, und öffnet die App auf Wunsch wieder.
    /// Ein kleines Shell-Skript erledigt das, denn eine laufende App kann sich nicht selbst überschreiben.
    public static func installWhenTerminated(_ newApp: URL, replacing target: URL, relaunch: Bool) throws {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path), fm.isWritableFile(atPath: target.path) else {
            throw UpdateError.notWritable(parent.path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", installScript, "moonvisor-update", "\(getpid())", newApp.path, target.path, relaunch ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Wartet bis zu einer Minute auf das Ende der App, tauscht sie aus (bei einem Fehler kommt die alte zurück)
    /// und öffnet sie wieder.
    static let installScript = """
    pid="$1"; new="$2"; target="$3"; relaunch="$4"
    i=0
    while kill -0 "$pid" 2>/dev/null; do
      i=$((i + 1)); [ "$i" -gt 600 ] && exit 1
      sleep 0.1
    done
    backup="$(dirname "$new")/Moonvisor-alt.app"
    rm -rf "$backup"
    if mv "$target" "$backup"; then
      if mv "$new" "$target"; then rm -rf "$backup"; else mv "$backup" "$target"; fi
    fi
    if [ "$relaunch" = 1 ]; then open "$target"; fi
    """
}
