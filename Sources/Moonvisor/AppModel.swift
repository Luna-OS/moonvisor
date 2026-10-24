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
    /// Aktiver Grafiktreiber im Gast (viogpu3d = DirectX, viogpudo = einfach), von den Moonvisor Tools gemeldet.
    var gpuDriver: String?
    /// Moonvisor richtet gerade den DirectX-Treiber im Gast ein.
    var directXSetupRunning = false
    /// In dieser Sitzung schon automatisch versucht (danach nur noch über den Knopf).
    var directXSetupTried = false
    @ObservationIgnored var directXSetupStarted: Date?
    /// „Moonvisor Tools installieren“ wurde gestartet; Windows wartet auf die Bestätigung der Adminrechte.
    var toolsInstallRequested = false
    /// Warum die VM zuletzt nicht starten konnte oder unerwartet beendet wurde.
    var lastFailure: String?
    let display = DisplaySession()
    @ObservationIgnored var agent: AgentChannel?
    @ObservationIgnored var displaySocket: String?
    /// QEMU-Prozess, zu dem Bild und Tools-Kanal gehören. Startet die VM mit demselben Socket neu, ist es eine neue Sitzung.
    @ObservationIgnored var runtimePID: Int32?
    @ObservationIgnored var thumbnailDate: Date?
    /// Wann „Herunterfahren“ angefordert wurde. Die Firmware und das Windows-Setup reagieren nicht auf den
    /// ACPI-Ausschalter; dann soll die VM nicht ewig als „Wird heruntergefahren …“ dastehen.
    @ObservationIgnored var shutdownRequested: Date?

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

    /// Kann Moonvisor den DirectX-Treiber jetzt in Windows einrichten lassen?
    var canSetUpDirectX: Bool {
        config.graphics == .directX && toolsActive && (toolsVersion ?? 0) >= 5
            && !directXSetupRunning && DriverStore.cachedDirectXISO != nil
    }

    /// Automatische Einrichtungsversuche über alle Sitzungen. Schlägt sie fehl, nicht bei jedem Start neu starten.
    var directXAutoSetups: Int {
        get { UserDefaults.standard.integer(forKey: "directXAutoSetups.\(config.id)") }
        set { UserDefaults.standard.set(newValue, forKey: "directXAutoSetups.\(config.id)") }
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
    @ObservationIgnored private let poller = DispatchQueue(label: "moonvisor.poller", qos: .utility)
    @ObservationIgnored private var tick = 0
    /// Eine Abfrage läuft noch: weitere Anstöße warten auf sie, statt sich in der Warteschlange zu stapeln.
    @ObservationIgnored private var refreshRunning = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var pasteboardCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var lastClipboardFromGuest: String?
    @ObservationIgnored private var lastFilesFromGuest: [URL] = []

    init() {
        reload()
        // Moonvisor lädt seine eigene Engine selbst herunter, auch wenn noch eine ältere Homebrew-Installation
        // vorhanden ist: nur die Moonvisor-Engine kann DirectX.
        if EngineStore.installedURL == nil { installEngine() }
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
        guard !refreshRunning else {
            refreshAgain = true
            return
        }
        refreshRunning = true
        tick += 1
        let snapshot = entries.map { ($0, $0.bundle, $0.state) }
        let captureThumbnails = tick % 15 == 0
        // Eigene Warteschlange: Aktionen wie Ausschalten sollen nicht hinter der Abfrage warten.
        poller.async {
            var results: [(VMEntry, VMRunState, RuntimeInfo?)] = []
            for (entry, bundle, previous) in snapshot {
                let info = VMRunner.runtime(of: bundle)
                var state = VMRunState.stopped
                if let info {
                    // Antwortet QMP gerade nicht, gilt der bisherige Zustand.
                    state = VMRunner.polledState(info) ?? (previous == .stopped ? .starting : previous)
                }
                if captureThumbnails, state == .running { try? VMRunner.captureThumbnail(bundle, timeout: 2) }
                results.append((entry, state, info))
            }
            DispatchQueue.main.async {
                self.refreshRunning = false
                if self.refreshAgain {
                    self.refreshAgain = false
                    DispatchQueue.main.async { self.refreshStates() }
                }
                for (entry, state, info) in results {
                    // Ein Start läuft noch, die Abfrage kam ihm zuvor: nicht als ausgeschaltet anzeigen.
                    if entry.state == .starting && state == .stopped && entry.busyMessage != nil { continue }
                    // Übergangszustände nicht durch Zwischenstände überschreiben.
                    if entry.state == .stopping && state == .running {
                        if let since = entry.shutdownRequested, Date().timeIntervalSince(since) > 30 {
                            entry.shutdownRequested = nil
                            self.errorMessage = "„\(entry.config.name)“ reagiert nicht auf „Herunterfahren“, etwa solange noch die Firmware oder die Windows-Installation läuft. Mit „Ausschalten“ endet die VM sofort."
                        } else {
                            continue
                        }
                    }
                    if state == .stopped { entry.shutdownRequested = nil }
                    entry.state = state
                    if let info {
                        // Im DirectX-Modus kommt das Bild über SPICE (IOSurface), sonst über VNC.
                        // Der SPICE-Client wartet selbst, bis QEMU den Socket angelegt hat.
                        let spice = info.config?.graphics == .directX
                        let socket = spice ? info.sockets.spice : info.sockets.vnc
                        // Neu verbinden, wenn die Verbindung abgerissen ist, die VM aber noch läuft (z. B. nach
                        // einem schnellen Neustart über moonctl mit demselben Socket).
                        let newSession = entry.displaySocket != socket || entry.runtimePID != info.qemuPID
                        if newSession || entry.display.finished {
                            entry.displaySocket = socket
                            entry.runtimePID = info.qemuPID
                            if spice {
                                entry.display.connect(spicePath: socket, logURL: entry.bundle.url.appendingPathComponent("spice.log"))
                            } else {
                                entry.display.connect(socketPath: socket)
                            }
                            if newSession { self.connectAgent(entry, path: info.sockets.agent) }
                        }
                    } else if entry.displaySocket != nil {
                        entry.displaySocket = nil
                        entry.runtimePID = nil
                        entry.display.disconnect()
                        entry.agent?.stop()
                        entry.agent = nil
                        entry.display.agent = nil
                        entry.toolsActive = false
                        entry.gpuDriver = nil
                        entry.directXSetupRunning = false
                        entry.directXSetupTried = false
                        entry.toolsInstallRequested = false
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
                entry.toolsInstallRequested = false
                entry.toolsVersion = Int(argument)
                // Ältere Agenten ab Version 4 aktualisieren sich selbst.
                if let version = Int(argument), version >= 4, version < GuestTools.version {
                    entry.agent?.sendAgentUpdate()
                }
                if entry.config.usesVirtioGPU { self.applyResolution(entry) }
                if entry.config.graphics == .directX, (entry.toolsVersion ?? 0) >= 6 { entry.agent?.send("report") }
            case "report":
                guard let data = Data(base64Encoded: argument) else { return }
                try? data.write(to: entry.bundle.windowsReportURL, options: .atomic)
            case "clip":
                guard entry.config.sharedClipboard,
                      let data = Data(base64Encoded: argument),
                      let text = String(data: data, encoding: .utf8) else { return }
                self.lastClipboardFromGuest = text
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.pasteboardCount = NSPasteboard.general.changeCount
            case "gpu":
                entry.gpuDriver = argument
                // Der virtio-GPU-Treiber läuft: ab jetzt dynamische Auflösung (mit virtio-ramfb ändert das kein Gerät).
                if ["viogpudo", "viogpu3d"].contains(argument),
                   entry.config.guestOS == .windows11 && entry.config.graphics == .automatic {
                    var config = entry.config
                    config.graphics = .virtio
                    self.save(entry, config: config)
                    self.applyResolution(entry)
                }
                // DirectX gewählt, Triton aber noch nicht aktiv: einmal pro Sitzung einrichten lassen.
                if argument != "viogpu3d", !entry.directXSetupTried, entry.directXAutoSetups < 2, entry.canSetUpDirectX {
                    entry.directXAutoSetups += 1
                    self.setUpDirectX(entry)
                } else if argument == "viogpu3d" {
                    entry.directXSetupRunning = false
                    entry.directXAutoSetups = 0
                }
            case "gpu-setup":
                if argument == "missing-tools" {
                    entry.directXSetupRunning = false
                    self.errorMessage = "Für DirectX fehlen in Windows die aktuellen Moonvisor Tools. Wähle in der Menüleiste „Aktionen → Moonvisor Tools installieren“."
                }
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
            errorMessage = "Für Drag & Drop braucht die VM die neuen Moonvisor Tools. Wähle in der Menüleiste „Aktionen → Moonvisor Tools installieren“."
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
        entry.lastFailure = nil
        perform(entry, "Startet …") { bundle in
            if entry.config.graphics == .directX && entry.config.guestOS == .windows11 && DriverStore.cachedDirectXISO == nil {
                try Self.loadDirectXDrivers(for: entry)
            }
            let toolchain = try Toolchain.locate(requireTPM: entry.config.tpmEnabled)
            do {
                try VMRunner.start(bundle: bundle, toolchain: toolchain) { [weak self] status in
                    DispatchQueue.main.async { self?.vmExited(entry, status: status) }
                }
            } catch {
                DispatchQueue.main.async { entry.lastFailure = error.localizedDescription }
                throw error
            }
        }
    }

    /// QEMU ist beendet. Ein Fehlercode ohne vorheriges Herunterfahren heißt: die VM ist abgestürzt
    /// oder gar nicht erst hochgekommen. Das soll nicht still als „ausgeschaltet“ enden.
    private func vmExited(_ entry: VMEntry, status: Int32) {
        let expected = entry.state == .stopping
        refreshStates()
        guard status != 0, !expected else { return }
        let log = VMRunner.recentLog(of: entry.bundle)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let message = "\(entry.config.name) wurde unerwartet beendet (Code \(status), Moonvisor \(version))."
            + (log.isEmpty ? "" : "\n\n" + log)
        entry.lastFailure = message
        errorMessage = message
    }

    /// Lädt die DirectX-Treiber-CD vor dem ersten Start im DirectX-Modus (läuft auf der Arbeits-Queue).
    private static func loadDirectXDrivers(for entry: VMEntry) throws {
        let done = DispatchSemaphore(value: 0)
        final class Outcome: @unchecked Sendable { var error: Error? }
        let outcome = Outcome()
        Task {
            do {
                _ = try await DriverStore.ensureDirectXISO { value in
                    DispatchQueue.main.async { entry.busyMessage = "DirectX-Treiber werden geladen … \(Int(value * 100)) %" }
                }
            } catch {
                outcome.error = error
            }
            done.signal()
        }
        done.wait()
        DispatchQueue.main.async { entry.busyMessage = "Startet …" }
        if let error = outcome.error {
            throw MoonError.processFailed("DirectX-Treiber", DriverStore.describe(error))
        }
    }

    /// Öffnet `qemu.log` der VM (Konsole bzw. Texteditor), im DirectX-Modus auch `spice.log`.
    func openLog(_ entry: VMEntry) {
        NSWorkspace.shared.open(entry.bundle.logURL)
        if let start = try? Data(contentsOf: entry.bundle.startLogURL), !start.isEmpty {
            NSWorkspace.shared.open(entry.bundle.startLogURL)
        }
        guard entry.config.graphics == .directX else { return }
        let spice = entry.bundle.url.appendingPathComponent("spice.log")
        if FileManager.default.fileExists(atPath: spice.path) { NSWorkspace.shared.open(spice) }
        if FileManager.default.fileExists(atPath: entry.bundle.windowsReportURL.path) {
            NSWorkspace.shared.open(entry.bundle.windowsReportURL)
        }
        // Für das nächste Öffnen einen frischen Bericht anfordern.
        if (entry.toolsVersion ?? 0) >= 6 { entry.agent?.send("report") }
    }

    func shutdown(_ entry: VMEntry) {
        entry.state = .stopping
        entry.shutdownRequested = Date()
        perform(entry, nil) { bundle in
            try? VMRunner.captureThumbnail(bundle, timeout: 2)
            try VMRunner.shutdown(bundle)
        }
    }

    func powerOff(_ entry: VMEntry) {
        entry.state = .stopping
        perform(entry, "Wird ausgeschaltet …") { bundle in
            try? VMRunner.captureThumbnail(bundle, timeout: 2)
            try VMRunner.powerOff(bundle)
        }
    }

    func restart(_ entry: VMEntry) {
        entry.shutdownRequested = nil
        perform(entry, nil) { try VMRunner.restart($0) }
    }
    func pause(_ entry: VMEntry) { perform(entry, nil) { try VMRunner.pause($0) } }
    func resume(_ entry: VMEntry) { perform(entry, nil) { try VMRunner.resume($0) } }
    func ctrlAltDelete(_ entry: VMEntry) { perform(entry, nil) { try VMRunner.sendCtrlAltDelete($0) } }

    func takeSnapshot(_ entry: VMEntry, name: String) {
        perform(entry, "Schnappschuss wird erstellt …") { bundle in
            try Snapshots.create(bundle, name: name, toolchain: try Toolchain.locate(requireTPM: false))
        }
    }

    /// Installiert die Moonvisor Tools aus der App: öffnet in Windows „Ausführen“ und startet die Installation
    /// von der CD „MOONTOOLS“. Windows fragt danach einmal nach Administratorrechten.
    func installTools(_ entry: VMEntry) {
        guard entry.state == .running, entry.config.guestOS == .windows11 else { return }
        guard (GuestTools.discVersion(of: entry.bundle) ?? 0) >= GuestTools.firstDiscWithLauncher else {
            errorMessage = "Diese VM läuft noch mit der CD einer älteren Moonvisor-Version. Fahre Windows herunter, starte die VM wieder und wähle dann erneut „Moonvisor Tools installieren“."
            return
        }
        let layout = KeyMap.guestLayout
        entry.busyMessage = "Moonvisor Tools werden installiert …"
        let bundle = entry.bundle
        worker.async {
            do {
                try VMRunner.runInGuest(bundle, command: GuestKeyboard.installToolsCommand, layout: layout)
                DispatchQueue.main.async {
                    entry.busyMessage = nil
                    entry.toolsInstallRequested = true
                }
            } catch {
                DispatchQueue.main.async {
                    entry.busyMessage = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Startet die Einrichtung des DirectX-Treibers (Triton) in Windows über die Moonvisor Tools.
    func setUpDirectX(_ entry: VMEntry) {
        guard entry.canSetUpDirectX else { return }
        entry.directXSetupRunning = true
        entry.directXSetupTried = true
        entry.agent?.send("install-3d")
        // Meldet sich Windows nach einigen Minuten noch immer ohne Triton, ist die Einrichtung gescheitert:
        // dann wieder den Knopf anbieten.
        let started = Date()
        entry.directXSetupStarted = started
        DispatchQueue.main.asyncAfter(deadline: .now() + 6 * 60) { [weak entry] in
            guard let entry, entry.directXSetupStarted == started, entry.gpuDriver != "viogpu3d" else { return }
            entry.directXSetupRunning = false
        }
    }

    /// Feste Auflösung setzen oder (nil) wieder an das Fenster anpassen.
    func setResolution(_ entry: VMEntry, _ resolution: GuestResolution?) {
        var config = entry.config
        config.fixedResolution = resolution
        save(entry, config: config)
        applyResolution(entry)
    }

    /// Schickt die gewünschte Auflösung an die Moonvisor Tools.
    func applyResolution(_ entry: VMEntry) {
        if let fixed = entry.config.fixedResolution {
            entry.agent?.requestResolution(width: fixed.width, height: fixed.height)
        } else {
            entry.display.requestCurrentSize()
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
