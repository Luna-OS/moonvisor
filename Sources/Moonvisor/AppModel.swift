import AppKit
import MoonvisorCore
import SwiftUI

@Observable
final class VMEntry: Identifiable {
    let bundle: VMBundle
    var config: VMConfig
    var state: VMRunState = .stopped
    var thumbnail: NSImage?
    var busyMessage: String?
    /// Moonvisor Tools im Gast melden sich über den Agent-Kanal.
    var toolsActive = false
    let display = DisplaySession()
    @ObservationIgnored var agent: AgentChannel?
    @ObservationIgnored var displaySocket: String?
    @ObservationIgnored var thumbnailDate: Date?

    var id: String { bundle.id }

    init(bundle: VMBundle, config: VMConfig) {
        self.bundle = bundle
        self.config = config
        loadThumbnail()
    }

    func loadThumbnail() {
        guard let values = try? bundle.thumbnailURL.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate else { return }
        if date != thumbnailDate, let image = NSImage(contentsOf: bundle.thumbnailURL) {
            thumbnail = image
            thumbnailDate = date
        }
    }

    var symbolName: String {
        switch config.guestOS {
        case .windows11: return "macwindow.on.rectangle"
        case .linux: return "terminal"
        case .other: return "desktopcomputer"
        }
    }
}

@Observable
final class AppModel {
    var entries: [VMEntry] = []
    var toolchainStatus = Toolchain.status()
    var errorMessage: String?
    var selectedID: String?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let worker = DispatchQueue(label: "moonvisor.model", qos: .userInitiated)
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var pasteboardCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var lastClipboardFromGuest: String?

    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshStates() }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.syncPasteboardToGuests() }
    }

    func entry(_ id: String?) -> VMEntry? {
        guard let id else { return nil }
        return entries.first { $0.id == id }
    }

    func reload() {
        try? FileManager.default.createDirectory(at: VMLibrary.defaultFolder, withIntermediateDirectories: true)
        let bundles = VMLibrary.list()
        var next: [VMEntry] = []
        for bundle in bundles {
            guard let config = try? bundle.loadConfig() else { continue }
            if let existing = entries.first(where: { $0.bundle == bundle }) {
                existing.config = config
                next.append(existing)
            } else {
                next.append(VMEntry(bundle: bundle, config: config))
            }
        }
        entries = next
        toolchainStatus = Toolchain.status()
        refreshStates()
    }

    func refreshStates() {
        tick += 1
        let snapshot = entries.map { ($0, $0.bundle) }
        let captureThumbnails = tick % 15 == 0
        worker.async {
            var results: [(VMEntry, VMRunState, RuntimeInfo?)] = []
            for (entry, bundle) in snapshot {
                let info = VMRunner.runtime(of: bundle)
                let state = info == nil ? VMRunState.stopped : VMRunner.state(of: bundle)
                if captureThumbnails, state == .running { try? VMRunner.captureThumbnail(bundle) }
                results.append((entry, state, info))
            }
            DispatchQueue.main.async {
                for (entry, state, info) in results {
                    // Übergangszustände nicht durch Zwischenstände überschreiben.
                    if entry.state == .stopping && state == .running { continue }
                    entry.state = state
                    if let info {
                        if entry.displaySocket != info.sockets.vnc {
                            entry.displaySocket = info.sockets.vnc
                            entry.display.connect(socketPath: info.sockets.vnc)
                            self.connectAgent(entry, path: info.sockets.agent)
                        }
                    } else if entry.displaySocket != nil {
                        entry.displaySocket = nil
                        entry.display.disconnect()
                        entry.agent?.stop()
                        entry.agent = nil
                        entry.display.agent = nil
                        entry.toolsActive = false
                    }
                    entry.loadThumbnail()
                }
            }
        }
    }

    // MARK: Moonvisor Tools

    private func connectAgent(_ entry: VMEntry, path: String) {
        entry.agent?.stop()
        let agent = AgentChannel(path: path)
        agent.onMessage = { [weak self, weak entry] command, argument in
            guard let self, let entry else { return }
            switch command {
            case "hello":
                entry.toolsActive = true
                // Mit installierten Tools ist auch der virtio-GPU-Treiber da: ab dem nächsten Start dynamische Auflösung.
                if entry.config.guestOS == .windows11 && entry.config.graphics == .automatic {
                    var config = entry.config
                    config.graphics = .virtio
                    self.save(entry, config: config)
                }
                if entry.config.usesVirtioGPU { entry.display.requestCurrentSize() }
            case "clip":
                guard entry.config.sharedClipboard,
                      let data = Data(base64Encoded: argument),
                      let text = String(data: data, encoding: .utf8) else { return }
                self.lastClipboardFromGuest = text
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.pasteboardCount = NSPasteboard.general.changeCount
            default:
                break
            }
        }
        agent.onClose = { [weak entry] in entry?.toolsActive = false }
        entry.agent = agent
        entry.display.agent = agent
        agent.start()
    }

    /// Mac-Zwischenablage an alle VMs mit Moonvisor Tools weitergeben.
    private func syncPasteboardToGuests() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != pasteboardCount else { return }
        pasteboardCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), text != lastClipboardFromGuest, text.utf8.count < 4_000_000 else { return }
        for entry in entries where entry.toolsActive && entry.config.sharedClipboard {
            entry.agent?.sendClipboard(text)
        }
    }

    // MARK: Aktionen

    private func perform(_ entry: VMEntry, _ message: String?, _ body: @escaping (VMBundle) throws -> Void) {
        entry.busyMessage = message
        let bundle = entry.bundle
        worker.async {
            do {
                try body(bundle)
                DispatchQueue.main.async {
                    entry.busyMessage = nil
                    self.refreshStates()
                }
            } catch {
                DispatchQueue.main.async {
                    entry.busyMessage = nil
                    self.errorMessage = error.localizedDescription
                    self.refreshStates()
                }
            }
        }
    }

    func start(_ entry: VMEntry) {
        toolchainStatus = Toolchain.status()
        guard toolchainStatus.isComplete || (!entry.config.tpmEnabled && toolchainStatus.qemu != nil) else {
            errorMessage = ToolchainError.missing(toolchainStatus.missing).localizedDescription
            return
        }
        entry.state = .starting
        perform(entry, "Startet …") { bundle in
            let toolchain = try Toolchain.locate(requireTPM: entry.config.tpmEnabled)
            try VMRunner.start(bundle: bundle, toolchain: toolchain) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshStates() }
            }
        }
    }

    func shutdown(_ entry: VMEntry) {
        captureThumbnail(entry)
        entry.state = .stopping
        perform(entry, nil) { try VMRunner.shutdown($0) }
    }

    func powerOff(_ entry: VMEntry) {
        captureThumbnail(entry)
        entry.state = .stopping
        perform(entry, "Wird ausgeschaltet …") { try VMRunner.powerOff($0) }
    }

    func restart(_ entry: VMEntry) { perform(entry, nil) { try VMRunner.restart($0) } }
    func pause(_ entry: VMEntry) { perform(entry, nil) { try VMRunner.pause($0) } }
    func resume(_ entry: VMEntry) { perform(entry, nil) { try VMRunner.resume($0) } }
    func ctrlAltDelete(_ entry: VMEntry) { perform(entry, nil) { try VMRunner.sendCtrlAltDelete($0) } }

    func captureThumbnail(_ entry: VMEntry) {
        try? VMRunner.captureThumbnail(entry.bundle)
    }

    func takeSnapshot(_ entry: VMEntry, name: String) {
        perform(entry, "Schnappschuss wird erstellt …") { bundle in
            try Snapshots.create(bundle, name: name, toolchain: try Toolchain.locate(requireTPM: false))
        }
    }

    func save(_ entry: VMEntry, config: VMConfig) {
        do {
            try entry.bundle.saveConfig(config)
            entry.config = config
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealInFinder(_ entry: VMEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.bundle.url])
    }

    func moveToTrash(_ entry: VMEntry) {
        do {
            try VMLibrary.moveToTrash(entry.bundle)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func ejectInstallMedia(_ entry: VMEntry) {
        var config = entry.config
        config.installMediaAttached = false
        save(entry, config: config)
    }

    /// Öffnet Terminal mit dem Homebrew-Installationsbefehl für die Engine.
    func installEngine() {
        let command = toolchainStatus.homebrew != nil
            ? Toolchain.brewInstallCommand
            : #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" && \#(Toolchain.brewInstallCommand)"#
        let script = "tell application \"Terminal\" to do script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"\nactivate application \"Terminal\""
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if error != nil {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            errorMessage = "Terminal konnte nicht geöffnet werden. Der Befehl wurde in die Zwischenablage kopiert:\n\(command)"
        }
    }

    var runningCount: Int { entries.filter { $0.state != .stopped }.count }
}
