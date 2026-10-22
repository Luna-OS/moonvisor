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
    var toolsVersion: Int?
    /// Laufende Dateiübertragungen in die VM.
    var transfers = 0
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
    /// Fortschritt, solange die Engine heruntergeladen wird.
    var engineProgress: EngineStore.Phase?
    var engineError: String?
    var errorMessage: String?
    var selectedID: String?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let worker = DispatchQueue(label: "moonvisor.model", qos: .userInitiated)
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var pasteboardCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var lastClipboardFromGuest: String?
    @ObservationIgnored private var lastFilesFromGuest: [URL] = []

    init() {
        reload()
        // Beim ersten Start ohne Engine lädt Moonvisor sie selbst herunter.
        if !toolchainStatus.isComplete { installEngine() }
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
                entry.toolsVersion = Int(argument)
                // Ältere Agenten ab Version 4 aktualisieren sich selbst.
                if let version = Int(argument), version >= 4, version < GuestTools.version {
                    entry.agent?.sendAgentUpdate()
                }
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
            case "img":
                guard entry.config.sharedClipboard, let png = Data(base64Encoded: argument) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(png, forType: .png)
                self.pasteboardCount = NSPasteboard.general.changeCount
            default:
                break
            }
        }
        agent.onFilesReceived = { [weak self, weak entry] urls, mode in
            guard let self, let entry, entry.config.sharedClipboard, mode == "clip", !urls.isEmpty else { return }
            // Im Finder mit ⌘V einsetzen.
            self.lastFilesFromGuest = urls
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
            self.pasteboardCount = NSPasteboard.general.changeCount
        }
        agent.onClose = { [weak entry] in entry?.toolsActive = false }
        entry.agent = agent
        entry.display.agent = agent
        agent.start()
    }

    /// Mac-Zwischenablage an alle VMs mit Moonvisor Tools weitergeben: Dateien, Text oder Bild.
    private func syncPasteboardToGuests() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != pasteboardCount else { return }
        pasteboardCount = pasteboard.changeCount
        let targets = entries.filter { $0.toolsActive && $0.config.sharedClipboard }
        guard !targets.isEmpty else { return }

        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty {
            guard files != lastFilesFromGuest else { return }
            let urls = files
            worker.async {
                guard FileTransfer.totalSize(urls) <= FileTransfer.clipboardLimit else { return }
                DispatchQueue.main.async {
                    for entry in targets where (entry.toolsVersion ?? 0) >= 4 {
                        entry.agent?.sendFiles(urls, mode: "clip")
                    }
                }
            }
            return
        }
        if let text = pasteboard.string(forType: .string) {
            guard text != lastClipboardFromGuest, text.utf8.count < 4_000_000 else { return }
            for entry in targets { entry.agent?.sendClipboard(text) }
            return
        }
        if let png = Self.pngData(from: pasteboard), png.count < 32_000_000 {
            for entry in targets where (entry.toolsVersion ?? 0) >= 4 { entry.agent?.sendImage(png: png) }
        }
    }

    static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Dateien per Drag & Drop in die VM (landen auf dem Windows-Schreibtisch).
    func dropFiles(_ urls: [URL], into entry: VMEntry) {
        guard let agent = entry.agent, entry.toolsActive else { return }
        guard (entry.toolsVersion ?? 0) >= 4 else {
            errorMessage = "Für Drag & Drop braucht die VM die neuen Moonvisor Tools. In Windows die CD „MOONTOOLS“ öffnen und „Moonvisor Tools installieren“ erneut ausführen."
            return
        }
        entry.transfers += 1
        agent.sendFiles(urls, mode: "drop") { [weak self, weak entry] error in
            entry?.transfers -= 1
            if let error { self?.errorMessage = "Übertragung fehlgeschlagen: \(error.localizedDescription)" }
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

    /// Richtet den vmnet-Netzwerkdienst ein. macOS fragt dafür einmalig nach einem Administrator-Passwort.
    @discardableResult
    func installVMNet(_ service: VMNet.Service) -> Bool {
        guard let engine = EngineStore.installedURL else {
            errorMessage = "Für dieses Netzwerk wird die Moonvisor-Engine benötigt. Lade sie in den Einstellungen herunter."
            return false
        }
        let script = VMNet.installScript(for: service, engine: engine)
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        if let error {
            // -128: Abbrechen im Passwortdialog.
            if (error[NSAppleScript.errorNumber] as? Int) != -128 {
                errorMessage = "Der Netzwerkdienst konnte nicht eingerichtet werden: \(error[NSAppleScript.errorMessage] as? String ?? "unbekannter Fehler")"
            }
            return false
        }
        if !VMNet.waitUntilRunning(service) {
            errorMessage = "Der Netzwerkdienst wurde eingerichtet, startet aber nicht. Details: /var/log/moonvisor-vmnet-\(service.name).log"
            return false
        }
        return true
    }

    /// Lädt die Moonvisor-Engine herunter, prüft und entpackt sie.
    func installEngine() {
        guard engineProgress == nil || engineProgress == .done else { return }
        engineError = nil
        engineProgress = .checking
        Task {
            do {
                try await EngineStore.install { phase in
                    DispatchQueue.main.async { self.engineProgress = phase }
                }
                await MainActor.run {
                    self.engineProgress = nil
                    self.reload()
                }
            } catch {
                await MainActor.run {
                    self.engineProgress = nil
                    self.engineError = EngineStore.describe(error)
                }
            }
        }
    }

    var runningCount: Int { entries.filter { $0.state != .stopped }.count }
}
