import Foundation

/// Gastbetriebssystem einer VM. Bestimmt Geräteauswahl und Installationsweg.
public enum GuestOS: String, Codable, CaseIterable, Sendable {
    case windows11
    case linux
    case other

    public var displayName: String {
        switch self {
        case .windows11: return "Windows 11"
        case .linux: return "Linux"
        case .other: return "Anderes Betriebssystem"
        }
    }
}

public enum NetworkMode: String, Codable, CaseIterable, Sendable {
    /// NAT über QEMU-Usermode-Netz: Gast kommt ins Internet, Host erreicht den Gast über Portweiterleitungen.
    case shared
    /// vmnet (gemeinsam): Gast bekommt eine eigene IP-Adresse, die der Mac direkt erreicht.
    case vmnet
    /// vmnet (Bridge): Gast hängt direkt im lokalen Netz, wie ein eigener Rechner.
    case bridged
    case disconnected

    public var displayName: String {
        switch self {
        case .shared: return "Gemeinsames Netzwerk (NAT)"
        case .vmnet: return "Eigene IP-Adresse (vom Mac erreichbar)"
        case .bridged: return "Bridge (im lokalen Netz)"
        case .disconnected: return "Getrennt"
        }
    }

    /// Braucht den vmnet-Dienst (läuft mit Administratorrechten).
    public var usesVMNet: Bool { self == .vmnet || self == .bridged }
}

public struct PortForward: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(proto)-\(hostPort)" }
    public var proto: String
    public var hostPort: Int
    public var guestPort: Int

    public init(proto: String = "tcp", hostPort: Int, guestPort: Int) {
        self.proto = proto
        self.hostPort = hostPort
        self.guestPort = guestPort
    }
}

public enum GraphicsMode: String, Codable, CaseIterable, Sendable {
    /// Windows: einfacher Framebuffer (läuft ohne Treiber), Linux: virtio-gpu.
    case automatic
    /// Einfacher Framebuffer (ramfb), feste Auflösung.
    case basic
    /// virtio-gpu mit Treiber: Auflösung passt sich dem Fenster an.
    case virtio
    /// virtio-gpu mit 3D (Neptune): DirectX 11 über DXMT/Metal, Triton-Treiber im Gast. Experimentell.
    case directX

    public var displayName: String {
        switch self {
        case .automatic: return "Automatisch"
        case .basic: return "Basis (ohne Treiber)"
        case .virtio: return "virtio-GPU (dynamische Auflösung)"
        case .directX: return "DirectX 11 (experimentell)"
        }
    }

    /// Im Menü wählbar. DirectX gibt es nur mit der Moonvisor-Engine.
    public static func selectable(directX: Bool) -> [GraphicsMode] {
        directX ? [.automatic, .basic, .virtio, .directX] : [.automatic, .basic, .virtio]
    }
}

/// Ressourcenprofil wie im Installationsassistenten.
public enum ResourceProfile: String, Codable, CaseIterable, Sendable {
    case productivity, development, gaming, custom

    public var displayName: String {
        switch self {
        case .productivity: return "Produktivität"
        case .development: return "Software-Entwicklung"
        case .gaming: return "Nur Spiele"
        case .custom: return "Benutzerdefiniert"
        }
    }

    public var detail: String {
        switch self {
        case .productivity: return "Office, Browser und Alltags-Apps"
        case .development: return "Mehr Kerne und RAM für Compiler und IDEs"
        case .gaming: return "Maximale Leistung für Spiele"
        case .custom: return "Werte selbst festlegen"
        }
    }

    /// Vorschlag abhängig von der Host-Hardware.
    public func suggestion(hostCPUs: Int, hostMemoryMB: Int) -> (cpus: Int, memoryMB: Int) {
        let half = max(2, hostCPUs / 2)
        switch self {
        case .productivity:
            return (min(4, half), clampMemory(4096, host: hostMemoryMB))
        case .development:
            return (max(2, hostCPUs - 2), clampMemory(8192, host: hostMemoryMB))
        case .gaming:
            return (max(2, hostCPUs - 2), clampMemory(8192, host: hostMemoryMB))
        case .custom:
            return (min(4, half), clampMemory(4096, host: hostMemoryMB))
        }
    }

    private func clampMemory(_ wanted: Int, host: Int) -> Int {
        // Dem Mac immer mindestens die Hälfte lassen.
        min(wanted, max(2048, host / 2))
    }
}

public enum InstallMode: String, Codable, Sendable {
    /// Vollautomatisch: Partitionierung, Benutzerkonto, Treiber.
    case express
    /// Nur Hardwareprüfungen überspringen, Rest macht der Benutzer.
    case manual
    /// Keine Installationshilfe (z. B. importierte oder Linux-VM).
    case none
}

public struct VMConfig: Codable, Hashable, Sendable, Identifiable {
    public static let currentVersion = 1

    public var version: Int = VMConfig.currentVersion
    public var id: UUID
    public var name: String
    public var guestOS: GuestOS
    public var notes: String = ""
    public var createdAt: Date

    public var cpuCount: Int
    public var memoryMB: Int
    public var diskSizeGB: Int
    public var profile: ResourceProfile = .productivity

    public var networkMode: NetworkMode = .shared
    public var portForwards: [PortForward] = []
    /// Netzwerkschnittstelle des Macs für den Bridge-Modus.
    public var bridgeInterface: String = "en0"
    public var macAddress: String
    public var soundEnabled: Bool = true
    public var tpmEnabled: Bool = true

    /// Installationsmedium (ISO). Wird nach der Installation ausgeworfen.
    public var installMediaPath: String?
    public var installMediaAttached: Bool = false
    /// Beim nächsten Start automatisch "Taste drücken, um von CD zu starten" bestätigen.
    public var autoConfirmCDBoot: Bool = false
    public var installMode: InstallMode = .none
    public var attachDriversDisc: Bool = false

    /// Startet die VM, wenn ihr Fenster geöffnet wird.
    public var startOnOpen: Bool = false
    /// Mac-Befehlstaste als Strg an den Gast schicken (Parallels-Standard) statt als Windows-Taste.
    public var commandAsControl: Bool = false
    public var graphics: GraphicsMode = .automatic
    /// Text-Zwischenablage mit dem Gast teilen (benötigt Moonvisor Tools).
    public var sharedClipboard: Bool = true
    /// Beim nächsten Start diesen Schnappschuss samt Arbeitsspeicher laden.
    public var resumeSnapshot: String?

    public init(
        id: UUID = UUID(),
        name: String,
        guestOS: GuestOS,
        cpuCount: Int,
        memoryMB: Int,
        diskSizeGB: Int,
        createdAt: Date = Date(),
        macAddress: String = VMConfig.randomMAC()
    ) {
        self.id = id
        self.name = name
        self.guestOS = guestOS
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.diskSizeGB = diskSizeGB
        self.createdAt = createdAt
        self.macAddress = macAddress
    }

    enum CodingKeys: String, CodingKey {
        case version, id, name, guestOS, notes, createdAt, cpuCount, memoryMB, diskSizeGB, profile
        case networkMode, portForwards, bridgeInterface, macAddress, soundEnabled, tpmEnabled
        case installMediaPath, installMediaAttached, autoConfirmCDBoot, installMode, attachDriversDisc
        case startOnOpen, commandAsControl, graphics, sharedClipboard, resumeSnapshot
    }

    /// Fehlende Felder (ältere Konfigurationen) bekommen ihren Standardwert.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        guestOS = try c.decodeIfPresent(GuestOS.self, forKey: .guestOS) ?? .other
        cpuCount = try c.decodeIfPresent(Int.self, forKey: .cpuCount) ?? 2
        memoryMB = try c.decodeIfPresent(Int.self, forKey: .memoryMB) ?? 4096
        diskSizeGB = try c.decodeIfPresent(Int.self, forKey: .diskSizeGB) ?? 64
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress) ?? VMConfig.randomMAC()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? VMConfig.currentVersion
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        profile = try c.decodeIfPresent(ResourceProfile.self, forKey: .profile) ?? .custom
        networkMode = try c.decodeIfPresent(NetworkMode.self, forKey: .networkMode) ?? .shared
        portForwards = try c.decodeIfPresent([PortForward].self, forKey: .portForwards) ?? []
        bridgeInterface = try c.decodeIfPresent(String.self, forKey: .bridgeInterface) ?? "en0"
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
        tpmEnabled = try c.decodeIfPresent(Bool.self, forKey: .tpmEnabled) ?? (guestOS == .windows11)
        installMediaPath = try c.decodeIfPresent(String.self, forKey: .installMediaPath)
        installMediaAttached = try c.decodeIfPresent(Bool.self, forKey: .installMediaAttached) ?? false
        autoConfirmCDBoot = try c.decodeIfPresent(Bool.self, forKey: .autoConfirmCDBoot) ?? false
        installMode = try c.decodeIfPresent(InstallMode.self, forKey: .installMode) ?? .none
        attachDriversDisc = try c.decodeIfPresent(Bool.self, forKey: .attachDriversDisc) ?? false
        startOnOpen = try c.decodeIfPresent(Bool.self, forKey: .startOnOpen) ?? false
        commandAsControl = try c.decodeIfPresent(Bool.self, forKey: .commandAsControl) ?? false
        graphics = try c.decodeIfPresent(GraphicsMode.self, forKey: .graphics) ?? .automatic
        sharedClipboard = try c.decodeIfPresent(Bool.self, forKey: .sharedClipboard) ?? true
        resumeSnapshot = try c.decodeIfPresent(String.self, forKey: .resumeSnapshot)
    }

    /// Lokal administrierte Unicast-MAC im QEMU-Präfix 52:54:00.
    public static func randomMAC() -> String {
        let bytes = (0..<3).map { _ in UInt8.random(in: 0...255) }
        return (["52", "54", "00"] + bytes.map { String(format: "%02x", $0) }).joined(separator: ":")
    }
}

/// Eine VM auf der Festplatte: ein Ordner `Name.moonvm` mit Konfiguration, Disk, EFI-Variablen und TPM-Zustand.
public struct VMBundle: Hashable, Sendable, Identifiable {
    public static let pathExtension = "moonvm"

    public let url: URL
    public var id: String { url.path }

    public init(url: URL) {
        self.url = url
    }

    public var configURL: URL { url.appendingPathComponent("config.json") }
    public var diskURL: URL { url.appendingPathComponent("disk.qcow2") }
    /// UEFI-Variablen als qcow2, damit Schnappschüsse der laufenden VM möglich sind.
    public var efiVarsURL: URL { url.appendingPathComponent("efi-vars.qcow2") }
    /// Ältere VMs speicherten die Variablen roh.
    var legacyEfiVarsURL: URL { url.appendingPathComponent("efi-vars.fd") }
    public var tpmStateURL: URL { url.appendingPathComponent("tpm", isDirectory: true) }
    public var setupDiscURL: URL { url.appendingPathComponent("moon-setup.iso") }
    public var toolsDiscURL: URL { url.appendingPathComponent("moon-tools.iso") }
    public var runtimeURL: URL { url.appendingPathComponent("runtime.json") }
    public var thumbnailURL: URL { url.appendingPathComponent("thumbnail.png") }
    /// Hardware-Konfiguration je Schnappschuss mit Arbeitsspeicher.
    public var snapshotConfigsURL: URL { url.appendingPathComponent("snapshots", isDirectory: true) }
    public var logURL: URL { url.appendingPathComponent("qemu.log") }

    public func loadConfig() throws -> VMConfig {
        let data = try Data(contentsOf: configURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VMConfig.self, from: data)
    }

    public func saveConfig(_ config: VMConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }
}

extension VMConfig {
    /// Ob die VM mit virtio-GPU startet (dann ist die Auflösung veränderbar).
    public var usesVirtioGPU: Bool {
        switch graphics {
        case .virtio, .directX: return true
        case .basic: return false
        case .automatic: return guestOS != .windows11
        }
    }
}
