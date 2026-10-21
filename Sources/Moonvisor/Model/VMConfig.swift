import Foundation
import Virtualization

struct SharedFolder: Codable, Hashable, Identifiable {
    var id = UUID()
    var path: String
    var readOnly = false

    var url: URL { URL(fileURLWithPath: path) }
}

struct DisplaySize: Codable, Hashable {
    var width: Int
    var height: Int
    var ppi: Int

    static let standard = DisplaySize(width: 1920, height: 1200, ppi: 80)
}

struct DisplayPreset: Identifiable {
    let name: String
    let size: DisplaySize
    var id: String { name }

    static let all: [DisplayPreset] = [
        DisplayPreset(name: "1920 × 1200", size: .standard),
        DisplayPreset(name: "1280 × 800", size: DisplaySize(width: 1280, height: 800, ppi: 80)),
        DisplayPreset(name: "1440 × 900 Retina", size: DisplaySize(width: 2880, height: 1800, ppi: 144)),
        DisplayPreset(name: "1728 × 1117 Retina", size: DisplaySize(width: 3456, height: 2234, ppi: 144)),
    ]
}

/// Persisted as `config.json` inside the VM bundle.
struct VMConfig: Codable, Hashable {
    var name: String
    var cpuCount: Int
    var memoryGB: Int
    var diskGB: Int
    var display = DisplaySize.standard
    var sharedFolders: [SharedFolder] = []
    var macAddress: String
    var osVersion: String?
    var created = Date()

    static func makeDefault(name: String) -> VMConfig {
        VMConfig(
            name: name,
            cpuCount: HostLimits.defaultCPU,
            memoryGB: HostLimits.defaultMemoryGB,
            diskGB: 64,
            macAddress: VZMACAddress.randomLocallyAdministered().string
        )
    }
}

extension VMConfig {
    // Tolerates configs written by older versions that lack newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        cpuCount = try c.decode(Int.self, forKey: .cpuCount)
        memoryGB = try c.decode(Int.self, forKey: .memoryGB)
        diskGB = try c.decode(Int.self, forKey: .diskGB)
        display = try c.decodeIfPresent(DisplaySize.self, forKey: .display) ?? .standard
        sharedFolders = try c.decodeIfPresent([SharedFolder].self, forKey: .sharedFolders) ?? []
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress)
            ?? VZMACAddress.randomLocallyAdministered().string
        osVersion = try c.decodeIfPresent(String.self, forKey: .osVersion)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
    }

    static func load(from url: URL) throws -> VMConfig {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VMConfig.self, from: Data(contentsOf: url))
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

enum HostLimits {
    static let gib: UInt64 = 1 << 30
    static let minMemoryGB = 2

    static var maxCPU: Int {
        max(1, min(ProcessInfo.processInfo.processorCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
    }

    /// Leaves 2 GB for the host.
    static var maxMemoryGB: Int {
        let physical = ProcessInfo.processInfo.physicalMemory
        let usable = physical > 4 * gib ? physical - 2 * gib : physical / 2
        return max(minMemoryGB, Int(min(usable, VZVirtualMachineConfiguration.maximumAllowedMemorySize) / gib))
    }

    static var defaultCPU: Int { min(maxCPU, max(2, maxCPU / 2)) }

    static var defaultMemoryGB: Int {
        min(maxMemoryGB, max(4, Int(ProcessInfo.processInfo.physicalMemory / gib) / 2))
    }
}

enum MoonvisorError: LocalizedError {
    case unsupportedHost
    case unsupportedHardwareModel
    case invalidMachineIdentifier
    case noSupportedConfiguration(String)
    case machineActive
    case downloadFailed(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedHost:
            return "This Mac can't run virtual machines. Moonvisor needs a Mac with Apple silicon."
        case .unsupportedHardwareModel:
            return "This virtual machine was created for hardware this Mac doesn't support."
        case .invalidMachineIdentifier:
            return "The machine identifier of this virtual machine is damaged."
        case .noSupportedConfiguration(let version):
            return "macOS \(version) can't be installed on this Mac. Try a newer restore image."
        case .machineActive:
            return "Shut down the virtual machine first."
        case .downloadFailed(let status):
            return "The download failed (HTTP \(status))."
        }
    }
}
