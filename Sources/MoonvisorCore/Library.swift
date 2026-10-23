import Foundation

/// Der VM-Ordner `~/Moonvisor` (entspricht `~/Parallels`).
public enum VMLibrary {
    public static var defaultFolder: URL {
        if let custom = UserDefaults.standard.string(forKey: "vmFolder"), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Moonvisor", isDirectory: true)
    }

    public static func list(in folder: URL = defaultFolder) -> [VMBundle] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { $0.pathExtension == VMBundle.pathExtension && fm.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
            .map(VMBundle.init)
            .sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    /// Findet eine VM per Name, UUID(-Präfix) oder Pfad.
    public static func find(_ query: String, in folder: URL = defaultFolder) -> VMBundle? {
        if query.contains("/") {
            let url = URL(fileURLWithPath: (query as NSString).expandingTildeInPath)
            return FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path) ? VMBundle(url: url) : nil
        }
        let q = query.lowercased()
        return list(in: folder).first { bundle in
            guard let config = try? bundle.loadConfig() else { return false }
            return config.name.lowercased() == q || config.id.uuidString.lowercased().hasPrefix(q)
        }
    }

    public static func uniqueBundleURL(named name: String, in folder: URL = defaultFolder) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = folder.appendingPathComponent("\(safe).\(VMBundle.pathExtension)", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(safe) \(n).\(VMBundle.pathExtension)", isDirectory: true)
            n += 1
        }
        return url
    }

    /// In den Papierkorb legen statt endgültig löschen.
    public static func moveToTrash(_ bundle: VMBundle) throws {
        if VMRunner.runtime(of: bundle) != nil { throw MoonError.alreadyRunning }
        try FileManager.default.trashItem(at: bundle.url, resultingItemURL: nil)
    }

    /// Bekannte Orte, an denen Windows-ISOs liegen (Downloads, Parallels-Downloads).
    public static func discoverInstallImages() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let folders = [
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Library/Parallels/Downloads"),
        ]
        var found: [URL] = []
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for item in items where item.pathExtension.lowercased() == "iso" {
                let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 500_000_000 { found.append(item) }
            }
        }
        return found
    }

    /// Erkennt ARM64-Windows-ISOs am Microsoft-Dateinamen (`…_A64FRE_…`).
    public static func looksLikeWindowsARM(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.contains("a64fre") || name.contains("arm64") || (name.contains("win") && name.contains("arm"))
    }
}

public struct CreateRequest: Sendable {
    public var name: String
    public var guestOS: GuestOS
    public var installMedia: URL?
    public var cpuCount: Int
    public var memoryMB: Int
    public var diskSizeGB: Int
    public var profile: ResourceProfile
    public var installMode: InstallMode
    public var express: ExpressInstallOptions?
    public var folder: URL

    public init(name: String, guestOS: GuestOS, installMedia: URL?, cpuCount: Int, memoryMB: Int, diskSizeGB: Int,
                profile: ResourceProfile, installMode: InstallMode, express: ExpressInstallOptions?, folder: URL = VMLibrary.defaultFolder) {
        self.name = name
        self.guestOS = guestOS
        self.installMedia = installMedia
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.diskSizeGB = diskSizeGB
        self.profile = profile
        self.installMode = installMode
        self.express = express
        self.folder = folder
    }
}

public enum VMFactory {
    /// Legt eine neue VM an: Ordner, dünn belegte Festplatte, EFI-Variablen und ggf. die Setup-CD.
    public static func create(_ request: CreateRequest, toolchain: Toolchain, progress: (String) -> Void = { _ in }) throws -> VMBundle {
        let fm = FileManager.default
        try fm.createDirectory(at: request.folder, withIntermediateDirectories: true)
        let url = VMLibrary.uniqueBundleURL(named: request.name, in: request.folder)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let bundle = VMBundle(url: url)

        do {
            var config = VMConfig(name: request.name, guestOS: request.guestOS, cpuCount: request.cpuCount,
                                  memoryMB: request.memoryMB, diskSizeGB: request.diskSizeGB)
            config.profile = request.profile
            config.installMode = request.installMode
            config.installMediaPath = request.installMedia?.path
            config.installMediaAttached = request.installMedia != nil
            config.autoConfirmCDBoot = request.installMedia != nil && request.guestOS == .windows11
            config.attachDriversDisc = request.guestOS == .windows11 && DriverStore.cachedVirtioISO != nil
            config.tpmEnabled = request.guestOS == .windows11

            progress("Virtuelle Festplatte wird erstellt …")
            let result = try ProcessRunner.run(toolchain.qemuImg, ["create", "-f", "qcow2", "-o", "lazy_refcounts=on", bundle.diskURL.path, "\(request.diskSizeGB)G"])
            guard result.status == 0 else { throw MoonError.processFailed("qemu-img", result.output) }

            progress("UEFI-Firmware wird vorbereitet …")
            try toolchain.prepareEFIVars(for: bundle)

            if request.guestOS == .windows11 {
                progress("Installationshilfe wird erstellt …")
                let xml: String
                if request.installMode == .express, let express = request.express {
                    xml = UnattendBuilder.expressXML(express)
                } else {
                    xml = UnattendBuilder.manualXML(locale: WindowsLocale.guess(isoPath: request.installMedia?.path))
                }
                try UnattendBuilder.buildSetupDisc(at: bundle.setupDiscURL, unattendXML: xml)
            }

            try bundle.saveConfig(config)
            return bundle
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
    }
}

public enum Installation {
    /// Unter dieser Größe der Festplattendatei ist noch kein Windows installiert (Setup schreibt vor dem ersten
    /// Neustart mehrere GB). Eine leere qcow2-Datei ist wenige hundert KB groß.
    static let installedDiskThreshold: Int64 = 1 << 30

    /// Soll Moonvisor beim Start „Press any key to boot from CD or DVD“ bestätigen? Ja, solange eine Windows-ISO
    /// eingelegt und die Festplatte noch leer ist. Früher galt das nur für den allerersten Start; scheiterte der,
    /// startete die Installation danach nicht mehr von selbst.
    public static func shouldConfirmCDBoot(bundle: VMBundle, config: VMConfig) -> Bool {
        guard config.guestOS == .windows11, config.installMediaAttached, config.resumeSnapshot == nil else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: bundle.diskURL.path))?[.size] as? NSNumber
        return (size?.int64Value ?? 0) < installedDiskThreshold
    }

    /// Vor jedem Start: Ein gelöschtes oder verschobenes Installationsmedium wird ausgeworfen, statt den Start
    /// zu blockieren. Ein vorhandenes Medium bleibt eingelegt – die Festplatte steht in der Bootreihenfolge vorn.
    static func prepareForBoot(bundle: VMBundle, config: inout VMConfig) {
        guard config.installMediaAttached, let path = config.installMediaPath else { return }
        if !FileManager.default.fileExists(atPath: path) {
            config.installMediaAttached = false
            config.autoConfirmCDBoot = false
            try? bundle.saveConfig(config)
        }
    }
}
