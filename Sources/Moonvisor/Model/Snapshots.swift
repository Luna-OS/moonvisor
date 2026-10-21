import Foundation

struct Snapshot: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var created: Date
    var includesSavedState: Bool
}

/// Snapshots are APFS clones of the disk image, the auxiliary storage and,
/// for a suspended machine, its saved state, kept under `Snapshots/<id>/`.
enum SnapshotStore {
    private static let metadataName = "snapshot.json"

    private static func directory(for snapshot: Snapshot, in bundle: VMBundle) -> URL {
        bundle.snapshotsURL.appendingPathComponent(snapshot.id.uuidString, isDirectory: true)
    }

    private static func liveFiles(in bundle: VMBundle) -> [URL] {
        [bundle.diskURL, bundle.auxiliaryStorageURL]
    }

    static func list(in bundle: VMBundle) -> [Snapshot] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: bundle.snapshotsURL, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return dirs
            .compactMap { dir in
                try? decoder.decode(Snapshot.self, from: Data(contentsOf: dir.appendingPathComponent(metadataName)))
            }
            .sorted { $0.created < $1.created }
    }

    static func create(named name: String, in bundle: VMBundle) throws -> Snapshot {
        let snapshot = Snapshot(id: UUID(), name: name, created: Date(), includesSavedState: bundle.hasSavedState)
        let dir = directory(for: snapshot, in: bundle)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            var sources = liveFiles(in: bundle)
            if snapshot.includesSavedState { sources.append(bundle.savedStateURL) }
            for source in sources {
                try FileCloner.clone(source, to: dir.appendingPathComponent(source.lastPathComponent))
            }
            // Metadata last: a snapshot without it is incomplete and never listed.
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: dir.appendingPathComponent(metadataName))
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return snapshot
    }

    static func restore(_ snapshot: Snapshot, in bundle: VMBundle) throws {
        let dir = directory(for: snapshot, in: bundle)
        for live in liveFiles(in: bundle) {
            try replace(live, with: dir.appendingPathComponent(live.lastPathComponent))
        }
        if snapshot.includesSavedState {
            try replace(bundle.savedStateURL, with: dir.appendingPathComponent(bundle.savedStateURL.lastPathComponent))
        } else {
            try? FileManager.default.removeItem(at: bundle.savedStateURL)
        }
    }

    static func delete(_ snapshot: Snapshot, in bundle: VMBundle) throws {
        try FileManager.default.removeItem(at: directory(for: snapshot, in: bundle))
    }

    private static func replace(_ live: URL, with source: URL) throws {
        let fm = FileManager.default
        let staged = live.deletingLastPathComponent().appendingPathComponent(".restoring-" + live.lastPathComponent)
        try? fm.removeItem(at: staged)
        try FileCloner.clone(source, to: staged)
        if fm.fileExists(atPath: live.path) {
            _ = try fm.replaceItemAt(live, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: live)
        }
    }
}
