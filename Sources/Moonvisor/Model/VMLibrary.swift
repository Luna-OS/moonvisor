import Foundation
import Virtualization

@MainActor
final class VirtualMachineItem: ObservableObject, Identifiable {
    nonisolated let id: URL
    let bundle: VMBundle
    let runner: VMRunner
    @Published private(set) var config: VMConfig
    @Published private(set) var snapshots: [Snapshot]
    @Published var lastError: String?

    init(bundle: VMBundle) throws {
        id = bundle.url
        self.bundle = bundle
        config = try bundle.loadConfig()
        runner = VMRunner(bundle: bundle)
        snapshots = SnapshotStore.list(in: bundle)
    }

    /// Hardware can only change while the machine is off; a saved state
    /// only restores into the exact configuration it was saved from.
    var isEditable: Bool { !runner.isActive && !runner.isSuspended }

    func update(_ change: (inout VMConfig) -> Void) {
        var updated = config
        change(&updated)
        guard updated != config else { return }
        do {
            try bundle.save(updated)
            config = updated
        } catch {
            lastError = error.localizedDescription
        }
    }

    func start() {
        lastError = nil
        runner.start(with: config)
    }

    func takeSnapshot(named name: String) {
        guard !runner.isActive else { lastError = MoonvisorError.machineActive.localizedDescription; return }
        modifySnapshots { _ = try SnapshotStore.create(named: name, in: bundle) }
    }

    func restore(_ snapshot: Snapshot) {
        guard !runner.isActive else { lastError = MoonvisorError.machineActive.localizedDescription; return }
        modifySnapshots { try SnapshotStore.restore(snapshot, in: bundle) }
        runner.refreshSuspendedState()
    }

    func delete(_ snapshot: Snapshot) {
        modifySnapshots { try SnapshotStore.delete(snapshot, in: bundle) }
    }

    private func modifySnapshots(_ work: () throws -> Void) {
        do {
            try work()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        snapshots = SnapshotStore.list(in: bundle)
    }
}

@MainActor
final class VMLibrary: ObservableObject {
    @Published private(set) var items: [VirtualMachineItem] = []
    let directory: URL
    let restoreImagesDirectory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moonvisor", isDirectory: true)
        directory = base.appendingPathComponent("Virtual Machines", isDirectory: true)
        restoreImagesDirectory = base.appendingPathComponent("Restore Images", isDirectory: true)
        for dir in [directory, restoreImagesDirectory] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        reload()
    }

    var hasActiveMachines: Bool { items.contains { $0.runner.isActive } }

    func item(for url: URL) -> VirtualMachineItem? {
        items.first { $0.id.path == url.path }
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let existing = Dictionary(items.map { ($0.id.path, $0) }, uniquingKeysWith: { first, _ in first })
        items = urls
            .filter { $0.pathExtension == VMBundle.fileExtension }
            .compactMap { url in existing[url.path] ?? (try? VirtualMachineItem(bundle: VMBundle(url: url))) }
            .sorted { $0.config.name.localizedStandardCompare($1.config.name) == .orderedAscending }
    }

    /// A free bundle location for a new machine called `name`.
    func newBundleURL(for name: String) -> URL {
        let safe = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        let base = safe.isEmpty ? "Virtual Machine" : safe
        var candidate = directory.appendingPathComponent(base).appendingPathExtension(VMBundle.fileExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(n)").appendingPathExtension(VMBundle.fileExtension)
            n += 1
        }
        return candidate
    }

    func clone(_ item: VirtualMachineItem) throws -> URL {
        guard !item.runner.isActive else { throw MoonvisorError.machineActive }
        var config = item.config
        config.name += " Copy"
        config.macAddress = VZMACAddress.randomLocallyAdministered().string
        config.created = Date()

        let target = VMBundle(url: newBundleURL(for: config.name))
        try FileManager.default.createDirectory(at: target.url, withIntermediateDirectories: false)
        do {
            let source = item.bundle
            // The machine identifier stays the same: the installed macOS's boot
            // policy is bound to it, so a new one would leave the clone unbootable.
            for (from, to) in [
                (source.diskURL, target.diskURL),
                (source.auxiliaryStorageURL, target.auxiliaryStorageURL),
                (source.hardwareModelURL, target.hardwareModelURL),
                (source.machineIdentifierURL, target.machineIdentifierURL),
            ] {
                try FileCloner.clone(from, to: to)
            }
            if source.hasSavedState { try FileCloner.clone(source.savedStateURL, to: target.savedStateURL) }
            try target.save(config)
        } catch {
            try? FileManager.default.removeItem(at: target.url)
            throw error
        }
        reload()
        return target.url
    }

    func delete(_ item: VirtualMachineItem) throws {
        guard !item.runner.isActive else { throw MoonvisorError.machineActive }
        try FileManager.default.trashItem(at: item.bundle.url, resultingItemURL: nil)
        reload()
    }

    /// Called when the app quits.
    func stopAll() async {
        for item in items where item.runner.isActive {
            await item.runner.stopForTermination()
        }
    }
}
