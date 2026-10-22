import Foundation

public enum ToolchainError: LocalizedError {
    case missing([String])

    public var errorDescription: String? {
        switch self {
        case .missing(let items):
            return "Die Virtualisierungs-Engine ist nicht vollständig (\(items.joined(separator: ", ")) fehlt). Lade sie im Kontrollcenter herunter."
        }
    }
}

/// Findet die Virtualisierungs-Engine (QEMU mit Hypervisor.framework), swtpm und die UEFI-Firmware.
///
/// Gesucht wird zuerst in der von Moonvisor heruntergeladenen Engine (`EngineStore`), dann im App-Bundle
/// (`Contents/Resources/engine`). Eine vorhandene Homebrew-Installation dient Entwicklern als Rückfallebene.
/// Alle Bestandteile kommen immer aus demselben Ordner, damit nichts gemischt wird.
public struct Toolchain: Sendable {
    public var qemuSystem: URL
    public var qemuImg: URL
    public var swtpm: URL?
    public var firmwareCode: URL
    public var firmwareVarsTemplate: URL
    /// Datenverzeichnis von QEMU (Firmware, Option-ROMs), wird mit `-L` übergeben.
    public var dataDirectory: URL?
    /// Engine-Ordner (bin/, Frameworks/, libexec/), nur bei der Moonvisor-Engine gesetzt.
    public var enginePrefix: URL?

    /// DirectX 11 über Neptune/DXMT ist nur mit der Moonvisor-Engine möglich.
    public var supportsDirectX: Bool {
        guard let enginePrefix else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: enginePrefix.appendingPathComponent("Frameworks/dxmt-native.framework").path)
            && fm.isExecutableFile(atPath: enginePrefix.appendingPathComponent("libexec/virgl_render_server").path)
    }

    static var searchPrefixes: [URL] {
        var prefixes: [URL] = []
        if let env = ProcessInfo.processInfo.environment["MOONVISOR_ENGINE"] {
            prefixes.append(URL(fileURLWithPath: env))
        }
        if let engine = EngineStore.installedURL {
            prefixes.append(engine)
        }
        if let resources = Bundle.main.resourceURL {
            prefixes.append(resources.appendingPathComponent("engine"))
        }
        prefixes.append(URL(fileURLWithPath: "/opt/homebrew"))
        prefixes.append(URL(fileURLWithPath: "/usr/local"))
        return prefixes
    }

    public struct Status: Sendable {
        public var qemu: URL?
        public var qemuImg: URL?
        public var swtpm: URL?
        public var firmware: URL?
        public var prefix: URL?

        public var isComplete: Bool { qemu != nil && qemuImg != nil && swtpm != nil && firmware != nil }
        /// Moonvisor-Engine (Werkzeuge als Frameworks, mit 3D-Bausteinen) statt z. B. Homebrew.
        public var isMoonvisorEngine: Bool {
            guard let prefix else { return false }
            return FileManager.default.fileExists(atPath: prefix.appendingPathComponent("Frameworks").path)
        }

        public var missing: [String] {
            var items: [String] = []
            if qemu == nil || qemuImg == nil { items.append("QEMU") }
            if firmware == nil { items.append("UEFI-Firmware") }
            if swtpm == nil { items.append("swtpm (TPM 2.0)") }
            return items
        }
    }

    static func status(prefix: URL) -> Status {
        let fm = FileManager.default
        func executable(_ relative: String) -> URL? {
            let url = prefix.appendingPathComponent(relative)
            return fm.isExecutableFile(atPath: url.path) ? url : nil
        }
        let firmware = prefix.appendingPathComponent("share/qemu/edk2-aarch64-code.fd")
        return Status(
            qemu: executable("bin/qemu-system-aarch64"),
            qemuImg: executable("bin/qemu-img"),
            swtpm: executable("bin/swtpm"),
            firmware: fm.fileExists(atPath: firmware.path) ? firmware : nil,
            prefix: prefix
        )
    }

    public static func status() -> Status {
        let all = searchPrefixes.map { status(prefix: $0) }
        return all.first { $0.isComplete }
            ?? all.first { $0.qemu != nil }
            ?? Status()
    }

    public static func locate(requireTPM: Bool = true) throws -> Toolchain {
        let s = status()
        var missing: [String] = []
        if s.qemu == nil || s.qemuImg == nil { missing.append("QEMU") }
        if s.firmware == nil { missing.append("UEFI-Firmware") }
        if requireTPM && s.swtpm == nil { missing.append("swtpm (TPM 2.0)") }
        guard missing.isEmpty, let qemu = s.qemu, let img = s.qemuImg, let fw = s.firmware else {
            throw ToolchainError.missing(missing.isEmpty ? ["QEMU"] : missing)
        }
        // Die ARM-Variablenvorlage hat dasselbe Layout wie die aarch64-Firmware.
        let data = fw.deletingLastPathComponent()
        let vars = data.appendingPathComponent("edk2-arm-vars.fd")
        return Toolchain(qemuSystem: qemu, qemuImg: img, swtpm: newestSwtpm(default: s.swtpm), firmwareCode: fw,
                         firmwareVarsTemplate: vars, dataDirectory: data, enginePrefix: s.isMoonvisorEngine ? s.prefix : nil)
    }

    /// TPM-Zustand, den ein neueres swtpm/libtpms (0.10, z. B. aus Homebrew bei Moonvisor 0.1) angelegt hat,
    /// kann das ältere libtpms der Engine nicht lesen. Ist ein Homebrew-swtpm vorhanden, nimmt Moonvisor deshalb
    /// das: es liest alte wie neue Zustände. swtpm ist ein eigener Prozess, QEMU spricht nur über den Socket mit ihm.
    static func newestSwtpm(default engineSwtpm: URL?) -> URL? {
        let homebrew = ["/opt/homebrew/bin/swtpm", "/usr/local/bin/swtpm"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        return homebrew ?? engineSwtpm
    }

    /// Legt die UEFI-Variablen einer VM aus der Vorlage an bzw. wandelt rohe Variablen in qcow2 um.
    public func prepareEFIVars(for bundle: VMBundle) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: bundle.efiVarsURL.path) else { return }
        let source = fm.fileExists(atPath: bundle.legacyEfiVarsURL.path) ? bundle.legacyEfiVarsURL : firmwareVarsTemplate
        let result = try ProcessRunner.run(qemuImg, ["convert", "-f", "raw", "-O", "qcow2", source.path, bundle.efiVarsURL.path])
        guard result.status == 0 else { throw MoonError.processFailed("qemu-img", result.output) }
        if source == bundle.legacyEfiVarsURL { try? fm.removeItem(at: source) }
    }

    public static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    public static var hostCPUCount: Int { ProcessInfo.processInfo.activeProcessorCount }
    public static var hostMemoryMB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) }
}
