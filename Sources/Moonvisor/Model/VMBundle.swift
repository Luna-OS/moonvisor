import Foundation

/// A virtual machine on disk: a `.moonvm` folder holding the disk image,
/// the platform files and `config.json`.
struct VMBundle: Hashable {
    static let fileExtension = "moonvm"

    let url: URL

    var configURL: URL { url.appendingPathComponent("config.json") }
    var diskURL: URL { url.appendingPathComponent("Disk.img") }
    var auxiliaryStorageURL: URL { url.appendingPathComponent("AuxiliaryStorage") }
    var hardwareModelURL: URL { url.appendingPathComponent("HardwareModel") }
    var machineIdentifierURL: URL { url.appendingPathComponent("MachineIdentifier") }
    var savedStateURL: URL { url.appendingPathComponent("SavedState.vzvmsave") }
    var snapshotsURL: URL { url.appendingPathComponent("Snapshots", isDirectory: true) }

    var hasSavedState: Bool { FileManager.default.fileExists(atPath: savedStateURL.path) }

    func loadConfig() throws -> VMConfig { try VMConfig.load(from: configURL) }
    func save(_ config: VMConfig) throws { try config.save(to: configURL) }
}

enum FileCloner {
    private static let cloneFlag = copyfile_flags_t(1 << 24) // COPYFILE_CLONE

    /// APFS clone when possible, so multi-GB disk images copy instantly and
    /// share blocks until they diverge. Falls back to a regular copy.
    static func clone(_ source: URL, to destination: URL) throws {
        guard copyfile(source.path, destination.path, nil, cloneFlag) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSFilePathErrorKey: destination.path,
            ])
        }
    }
}
