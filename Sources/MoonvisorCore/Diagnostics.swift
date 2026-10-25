import Foundation

/// Fasst die Protokolle einer VM zum Kopieren zusammen, damit man sie bei einem Problem in einem Rutsch weitergeben kann.
public enum Diagnostics {
    /// Die letzten `lines` Zeilen einer Textdatei; nil, wenn sie fehlt oder leer ist.
    public static func tail(of url: URL, lines: Int) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        // Große Protokolle nicht ganz lesen: Die letzten 256 KB reichen für die letzten Zeilen.
        let text = String(decoding: data.suffix(256 * 1024), as: UTF8.self)
        var rows = text.split(separator: "\n", omittingEmptySubsequences: false)
        if rows.last?.isEmpty == true { rows.removeLast() }
        return rows.suffix(lines).joined(separator: "\n")
    }

    public static func report(bundle: VMBundle, config: VMConfig, state: String, appVersion: String?) -> String {
        var parts: [String] = []
        parts.append("Moonvisor \(appVersion ?? "Entwicklungsversion") · Engine \(EngineStore.requiredVersion) · "
            + "macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(hardwareModel)")
        parts.append("VM „\(config.name)“: \(state), \(config.cpuCount) Kerne, \(config.memoryMB / 1024) GB, "
            + "Grafik \(config.graphics.rawValue), Netzwerk \(config.networkMode)")
        let files: [(String, URL, Int)] = [
            ("qemu.log", bundle.logURL, 60),
            ("spice.log", bundle.url.appendingPathComponent("spice.log"), 60),
            ("start.log", bundle.startLogURL, 30),
            ("windows-bericht.txt", bundle.windowsReportURL, 20),
        ]
        for (title, url, lines) in files {
            guard let text = tail(of: url, lines: lines) else { continue }
            parts.append("== \(title) (letzte Zeilen) ==\n\(text)")
        }
        return parts.joined(separator: "\n\n")
    }

    static var hardwareModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "Mac" }
        return String(cString: buffer)
    }
}
