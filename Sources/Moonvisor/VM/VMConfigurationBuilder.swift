import Foundation
import Virtualization

enum VMConfigurationBuilder {
    static func make(bundle: VMBundle, config: VMConfig) throws -> VZVirtualMachineConfiguration {
        guard VZVirtualMachine.isSupported else { throw MoonvisorError.unsupportedHost }

        let platform = VZMacPlatformConfiguration()
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: bundle.hardwareModelURL)),
              hardwareModel.isSupported
        else { throw MoonvisorError.unsupportedHardwareModel }
        platform.hardwareModel = hardwareModel
        guard let machineIdentifier = VZMacMachineIdentifier(
            dataRepresentation: try Data(contentsOf: bundle.machineIdentifierURL))
        else { throw MoonvisorError.invalidMachineIdentifier }
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorageURL)

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = config.cpuCount.clamped(
            VZVirtualMachineConfiguration.minimumAllowedCPUCount,
            VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        configuration.memorySize = (UInt64(config.memoryGB) * HostLimits.gib).clamped(
            VZVirtualMachineConfiguration.minimumAllowedMemorySize,
            VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(
            widthInPixels: config.display.width,
            heightInPixels: config.display.height,
            pixelsPerInch: config.display.ppi)]
        configuration.graphicsDevices = [graphics]

        let disk = try VZDiskImageStorageDeviceAttachment(url: bundle.diskURL, readOnly: false)
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        network.macAddress = VZMACAddress(string: config.macAddress) ?? .randomLocallyAdministered()
        configuration.networkDevices = [network]

        configuration.keyboards = [VZMacKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]

        let sound = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        sound.streams = [output]
        configuration.audioDevices = [sound]

        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        if let share = sharedDirectories(config.sharedFolders) {
            // macOS guests mount this tag automatically under /Volumes/My Shared Files.
            let fileSystem = VZVirtioFileSystemDeviceConfiguration(
                tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
            fileSystem.share = share
            configuration.directorySharingDevices = [fileSystem]
        }

        try configuration.validate()
        return configuration
    }

    private static func sharedDirectories(_ folders: [SharedFolder]) -> VZMultipleDirectoryShare? {
        var directories: [String: VZSharedDirectory] = [:]
        for folder in folders where FileManager.default.fileExists(atPath: folder.path) {
            let base = folder.url.lastPathComponent
            var name = base
            var n = 2
            while directories[name] != nil {
                name = "\(base) \(n)"
                n += 1
            }
            directories[name] = VZSharedDirectory(url: folder.url, readOnly: folder.readOnly)
        }
        return directories.isEmpty ? nil : VZMultipleDirectoryShare(directories: directories)
    }
}

private extension Comparable {
    func clamped(_ lower: Self, _ upper: Self) -> Self { min(max(self, lower), upper) }
}
