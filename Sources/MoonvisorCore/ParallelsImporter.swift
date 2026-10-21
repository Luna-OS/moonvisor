import Foundation

/// Liest die öffentlich sichtbare VM-Beschreibung einer Parallels-VM (`.pvm/config.pvs`, XML)
/// und übernimmt Name, CPU, RAM und Festplatte. Die Festplatte (`.hdd` mit `.hds`-Daten)
/// wird mit `qemu-img` nach qcow2 konvertiert; die Parallels-VM bleibt unverändert.
public struct ParallelsVMInfo: Sendable {
    public var name: String
    public var cpuCount: Int
    public var memoryMB: Int
    public var isWindows: Bool
    public var diskImages: [URL]
    public var diskSizeBytes: Int64?
}

public enum ParallelsImporter {
    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Parallels", isDirectory: true)
    }

    public static func discover() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: defaultFolder, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "pvm" }
    }

    public static func inspect(_ pvm: URL) throws -> ParallelsVMInfo {
        let configURL = pvm.appendingPathComponent("config.pvs")
        guard let doc = try? XMLDocument(contentsOf: configURL) else {
            throw MoonError.invalidBundle(pvm.path)
        }
        func value(_ xpath: String) -> String? {
            (try? doc.nodes(forXPath: xpath))?.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let name = value("/ParallelsVirtualMachine/Identification/VmName") ?? pvm.deletingPathExtension().lastPathComponent
        let cpus = Int(value("/ParallelsVirtualMachine/Hardware/Cpu/Number") ?? "") ?? 2
        let ram = Int(value("/ParallelsVirtualMachine/Hardware/Memory/RAM") ?? "") ?? 4096
        // OsType 8 steht in Parallels-Konfigurationen für Windows.
        let osType = value("/ParallelsVirtualMachine/Settings/General/OsType") ?? value("//OsType")
        let isWindows = osType == "8" || name.lowercased().contains("windows")

        var images: [URL] = []
        var size: Int64?
        let hddNodes = (try? doc.nodes(forXPath: "/ParallelsVirtualMachine/Hardware/Hdd")) ?? []
        for node in hddNodes {
            guard let element = node as? XMLElement,
                  element.elements(forName: "Enabled").first?.stringValue != "0",
                  let systemName = element.elements(forName: "SystemName").first?.stringValue else { continue }
            let hdd = systemName.hasPrefix("/") ? URL(fileURLWithPath: systemName) : pvm.appendingPathComponent(systemName)
            if let (image, bytes) = topImage(of: hdd) {
                images.append(image)
                if size == nil { size = bytes }
            }
        }
        return ParallelsVMInfo(name: name, cpuCount: cpus, memoryMB: ram, isWindows: isWindows, diskImages: images, diskSizeBytes: size)
    }

    /// Die oberste Datendatei laut `DiskDescriptor.xml` (bei Snapshots die zuletzt geschriebene).
    static func topImage(of hdd: URL) -> (URL, Int64?)? {
        let descriptor = hdd.appendingPathComponent("DiskDescriptor.xml")
        if let doc = try? XMLDocument(contentsOf: descriptor) {
            let files = ((try? doc.nodes(forXPath: "//StorageData/Storage/Image/File")) ?? []).compactMap(\.stringValue)
            let sectors = (try? doc.nodes(forXPath: "//Disk_Parameters/Disk_size"))?.first?.stringValue.flatMap { Int64($0) }
            if let last = files.last {
                return (hdd.appendingPathComponent(last), sectors.map { $0 * 512 })
            }
        }
        let hds = (try? FileManager.default.contentsOfDirectory(at: hdd, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "hds" }
        return hds.map { ($0, nil) }
    }

    public static func importVM(_ pvm: URL, toolchain: Toolchain, folder: URL = VMLibrary.defaultFolder,
                                progress: (String) -> Void = { _ in }) throws -> VMBundle {
        let info = try inspect(pvm)
        guard let image = info.diskImages.first else {
            throw MoonError.invalidBundle("Keine Festplatte in \(pvm.lastPathComponent) gefunden")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = VMLibrary.uniqueBundleURL(named: info.name, in: folder)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let bundle = VMBundle(url: url)
        do {
            progress("Festplatte von „\(info.name)“ wird konvertiert …")
            let result = try ProcessRunner.run(toolchain.qemuImg, ["convert", "-U", "-f", "parallels", "-O", "qcow2", "-o", "lazy_refcounts=on", image.path, bundle.diskURL.path])
            guard result.status == 0 else { throw MoonError.processFailed("qemu-img", result.output) }
            try toolchain.prepareEFIVars(for: bundle)

            let gb = Int(((info.diskSizeBytes ?? 64 * 1_073_741_824) + 1_073_741_823) / 1_073_741_824)
            var config = VMConfig(name: info.name, guestOS: info.isWindows ? .windows11 : .other,
                                  cpuCount: info.cpuCount, memoryMB: info.memoryMB, diskSizeGB: gb)
            config.tpmEnabled = info.isWindows
            config.attachDriversDisc = info.isWindows && DriverStore.cachedVirtioISO != nil
            config.profile = .custom
            config.notes = "Importiert aus Parallels: \(pvm.path)"
            try bundle.saveConfig(config)
            return bundle
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
    }
}
