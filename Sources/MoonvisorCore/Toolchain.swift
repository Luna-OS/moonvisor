import Foundation

public enum ToolchainError: LocalizedError {
    case missing([String])

    public var errorDescription: String? {
        switch self {
        case .missing(let items):
            return "Folgende Komponenten fehlen: \(items.joined(separator: ", ")). Installiere sie mit: brew install qemu swtpm"
        }
    }
}

/// Findet die Virtualisierungs-Engine (QEMU mit Hypervisor.framework), swtpm und die UEFI-Firmware.
///
/// Gesucht wird zuerst im App-Bundle (`Contents/Resources/engine`), dann in Homebrew.
public struct Toolchain: Sendable {
    public var qemuSystem: URL
    public var qemuImg: URL
    public var swtpm: URL?
    public var firmwareCode: URL
    public var firmwareVarsTemplate: URL

    public static let brewInstallCommand = "brew install qemu swtpm"

    static var searchPrefixes: [URL] {
        var prefixes: [URL] = []
        if let env = ProcessInfo.processInfo.environment["MOONVISOR_ENGINE"] {
            prefixes.append(URL(fileURLWithPath: env))
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
        public var homebrew: URL?

        public var isComplete: Bool { qemu != nil && qemuImg != nil && swtpm != nil && firmware != nil }

        public var missing: [String] {
            var items: [String] = []
            if qemu == nil || qemuImg == nil { items.append("QEMU") }
            if firmware == nil { items.append("UEFI-Firmware (edk2)") }
            if swtpm == nil { items.append("swtpm (TPM 2.0)") }
            return items
        }
    }

    public static func status() -> Status {
        let fm = FileManager.default
        func find(_ relative: String) -> URL? {
            for prefix in searchPrefixes {
                let candidate = prefix.appendingPathComponent(relative)
                if fm.isExecutableFile(atPath: candidate.path) || (relative.hasSuffix(".fd") && fm.fileExists(atPath: candidate.path)) {
                    return candidate
                }
            }
            return nil
        }
        let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { fm.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        return Status(
            qemu: find("bin/qemu-system-aarch64"),
            qemuImg: find("bin/qemu-img"),
            swtpm: find("bin/swtpm"),
            firmware: find("share/qemu/edk2-aarch64-code.fd"),
            homebrew: brew
        )
    }

    public static func locate(requireTPM: Bool = true) throws -> Toolchain {
        let s = status()
        var missing: [String] = []
        if s.qemu == nil || s.qemuImg == nil { missing.append("QEMU") }
        if s.firmware == nil { missing.append("UEFI-Firmware (edk2)") }
        if requireTPM && s.swtpm == nil { missing.append("swtpm (TPM 2.0)") }
        guard missing.isEmpty, let qemu = s.qemu, let img = s.qemuImg, let fw = s.firmware else {
            throw ToolchainError.missing(missing)
        }
        // Die ARM-Variablenvorlage hat dasselbe Layout wie die aarch64-Firmware.
        let vars = fw.deletingLastPathComponent().appendingPathComponent("edk2-arm-vars.fd")
        return Toolchain(qemuSystem: qemu, qemuImg: img, swtpm: s.swtpm, firmwareCode: fw, firmwareVarsTemplate: vars)
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
