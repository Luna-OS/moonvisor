import Foundation
import MoonvisorCore

// moonctl – Kommandozeilensteuerung für Moonvisor (vergleichbar mit prlctl).

let usage = """
moonctl – Moonvisor über die Kommandozeile steuern

Verwendung:
  moonctl list                               Alle VMs mit Status
  moonctl info <vm>                          Konfiguration anzeigen
  moonctl doctor                             Prüft QEMU, swtpm und Firmware
  moonctl create-windows --iso <pfad> [--name N] [--user U] [--password P]
                         [--cpus 4] [--memory 4096] [--disk 64] [--edition pro|home] [--manual]
  moonctl import-parallels <pfad.pvm>        Parallels-VM übernehmen
  moonctl start <vm> [--wait]                Starten (mit --wait bis zum Ende warten)
  moonctl stop <vm> [--force]                Herunterfahren (--force: sofort aus)
  moonctl restart <vm>
  moonctl pause <vm> | resume <vm>
  moonctl ctrl-alt-del <vm>
  moonctl screenshot <vm> <datei.png>
  moonctl snapshot list|create|revert|delete <vm> [name]
  moonctl delete <vm>                        In den Papierkorb legen

<vm> ist der Name, der Anfang der UUID oder der Pfad zum .moonvm-Ordner.
"""

struct CLIError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

var args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func positional(_ index: Int, _ what: String) throws -> String {
    guard index < args.count else { throw CLIError(message: "Es fehlt: \(what)\n\n\(usage)") }
    return args[index]
}

func vm(_ index: Int = 1) throws -> VMBundle {
    let query = try positional(index, "<vm>")
    guard let bundle = VMLibrary.find(query) else { throw CLIError(message: "VM „\(query)“ nicht gefunden.") }
    return bundle
}

func run() throws {
    guard let command = args.first else {
        print(usage)
        return
    }
    switch command {
    case "list", "ls":
        let bundles = VMLibrary.list()
        if bundles.isEmpty { print("Keine VMs in \(VMLibrary.defaultFolder.path)") }
        for bundle in bundles {
            let config = try? bundle.loadConfig()
            let state = VMRunner.state(of: bundle)
            let id = config.map { String($0.id.uuidString.prefix(8)) } ?? "????????"
            print("\(id)  \(state.displayName.padding(toLength: 22, withPad: " ", startingAt: 0))  \(config?.name ?? bundle.url.lastPathComponent)")
        }

    case "info":
        let bundle = try vm()
        let config = try bundle.loadConfig()
        print("Name:        \(config.name)")
        print("ID:          \(config.id.uuidString)")
        print("System:      \(config.guestOS.displayName)")
        print("Status:      \(VMRunner.state(of: bundle).displayName)")
        print("CPU / RAM:   \(config.cpuCount) Kerne, \(config.memoryMB) MB")
        print("Festplatte:  \(config.diskSizeGB) GB (belegt: \(formatBytes(allocatedSize(of: bundle.diskURL))))")
        print("Netzwerk:    \(config.networkMode.displayName)")
        print("TPM 2.0:     \(config.tpmEnabled ? "ja" : "nein")")
        if config.installMediaAttached, let iso = config.installMediaPath { print("CD/DVD:      \(iso)") }
        print("Ordner:      \(bundle.url.path)")

    case "doctor":
        let s = Toolchain.status()
        print("Apple Silicon: \(Toolchain.isAppleSilicon ? "ja" : "NEIN – Moonvisor benötigt einen Mac mit Apple-Chip")")
        print("QEMU:          \(s.qemu?.path ?? "fehlt")")
        print("qemu-img:      \(s.qemuImg?.path ?? "fehlt")")
        print("swtpm:         \(s.swtpm?.path ?? "fehlt")")
        print("UEFI:          \(s.firmware?.path ?? "fehlt")")
        print("Treiber-CD:    \(DriverStore.cachedVirtioISO?.path ?? "noch nicht geladen")")
        if !s.isComplete { print("\nInstallieren mit: \(Toolchain.brewInstallCommand)") }

    case "create-windows":
        let iso = option("--iso")
        let name = option("--name") ?? "Windows 11"
        let user = option("--user") ?? NSUserName()
        let password = option("--password") ?? ""
        let cpus = Int(option("--cpus") ?? "") ?? min(4, Toolchain.hostCPUCount / 2)
        let memory = Int(option("--memory") ?? "") ?? 4096
        let disk = Int(option("--disk") ?? "") ?? 64
        let edition = WindowsEdition(rawValue: option("--edition") ?? "pro") ?? .pro
        let manual = flag("--manual")
        guard let iso else { throw CLIError(message: "--iso <pfad> fehlt") }
        let toolchain = try Toolchain.locate()
        if DriverStore.cachedVirtioISO == nil {
            print("Lade Treiber-CD (virtio-win) …")
            let semaphore = DispatchSemaphore(value: 0)
            var failure: Error?
            Task {
                do { _ = try await DriverStore.ensureVirtioISO { _ in } } catch { failure = error }
                semaphore.signal()
            }
            semaphore.wait()
            if let failure { throw failure }
        }
        let isoURL = URL(fileURLWithPath: (iso as NSString).expandingTildeInPath)
        let express = ExpressInstallOptions(userName: user, password: password, computerName: name, edition: edition,
                                            locale: WindowsLocale.guess(isoPath: isoURL.path))
        let request = CreateRequest(name: name, guestOS: .windows11, installMedia: isoURL, cpuCount: cpus, memoryMB: memory,
                                    diskSizeGB: disk, profile: .custom, installMode: manual ? .manual : .express,
                                    express: manual ? nil : express)
        let bundle = try VMFactory.create(request, toolchain: toolchain) { print($0) }
        print("Erstellt: \(bundle.url.path)\nStarten mit: moonctl start \"\(name)\"")

    case "import-parallels":
        let path = try positional(1, "<pfad.pvm>")
        let toolchain = try Toolchain.locate(requireTPM: false)
        let bundle = try ParallelsImporter.importVM(URL(fileURLWithPath: (path as NSString).expandingTildeInPath), toolchain: toolchain) { print($0) }
        print("Importiert: \(bundle.url.path)")

    case "start":
        let wait = flag("--wait")
        let bundle = try vm()
        let toolchain = try Toolchain.locate(requireTPM: (try bundle.loadConfig()).tpmEnabled)
        let done = DispatchSemaphore(value: 0)
        let info = try VMRunner.start(bundle: bundle, toolchain: toolchain) { status in
            print("VM beendet (Status \(status)).")
            done.signal()
        }
        print("Gestartet (PID \(info.qemuPID)). Bildschirm: Moonvisor-App oder VNC-Socket \(info.sockets.vnc)")
        if wait {
            done.wait()
        } else {
            // Kurz warten, damit z. B. der automatische CD-Boot-Tastendruck abgeschlossen wird.
            Thread.sleep(forTimeInterval: (try bundle.loadConfig()).installMediaAttached ? 17 : 1)
        }

    case "stop":
        let force = flag("--force")
        let bundle = try vm()
        if force {
            try VMRunner.powerOff(bundle)
        } else {
            try VMRunner.shutdown(bundle)
            print("Herunterfahren angefordert …")
            if !VMRunner.waitUntilStopped(bundle, timeout: 120) {
                print("Die VM reagiert nicht. Mit --force sofort ausschalten.")
            }
        }

    case "restart": try VMRunner.restart(try vm())
    case "pause": try VMRunner.pause(try vm())
    case "resume": try VMRunner.resume(try vm())
    case "ctrl-alt-del": try VMRunner.sendCtrlAltDelete(try vm())

    case "screenshot":
        let bundle = try vm()
        let file = try positional(2, "<datei.png>")
        try VMRunner.withQMP(bundle) { try $0.screendump(to: URL(fileURLWithPath: (file as NSString).expandingTildeInPath).standardizedFileURL) }

    case "snapshot":
        let sub = try positional(1, "list|create|revert|delete")
        let bundle = try vm(2)
        let toolchain = try Toolchain.locate(requireTPM: false)
        switch sub {
        case "list":
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            for snap in try Snapshots.list(bundle, toolchain: toolchain) {
                print("\(snap.name)\t\(snap.date.map(formatter.string) ?? "")\t\(snap.vmStateSize)")
            }
        case "create": try Snapshots.create(bundle, name: try positional(3, "[name]"), toolchain: toolchain)
        case "revert": try Snapshots.revert(bundle, name: try positional(3, "[name]"), toolchain: toolchain)
        case "delete": try Snapshots.delete(bundle, name: try positional(3, "[name]"), toolchain: toolchain)
        default: throw CLIError(message: usage)
        }

    case "delete":
        try VMLibrary.moveToTrash(try vm())

    case "help", "-h", "--help":
        print(usage)

    default:
        throw CLIError(message: "Unbekannter Befehl „\(command)“.\n\n\(usage)")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("Fehler: \(error.localizedDescription)\n".utf8))
    exit(1)
}
