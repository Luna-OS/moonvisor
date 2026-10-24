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
    /// Ob das TPM-Gerät dieser QEMU-Version die Option `ppi` kennt (QEMU 11 ja, QEMU 10 nein).
    public var tpmHasPPI = true
    /// UTMs QEMU (die Moonvisor-Engine) kennt `virtio-ramfb`, Homebrew-QEMU nicht.
    public var hasVirtioRamfb = false

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
                         firmwareVarsTemplate: vars, dataDirectory: data, enginePrefix: s.isMoonvisorEngine ? s.prefix : nil,
                         tpmHasPPI: deviceHasProperty(qemu, device: "tpm-tis-device", property: "ppi"),
                         // Nur QEMU selbst weiß es: Auch Homebrew legt einen Ordner Frameworks an.
                         hasVirtioRamfb: deviceExists(qemu, device: "virtio-ramfb"))
    }

    private static let probeLock = NSLock()
    nonisolated(unsafe) private static var probeCache: [String: Bool] = [:]

    /// Fragt QEMU, ob ein Gerät eine Eigenschaft kennt (`-device <gerät>,help`). Das Ergebnis wird je QEMU zwischengespeichert.
    static func deviceHasProperty(_ qemu: URL, device: String, property: String) -> Bool {
        let key = "\(qemu.path)|\(device)|\(property)"
        probeLock.lock()
        if let cached = probeCache[key] { probeLock.unlock(); return cached }
        probeLock.unlock()
        guard let result = try? ProcessRunner.run(qemu, ["-device", "\(device),help"]), result.status == 0 else {
            return true
        }
        let found = result.output.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix(property + "=") }
        probeLock.lock()
        probeCache[key] = found
        probeLock.unlock()
        return found
    }

    /// Fragt QEMU, ob es ein Gerät kennt. `-device <gerät>,help` endet auch bei unbekannten Geräten mit Status 0
    /// („Device '…' not found“), deshalb zählt nur die Liste der Optionen.
    static func deviceExists(_ qemu: URL, device: String) -> Bool {
        let key = "\(qemu.path)|\(device)"
        probeLock.lock()
        if let cached = probeCache[key] { probeLock.unlock(); return cached }
        probeLock.unlock()
        // Ließ sich QEMU nicht starten, nichts zwischenspeichern: beim nächsten Start erneut fragen.
        guard let result = try? ProcessRunner.run(qemu, ["-device", "\(device),help"]) else { return false }
        let found = deviceListed(device, inHelp: result.output)
        probeLock.lock()
        probeCache[key] = found
        probeLock.unlock()
        return found
    }

    static func deviceListed(_ device: String, inHelp output: String) -> Bool {
        output.contains("\(device) options:") || output.contains("There are no options for \(device)")
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
        if !fm.fileExists(atPath: bundle.efiVarsURL.path) {
            let source = fm.fileExists(atPath: bundle.legacyEfiVarsURL.path) ? bundle.legacyEfiVarsURL : firmwareVarsTemplate
            let result = try ProcessRunner.run(qemuImg, ["convert", "-f", Self.imageFormat(of: source), "-O", "qcow2",
                                                         source.path, bundle.efiVarsURL.path])
            guard result.status == 0 else { throw MoonError.processFailed("qemu-img", result.output) }
            if source == bundle.legacyEfiVarsURL { try? fm.removeItem(at: source) }
        }
        try padEFIVars(bundle.efiVarsURL)
    }

    /// Die Vorlage der Engine (QEMU 10) ist selbst schon qcow2 mit 64 MB, ältere Vorlagen und efi-vars.fd sind roh.
    static func imageFormat(of url: URL) -> String {
        qcow2VirtualSize(url) == nil ? "raw" : "qcow2"
    }

    /// Bis Moonvisor 0.2.16 wurde die qcow2-Vorlage der Engine als Rohdaten umgewandelt: efi-vars.qcow2 war dann nur
    /// 329 216 Bytes groß. Die virt-Maschine verlangt aber für beide Flash-Bausteine genau die Größe der Firmware (64 MB).
    /// Solche VMs werden hier aufgefüllt; die Firmware legt den Variablenspeicher beim nächsten Start neu an.
    func padEFIVars(_ vars: URL) throws {
        let code = firmwareCode.resolvingSymlinksInPath()
        guard let codeSize = ((try? FileManager.default.attributesOfItem(atPath: code.path))?[.size] as? NSNumber)?.int64Value,
              codeSize > 0 else {
            throw MoonError.processFailed("UEFI-Variablen", "Größe der Firmware \(code.path) nicht lesbar.")
        }
        guard try efiVarsSize(vars) < codeSize else { return }
        let result = try ProcessRunner.run(qemuImg, ["resize", "-f", "qcow2", vars.path, String(codeSize)])
        guard result.status == 0 else { throw MoonError.processFailed("qemu-img resize", result.output) }
        // Lieber hier mit klarer Meldung abbrechen als QEMU mit „pflash1 block backend provides …“ scheitern lassen.
        let padded = try efiVarsSize(vars)
        guard padded >= codeSize else {
            throw MoonError.processFailed("UEFI-Variablen", "\(vars.lastPathComponent) hat \(padded) statt \(codeSize) Bytes.")
        }
    }

    /// Virtuelle Größe von efi-vars.qcow2: aus dem qcow2-Kopf, sonst über qemu-img info.
    func efiVarsSize(_ vars: URL) throws -> Int64 {
        if let size = Self.qcow2VirtualSize(vars) { return size }
        let info = try ProcessRunner.run(qemuImg, ["info", "--output=json", "-f", "qcow2", vars.path])
        guard info.status == 0, let size = Self.virtualSize(fromImageInfo: info.output) else {
            throw MoonError.processFailed("qemu-img info", info.output)
        }
        return size
    }

    /// qcow2 beginnt mit „QFI\u{FB}“; die virtuelle Größe steht big-endian in den Bytes 24–31.
    static func qcow2VirtualSize(_ url: URL) -> Int64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32) else { return nil }
        let header = [UInt8](data)
        guard header.count == 32, header[0..<4] == [0x51, 0x46, 0x49, 0xFB] else { return nil }
        return header[24..<32].reduce(Int64(0)) { $0 << 8 | Int64($1) }
    }

    /// `virtual-size` aus `qemu-img info --output=json`.
    static func virtualSize(fromImageInfo output: String) -> Int64? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let data = String(output[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["virtual-size"] as? NSNumber)?.int64Value
    }

    public static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    public static var hostCPUCount: Int { ProcessInfo.processInfo.activeProcessorCount }
    public static var hostMemoryMB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) }
}
