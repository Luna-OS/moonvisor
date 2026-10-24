import Foundation

public struct Snapshot: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var date: Date?
    public var vmStateSize: String
}

/// Schnappschüsse liegen direkt in der qcow2-Festplatte (interne Snapshots).
public enum Snapshots {
    /// Interne Schnappschüsse liegen in der Festplatte und in den UEFI-Variablen (beide qcow2).
    static func images(_ bundle: VMBundle) -> [URL] {
        [bundle.diskURL, bundle.efiVarsURL].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func info(_ image: URL, toolchain: Toolchain) throws -> [[String: Any]] {
        let result = try ProcessRunner.run(toolchain.qemuImg, ["info", "-U", "--output=json", image.path])
        guard result.status == 0 else { throw MoonError.processFailed("qemu-img", result.output) }
        let object = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
        return object?["snapshots"] as? [[String: Any]] ?? []
    }

    public static func list(_ bundle: VMBundle, toolchain: Toolchain) throws -> [Snapshot] {
        let disk = try info(bundle.diskURL, toolchain: toolchain)
        var stateSizes: [String: Int64] = [:]
        for image in images(bundle) {
            for item in try info(image, toolchain: toolchain) {
                guard let name = item["name"] as? String else { continue }
                stateSizes[name] = max(stateSizes[name] ?? 0, (item["vm-state-size"] as? NSNumber)?.int64Value ?? 0)
            }
        }
        return merge(disk: disk, stateSizes: stateSizes)
    }

    static func merge(disk: [[String: Any]], stateSizes: [String: Int64]) -> [Snapshot] {
        disk.map { item in
            let name = item["name"] as? String ?? "?"
            let seconds = (item["date-sec"] as? NSNumber)?.doubleValue
            let state = stateSizes[name] ?? 0
            return Snapshot(
                name: name,
                date: seconds.map { Date(timeIntervalSince1970: $0) },
                vmStateSize: state > 0 ? "mit Arbeitsspeicher (\(formatBytes(state)))" : "nur Festplatte"
            )
        }
    }

    /// Für Tests: liest die Liste direkt aus einer JSON-Ausgabe von `qemu-img info`.
    static func parse(_ json: Data) -> [Snapshot] {
        let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        let items = object?["snapshots"] as? [[String: Any]] ?? []
        var sizes: [String: Int64] = [:]
        for item in items {
            if let name = item["name"] as? String { sizes[name] = (item["vm-state-size"] as? NSNumber)?.int64Value ?? 0 }
        }
        return merge(disk: items, stateSizes: sizes)
    }

    static func requireStopped(_ bundle: VMBundle) throws {
        if VMRunner.runtime(of: bundle) != nil {
            throw MoonError.qmp("Das geht nur bei ausgeschalteter VM.")
        }
    }

    static func hmp(_ bundle: VMBundle, _ command: String, timeout: Double = 10) throws {
        try VMRunner.withQMP(bundle, timeout: timeout) { qmp in
            let output = try qmp.execute("human-monitor-command", ["command-line": command]) as? String ?? ""
            if output.lowercased().contains("error") { throw MoonError.qmp(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    /// QEMU-Monitor trennt Argumente an Leerzeichen; Namen deshalb ohne Leerzeichen weitergeben.
    public static func sanitize(_ name: String) -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "_")
        return cleaned.isEmpty ? "Schnappschuss" : cleaned
    }

    // MARK: Hardware je Schnappschuss

    /// Ein Schnappschuss mit Arbeitsspeicher lässt sich nur mit derselben Hardware laden. Moonvisor merkt sie sich
    /// deshalb beim Erstellen und stellt sie beim Wiederherstellen zurück (wie Parallels).
    static func hardwareURL(_ bundle: VMBundle, _ tag: String) -> URL {
        let file = tag.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? tag
        return bundle.snapshotConfigsURL.appendingPathComponent(file + ".json")
    }

    static func saveHardware(_ bundle: VMBundle, tag: String) throws {
        // Maßgeblich ist die Hardware, mit der die laufende VM gestartet wurde.
        let config = try VMRunner.runtime(of: bundle)?.config ?? bundle.loadConfig()
        try FileManager.default.createDirectory(at: bundle.snapshotConfigsURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(config).write(to: hardwareURL(bundle, tag), options: .atomic)
    }

    static func savedHardware(_ bundle: VMBundle, tag: String) -> VMConfig? {
        guard let data = try? Data(contentsOf: hardwareURL(bundle, tag)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VMConfig.self, from: data)
    }

    /// Übernimmt alles, was die Geräte der VM bestimmt. Name, Notizen, Portweiterleitungen usw. bleiben.
    public static func applyHardware(from snapshot: VMConfig, to config: inout VMConfig) {
        config.cpuCount = snapshot.cpuCount
        config.memoryMB = snapshot.memoryMB
        config.graphics = snapshot.graphics
        config.deviceRevision = snapshot.deviceRevision
        config.soundEnabled = snapshot.soundEnabled
        config.tpmEnabled = snapshot.tpmEnabled
        config.macAddress = snapshot.macAddress
        config.installMediaAttached = snapshot.installMediaAttached
        config.installMediaPath = snapshot.installMediaPath
        config.attachDriversDisc = snapshot.attachDriversDisc
        // Ob es eine Netzwerkkarte gibt, gehört zur Hardware; die Art der Verbindung nicht.
        if (snapshot.networkMode == .disconnected) != (config.networkMode == .disconnected) {
            config.networkMode = snapshot.networkMode
        }
    }

    /// Läuft die VM, werden Arbeitsspeicher und Geräte mitgesichert (die VM pausiert dafür kurz).
    public static func create(_ bundle: VMBundle, name: String, toolchain: Toolchain) throws {
        let tag = sanitize(name)
        if let info = VMRunner.runtime(of: bundle) {
            // QEMU kann eine NVMe-Festplatte nicht mitsichern; Windows-VMs haben eine.
            if (info.config ?? (try? bundle.loadConfig()))?.guestOS == .windows11 {
                throw MoonError.qmp("Schnappschüsse einer laufenden Windows-VM sind nicht möglich: QEMU kann ihre NVMe-Festplatte nicht samt Arbeitsspeicher sichern. Fahre Windows herunter, dann sichert Moonvisor die Festplatte.")
            }
            // Die Hardware vorher sichern: savevm antwortet erst, wenn der ganze Arbeitsspeicher geschrieben ist.
            let url = hardwareURL(bundle, tag)
            let previous = try? Data(contentsOf: url)
            try? saveHardware(bundle, tag: tag)
            do {
                try hmp(bundle, "savevm \(tag)", timeout: 900)
            } catch {
                if let previous { try? previous.write(to: url, options: .atomic) } else { try? FileManager.default.removeItem(at: url) }
                throw error
            }
            return
        }
        for image in images(bundle) { try run(toolchain, ["snapshot", "-c", tag, image.path]) }
    }

    /// Stellt einen Schnappschuss wieder her. Mit Arbeitsspeicher setzt die VM beim (Neu-)Start genau dort fort.
    /// Gibt zurück, ob die VM dafür neu gestartet werden muss.
    @discardableResult
    public static func revert(_ bundle: VMBundle, name: String, toolchain: Toolchain) throws -> Bool {
        let hasState = try info(bundle.diskURL, toolchain: toolchain)
            .first { $0["name"] as? String == name }
            .map { (($0["vm-state-size"] as? NSNumber)?.int64Value ?? 0) > 0 } ?? false
        let running = VMRunner.runtime(of: bundle) != nil
        if hasState {
            var config = try bundle.loadConfig()
            if let hardware = savedHardware(bundle, tag: name) {
                applyHardware(from: hardware, to: &config)
            }
            config.resumeSnapshot = name
            try bundle.saveConfig(config)
            if running { try VMRunner.powerOff(bundle) }
            return running
        }
        if running { try VMRunner.powerOff(bundle) }
        for image in images(bundle) where try info(image, toolchain: toolchain).contains(where: { $0["name"] as? String == name }) {
            try run(toolchain, ["snapshot", "-a", name, image.path])
        }
        return running
    }

    public static func delete(_ bundle: VMBundle, name: String, toolchain: Toolchain) throws {
        defer { try? FileManager.default.removeItem(at: hardwareURL(bundle, name)) }
        if VMRunner.runtime(of: bundle) != nil {
            try hmp(bundle, "delvm \(name)", timeout: 120)
            return
        }
        for image in images(bundle) where try info(image, toolchain: toolchain).contains(where: { $0["name"] as? String == name }) {
            try run(toolchain, ["snapshot", "-d", name, image.path])
        }
    }

    static func run(_ toolchain: Toolchain, _ args: [String]) throws {
        let result = try ProcessRunner.run(toolchain.qemuImg, args)
        guard result.status == 0 else { throw MoonError.processFailed("qemu-img", result.output) }
    }
}

public enum DiskTool {
    /// Vergrößert die virtuelle Festplatte (Partition muss im Gast erweitert werden).
    public static func grow(_ bundle: VMBundle, toGB size: Int, toolchain: Toolchain) throws {
        try Snapshots.requireStopped(bundle)
        let result = try ProcessRunner.run(toolchain.qemuImg, ["resize", bundle.diskURL.path, "\(size)G"])
        guard result.status == 0 else { throw MoonError.processFailed("qemu-img", result.output) }
    }

    /// Gibt freigegebenen Speicher wieder an den Mac zurück (wie „Festplatte bereinigen“).
    public static func compact(_ bundle: VMBundle, toolchain: Toolchain) throws {
        try Snapshots.requireStopped(bundle)
        // `qemu-img convert` übernimmt keine internen Schnappschüsse.
        if !(try Snapshots.list(bundle, toolchain: toolchain)).isEmpty {
            throw MoonError.qmp("Bereinigen ist nur ohne Schnappschüsse möglich. Lösche sie zuerst.")
        }
        let temp = bundle.url.appendingPathComponent("disk.compact.qcow2")
        try? FileManager.default.removeItem(at: temp)
        let result = try ProcessRunner.run(toolchain.qemuImg, ["convert", "-O", "qcow2", "-o", "lazy_refcounts=on", bundle.diskURL.path, temp.path])
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw MoonError.processFailed("qemu-img", result.output)
        }
        _ = try FileManager.default.replaceItemAt(bundle.diskURL, withItemAt: temp)
    }
}
