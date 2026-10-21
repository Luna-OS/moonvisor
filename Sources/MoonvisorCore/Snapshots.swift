import Foundation

public struct Snapshot: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var date: Date?
    public var vmStateSize: String
}

/// Schnappschüsse liegen direkt in der qcow2-Festplatte (interne Snapshots).
public enum Snapshots {
    public static func list(_ bundle: VMBundle, toolchain: Toolchain) throws -> [Snapshot] {
        let result = try ProcessRunner.run(toolchain.qemuImg, ["info", "-U", "--output=json", bundle.diskURL.path])
        guard result.status == 0 else { throw MoonError.processFailed("qemu-img", result.output) }
        return parse(Data(result.output.utf8))
    }

    /// Liest die Snapshot-Liste aus `qemu-img info --output=json`.
    static func parse(_ json: Data) -> [Snapshot] {
        guard let info = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let list = info["snapshots"] as? [[String: Any]] else { return [] }
        return list.map { item in
            let seconds = (item["date-sec"] as? NSNumber)?.doubleValue
            let stateBytes = (item["vm-state-size"] as? NSNumber)?.int64Value ?? 0
            return Snapshot(
                name: item["name"] as? String ?? "?",
                date: seconds.map { Date(timeIntervalSince1970: $0) },
                vmStateSize: stateBytes > 0 ? formatBytes(stateBytes) : "nur Festplatte"
            )
        }
    }

    static func requireStopped(_ bundle: VMBundle) throws {
        if VMRunner.runtime(of: bundle) != nil {
            throw MoonError.qmp("Schnappschüsse von Festplatten gehen nur bei ausgeschalteter VM. Nutze für laufende VMs „Schnappschuss (laufend)“.")
        }
    }

    public static func create(_ bundle: VMBundle, name: String, toolchain: Toolchain) throws {
        if VMRunner.runtime(of: bundle) != nil {
            try createLive(bundle, name: name)
            return
        }
        try run(toolchain, ["snapshot", "-c", name, bundle.diskURL.path])
    }

    /// Schnappschuss einer laufenden VM inklusive Arbeitsspeicher.
    public static func createLive(_ bundle: VMBundle, name: String) throws {
        try VMRunner.withQMP(bundle) { qmp in
            let output = try qmp.execute("human-monitor-command", ["command-line": "savevm \(name)"]) as? String ?? ""
            if output.lowercased().contains("error") { throw MoonError.qmp(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    public static func revert(_ bundle: VMBundle, name: String, toolchain: Toolchain) throws {
        if VMRunner.runtime(of: bundle) != nil {
            try VMRunner.withQMP(bundle) { qmp in
                let output = try qmp.execute("human-monitor-command", ["command-line": "loadvm \(name)"]) as? String ?? ""
                if output.lowercased().contains("error") { throw MoonError.qmp(output.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            return
        }
        try run(toolchain, ["snapshot", "-a", name, bundle.diskURL.path])
    }

    public static func delete(_ bundle: VMBundle, name: String, toolchain: Toolchain) throws {
        try requireStopped(bundle)
        try run(toolchain, ["snapshot", "-d", name, bundle.diskURL.path])
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
