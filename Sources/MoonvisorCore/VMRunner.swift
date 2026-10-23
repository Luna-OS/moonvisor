import Foundation

/// Laufzeitdaten einer gestarteten VM. Liegt als `runtime.json` im VM-Ordner, damit App und `moonctl`
/// dieselbe laufende VM finden und steuern können.
public struct RuntimeInfo: Codable, Sendable {
    public var qemuPID: Int32
    public var swtpmPID: Int32?
    public var sockets: RuntimeSockets
    public var startedAt: Date
    /// Konfiguration, mit der die VM gestartet wurde (Änderungen gelten erst beim nächsten Start).
    public var config: VMConfig?
}

public enum VMRunState: String, Sendable {
    case stopped, starting, running, paused, stopping

    public var displayName: String {
        switch self {
        case .stopped: return "Ausgeschaltet"
        case .starting: return "Startet …"
        case .running: return "Läuft"
        case .paused: return "Angehalten"
        case .stopping: return "Wird heruntergefahren …"
        }
    }
}

public enum VMRunner {
    static func processAlive(_ pid: Int32) -> Bool {
        pid > 0 && kill(pid, 0) == 0
    }

    /// Laufende Instanz dieser VM, falls vorhanden. Veraltete Laufzeitdaten werden entfernt.
    public static func runtime(of bundle: VMBundle) -> RuntimeInfo? {
        guard let data = try? Data(contentsOf: bundle.runtimeURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let info = try? decoder.decode(RuntimeInfo.self, from: data) else { return nil }
        if processAlive(info.qemuPID) && FileManager.default.fileExists(atPath: info.sockets.qmp) {
            return info
        }
        cleanup(bundle: bundle, info: info)
        return nil
    }

    static func cleanup(bundle: VMBundle, info: RuntimeInfo?) {
        try? FileManager.default.removeItem(at: bundle.runtimeURL)
        if let info {
            if let tpm = info.swtpmPID, processAlive(tpm) { kill(tpm, SIGTERM) }
            try? FileManager.default.removeItem(atPath: info.sockets.directory)
        }
    }

    public static func state(of bundle: VMBundle) -> VMRunState {
        guard let info = runtime(of: bundle) else { return .stopped }
        guard let qmp = try? QMPClient(path: info.sockets.qmp) else { return .starting }
        defer { qmp.close() }
        switch (try? qmp.status()) ?? "running" {
        case "paused", "suspended": return .paused
        case "shutdown": return .stopping
        case "inmigrate", "prelaunch": return .starting
        default: return .running
        }
    }

    static func waitFor(path: String, process: Process, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return true }
            if !process.isRunning { return false }
            usleep(50_000)
        }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Letzte Zeilen aus `qemu.log` (für Fehlermeldungen in der App).
    public static func recentLog(of bundle: VMBundle) -> String {
        logTail(bundle.logURL)
    }

    static func logTail(_ url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return relevantLines(text)
    }

    /// Die letzten aussagekräftigen Zeilen: Debug-Ausgaben des 3D-Renderers und Aufräummeldungen beim Beenden
    /// verdecken sonst die eigentliche Fehlermeldung.
    static func relevantLines(_ text: String, count: Int = 8) -> String {
        let noise = ["<Debug>", "swtpm: Data client disconnected"]
        let lines = text.split(separator: "\n").filter { line in !noise.contains { line.contains($0) } }
        return lines.suffix(count).joined(separator: "\n")
    }

    /// Startet die VM. Die Prozesse laufen unabhängig vom Aufrufer weiter (wie bei Parallels' VM-Prozess),
    /// `onExit` wird aufgerufen, wenn QEMU endet, sofern der Aufrufer dann noch lebt.
    @discardableResult
    public static func start(
        bundle: VMBundle,
        toolchain: Toolchain,
        onExit: (@Sendable (Int32) -> Void)? = nil
    ) throws -> RuntimeInfo {
        if runtime(of: bundle) != nil { throw MoonError.alreadyRunning }
        var config = try bundle.loadConfig()
        let fm = FileManager.default

        if let service = VMNet.service(for: config), !service.isRunning {
            throw MoonError.vmnetMissing(config.networkMode.displayName)
        }
        if config.graphics == .directX && !toolchain.supportsDirectX {
            throw MoonError.directXUnavailable
        }

        Installation.prepareForBoot(bundle: bundle, config: &config)

        let sockets = RuntimeSockets.make(for: config.id)
        try? fm.removeItem(atPath: sockets.directory)
        try fm.createDirectory(atPath: sockets.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        try toolchain.prepareEFIVars(for: bundle)

        fm.createFile(atPath: bundle.logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: bundle.logURL)

        var extraDiscs: [URL] = []
        if fm.fileExists(atPath: bundle.setupDiscURL.path) && config.installMediaAttached {
            extraDiscs.append(bundle.setupDiscURL)
        }
        if config.guestOS == .windows11 {
            try GuestTools.ensureDisc(for: bundle)
            extraDiscs.append(bundle.toolsDiscURL)
        }
        if config.attachDriversDisc, let drivers = DriverStore.cachedVirtioISO {
            extraDiscs.append(drivers)
        }
        // DirectX: Triton-Treiber als CD, die Moonvisor Tools richten ihn in Windows ein.
        if config.graphics == .directX, config.guestOS == .windows11, let directX = DriverStore.cachedDirectXISO {
            extraDiscs.append(directX)
        }
        var command = QEMUCommand(config: config, bundle: bundle, toolchain: toolchain, sockets: sockets, extraDiscs: extraDiscs)
        // Ein Schnappschuss mit Arbeitsspeicher wird beim Start geladen. Das Laden in eine laufende VM
        // (loadvm) bringt QEMU 11 mit HVF zum Absturz, ein frischer Start mit -loadvm dagegen nicht.
        if let resume = config.resumeSnapshot {
            command.loadSnapshot = resume
            config.resumeSnapshot = nil
            config.autoConfirmCDBoot = false
            try? bundle.saveConfig(config)
        }

        var swtpm: Process?
        if config.tpmEnabled {
            guard let swtpmURL = toolchain.swtpm else { throw ToolchainError.missing(["swtpm (TPM 2.0)"]) }
            try fm.createDirectory(at: bundle.tpmStateURL, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = swtpmURL
            p.arguments = command.swtpmArguments
            p.standardOutput = log
            p.standardError = log
            try p.run()
            guard waitFor(path: sockets.tpm, process: p, seconds: 5) else {
                p.terminate()
                throw MoonError.processFailed("swtpm", logTail(bundle.logURL))
            }
            swtpm = p
        }

        let qemu = Process()
        qemu.executableURL = toolchain.qemuSystem
        qemu.arguments = command.arguments
        qemu.environment = command.environment
        qemu.currentDirectoryURL = bundle.url
        qemu.standardOutput = log
        qemu.standardError = log
        let swtpmRef = swtpm
        qemu.terminationHandler = { process in
            if let swtpmRef, swtpmRef.isRunning { swtpmRef.terminate() }
            cleanup(bundle: bundle, info: nil)
            try? FileManager.default.removeItem(atPath: sockets.directory)
            onExit?(process.terminationStatus)
        }
        try qemu.run()

        guard waitFor(path: sockets.qmp, process: qemu, seconds: 15) else {
            if qemu.isRunning { qemu.terminate() }
            swtpm?.terminate()
            throw MoonError.processFailed("QEMU", logTail(bundle.logURL))
        }

        let info = RuntimeInfo(qemuPID: qemu.processIdentifier, swtpmPID: swtpm?.processIdentifier, sockets: sockets,
                               startedAt: Date(), config: config)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(info).write(to: bundle.runtimeURL, options: .atomic)

        if config.autoConfirmCDBoot {
            config.autoConfirmCDBoot = false
            try? bundle.saveConfig(config)
            confirmCDBootPrompt(sockets: sockets)
        }
        return info
    }

    /// Der Windows-Bootloader auf der CD wartet einige Sekunden auf einen Tastendruck.
    /// Wie Parallels drücken wir in den ersten Sekunden wiederholt eine Taste.
    static func confirmCDBootPrompt(sockets: RuntimeSockets) {
        Thread.detachNewThread {
            guard let qmp = try? QMPClient(path: sockets.qmp) else { return }
            defer { qmp.close() }
            let start = Date()
            while Date().timeIntervalSince(start) < 16 {
                try? qmp.sendKeys(["ret"], holdMillis: 60)
                usleep(400_000)
            }
        }
    }

    public static func withQMP<T>(_ bundle: VMBundle, _ body: (QMPClient) throws -> T) throws -> T {
        guard let info = runtime(of: bundle) else { throw MoonError.notRunning }
        let qmp = try QMPClient(path: info.sockets.qmp)
        defer { qmp.close() }
        return try body(qmp)
    }

    /// ACPI-Ausschalter: Windows fährt sauber herunter.
    public static func shutdown(_ bundle: VMBundle) throws {
        try withQMP(bundle) { try $0.execute("system_powerdown") }
    }

    /// Sofort ausschalten (wie Stecker ziehen).
    public static func powerOff(_ bundle: VMBundle) throws {
        guard let info = runtime(of: bundle) else { throw MoonError.notRunning }
        if let qmp = try? QMPClient(path: info.sockets.qmp) {
            _ = try? qmp.execute("quit")
            qmp.close()
        }
        let deadline = Date().addingTimeInterval(5)
        while processAlive(info.qemuPID) && Date() < deadline { usleep(100_000) }
        if processAlive(info.qemuPID) { kill(info.qemuPID, SIGKILL) }
        cleanup(bundle: bundle, info: info)
    }

    public static func restart(_ bundle: VMBundle) throws {
        try withQMP(bundle) { try $0.execute("system_reset") }
    }

    public static func pause(_ bundle: VMBundle) throws {
        try withQMP(bundle) { try $0.execute("stop") }
    }

    public static func resume(_ bundle: VMBundle) throws {
        try withQMP(bundle) { try $0.execute("cont") }
    }

    public static func sendCtrlAltDelete(_ bundle: VMBundle) throws {
        try withQMP(bundle) { try $0.sendKeys(["ctrl", "alt", "delete"]) }
    }

    /// Öffnet in Windows „Ausführen“ (Windows+R), tippt `command` und bestätigt mit Enter.
    public static func runInGuest(_ bundle: VMBundle, command: String, layout: GuestKeyboard.Layout) throws {
        let strokes = try GuestKeyboard.keystrokes(for: command, layout: layout)
        try withQMP(bundle) { qmp in
            try qmp.sendKeys(["meta_l", "r"])
            Thread.sleep(forTimeInterval: 1.5)
            for keys in strokes {
                try qmp.sendKeys(keys, holdMillis: 20)
            }
            Thread.sleep(forTimeInterval: 0.3)
            try qmp.sendKeys(["ret"])
        }
    }

    public static func captureThumbnail(_ bundle: VMBundle) throws {
        try withQMP(bundle) { try $0.screendump(to: bundle.thumbnailURL) }
    }

    /// Wartet, bis die VM beendet ist.
    public static func waitUntilStopped(_ bundle: VMBundle, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if runtime(of: bundle) == nil { return true }
            usleep(250_000)
        }
        return runtime(of: bundle) == nil
    }
}
