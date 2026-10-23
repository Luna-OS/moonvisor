import XCTest
@testable import MoonvisorCore

final class CoreTests: XCTestCase {
    func testComputerNameIsSanitized() {
        XCTAssertEqual(UnattendBuilder.sanitizeComputerName("Lunas Windows 11 VM"), "LUNAS-WINDOWS-1")
        XCTAssertEqual(UnattendBuilder.sanitizeComputerName("ÄÖÜ"), "MOONVISOR-VM")
    }

    func testLocaleFromMicrosoftISOName() {
        XCTAssertEqual(WindowsLocale.guess(isoPath: "/x/26300.9711_CLIENTCONSUMER_RET_A64FRE_de-de.iso"), "de-DE")
        XCTAssertEqual(WindowsLocale.guess(isoPath: "/x/Win11_ARM64_en-gb.iso"), "en-GB")
    }

    func testExpressXMLIsWellFormed() throws {
        let options = ExpressInstallOptions(userName: "Luna & Co", password: "<geheim>", computerName: "Moon", locale: "de-DE", timeZone: "W. Europe Standard Time")
        let xml = UnattendBuilder.expressXML(options)
        let doc = try XMLDocument(xmlString: xml)
        let names = try doc.nodes(forXPath: "//*[local-name()='LocalAccount']/*[local-name()='Name']").map(\.stringValue)
        XCTAssertEqual(names, ["Luna & Co"])
        XCTAssertTrue(xml.contains("BypassSecureBootCheck"))
        XCTAssertTrue(xml.contains(#"processorArchitecture="arm64""#))
        _ = try XMLDocument(xmlString: UnattendBuilder.manualXML(locale: "de-DE"))
    }

    func testQEMUArgumentsEscapeCommasAndUseNVMeForWindows() {
        var config = VMConfig(name: "Win, 11", guestOS: .windows11, cpuCount: 4, memoryMB: 4096, diskSizeGB: 64)
        config.installMediaPath = "/isos/a,b.iso"
        config.installMediaAttached = true
        config.portForwards = [PortForward(hostPort: 3390, guestPort: 3389)]
        let bundle = VMBundle(url: URL(fileURLWithPath: "/vms/Win.moonvm"))
        let toolchain = Toolchain(qemuSystem: URL(fileURLWithPath: "/q"), qemuImg: URL(fileURLWithPath: "/qi"), swtpm: nil,
                                  firmwareCode: URL(fileURLWithPath: "/fw/code.fd"), firmwareVarsTemplate: URL(fileURLWithPath: "/fw/vars.fd"))
        let args = QEMUCommand(config: config, bundle: bundle, toolchain: toolchain, sockets: RuntimeSockets(directory: "/t/mv")).arguments
        XCTAssertTrue(args.contains { $0.contains("file=/isos/a,,b.iso") })
        XCTAssertTrue(args.contains { $0.hasPrefix("nvme,drive=hd0") })
        XCTAssertTrue(args.contains { $0.contains("hostfwd=tcp::3390-:3389") })
        XCTAssertTrue(args.contains("tpm-tis-device,tpmdev=tpm0,ppi=off"))
        XCTAssertEqual(args.first { $0.hasPrefix("Win") }, "Win,, 11")
    }

    func testSocketPathsFitUnixLimit() {
        let sockets = RuntimeSockets.make(for: UUID())
        XCTAssertLessThan(sockets.qmp.utf8.count, 104)
    }

    func testSnapshotJSONParsing() {
        let json = #"{"snapshots":[{"name":"Vor Update","date-sec":1792545196,"vm-state-size":0},{"name":"live","date-sec":1792545200,"vm-state-size":1048576}]}"#
        let list = Snapshots.parse(Data(json.utf8))
        XCTAssertEqual(list.map(\.name), ["Vor Update", "live"])
        XCTAssertEqual(list[0].vmStateSize, "nur Festplatte")
        XCTAssertTrue(list[1].vmStateSize.hasPrefix("mit Arbeitsspeicher"))
        XCTAssertEqual(Snapshots.sanitize(" Vor dem Update "), "Vor_dem_Update")
    }

    func testParallelsConfigIsRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pvm-\(UUID()).pvm")
        let hdd = dir.appendingPathComponent("harddisk.hdd")
        try FileManager.default.createDirectory(at: hdd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        <?xml version="1.0"?><ParallelsVirtualMachine><Identification><VmName>Windows 11</VmName></Identification>
        <Settings><General><OsType>8</OsType></General></Settings>
        <Hardware><Cpu><Number>6</Number></Cpu><Memory><RAM>8192</RAM></Memory>
        <Hdd id="0"><Enabled>1</Enabled><SystemName>harddisk.hdd</SystemName></Hdd></Hardware></ParallelsVirtualMachine>
        """.write(to: dir.appendingPathComponent("config.pvs"), atomically: true, encoding: .utf8)
        try """
        <Parallels_disk_image><Disk_Parameters><Disk_size>134217728</Disk_size></Disk_Parameters>
        <StorageData><Storage><Image><File>harddisk.hdd.0.{x}.hds</File></Image></Storage></StorageData></Parallels_disk_image>
        """.write(to: hdd.appendingPathComponent("DiskDescriptor.xml"), atomically: true, encoding: .utf8)
        let info = try ParallelsImporter.inspect(dir)
        XCTAssertEqual(info.name, "Windows 11")
        XCTAssertEqual(info.cpuCount, 6)
        XCTAssertEqual(info.memoryMB, 8192)
        XCTAssertTrue(info.isWindows)
        XCTAssertEqual(info.diskImages.first?.lastPathComponent, "harddisk.hdd.0.{x}.hds")
        XCTAssertEqual(info.diskSizeBytes, 64 * 1_073_741_824)
    }

    func testOldConfigWithMissingFieldsStillLoads() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Alt","guestOS":"windows11","cpuCount":2,"memoryMB":2048,"diskSizeGB":64}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.name, "Alt")
        XCTAssertEqual(config.graphics, .automatic)
        XCTAssertTrue(config.tpmEnabled)
        XCTAssertEqual(config.networkMode, .shared)
        XCTAssertNil(config.fixedResolution)
    }

    func testFixedResolutionIsSaved() throws {
        var config = VMConfig(name: "Auflösung", guestOS: .windows11, cpuCount: 4, memoryMB: 8192, diskSizeGB: 64)
        config.fixedResolution = GuestResolution(width: 1920, height: 1080)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode(VMConfig.self, from: encoder.encode(config))
        XCTAssertEqual(loaded.fixedResolution, GuestResolution(width: 1920, height: 1080))
        XCTAssertEqual(loaded.fixedResolution?.name, "1920 × 1080")
        XCTAssertTrue(GuestResolution.presets.allSatisfy { $0.width >= 1024 && $0.height >= 768 })
    }

    func testInstallCommandTypesOnAllLayouts() throws {
        for layout in [GuestKeyboard.Layout.us, .german, .swissGerman] {
            let strokes = try GuestKeyboard.keystrokes(for: GuestKeyboard.installToolsCommand, layout: layout)
            XCTAssertEqual(strokes.count, GuestKeyboard.installToolsCommand.count)
        }
        XCTAssertFalse(GuestKeyboard.installToolsCommand.lowercased().contains("y"))
        XCTAssertFalse(GuestKeyboard.installToolsCommand.lowercased().contains("z"))
        XCTAssertEqual(try GuestKeyboard.keystrokes(for: "\\:", layout: .german), [["alt_r", "minus"], ["shift", "dot"]])
        XCTAssertEqual(try GuestKeyboard.keystrokes(for: "\\:", layout: .us), [["backslash"], ["shift", "semicolon"]])
        XCTAssertEqual(try GuestKeyboard.keystrokes(for: "Zy", layout: .german), [["shift", "y"], ["z"]])
        XCTAssertThrowsError(try GuestKeyboard.keystrokes(for: "{", layout: .us))
    }

    func testDriverRedirectsStayEncrypted() {
        let insecure = URLRequest(url: URL(string: "http://fedorapeople.org/groups/virt/virtio-win/a.iso?x=1")!)
        XCTAssertEqual(DriverStore.secureRedirect(insecure).url?.absoluteString, "https://fedorapeople.org/groups/virt/virtio-win/a.iso?x=1")
        let secure = URLRequest(url: URL(string: "https://example.org/b.iso")!)
        XCTAssertEqual(DriverStore.secureRedirect(secure).url, secure.url)
    }

    private func toolchain(engine: URL? = nil) -> Toolchain {
        Toolchain(qemuSystem: URL(fileURLWithPath: "/q"), qemuImg: URL(fileURLWithPath: "/qi"), swtpm: nil,
                  firmwareCode: URL(fileURLWithPath: "/fw/code.fd"), firmwareVarsTemplate: URL(fileURLWithPath: "/fw/vars.fd"),
                  dataDirectory: URL(fileURLWithPath: "/fw"), enginePrefix: engine)
    }

    func testVMNetUsesStreamSocketAndDataDirectory() {
        var config = VMConfig(name: "Netz", guestOS: .windows11, cpuCount: 2, memoryMB: 4096, diskSizeGB: 64)
        config.networkMode = .bridged
        config.bridgeInterface = "en1"
        let bundle = VMBundle(url: URL(fileURLWithPath: "/vms/Netz.moonvm"))
        let args = QEMUCommand(config: config, bundle: bundle, toolchain: toolchain(), sockets: RuntimeSockets(directory: "/t/mv")).arguments
        XCTAssertTrue(args.contains("stream,id=net0,server=off,addr.type=unix,addr.path=/var/run/moonvisor-vmnet-bridged-en1.sock"))
        XCTAssertFalse(args.contains { $0.contains("hostfwd") })
        XCTAssertEqual(args[args.firstIndex(of: "-L")! + 1], "/fw")
    }

    func testDirectXFallsBackWithoutEngine() {
        var config = VMConfig(name: "3D", guestOS: .windows11, cpuCount: 2, memoryMB: 4096, diskSizeGB: 64)
        config.graphics = .directX
        let bundle = VMBundle(url: URL(fileURLWithPath: "/vms/3D.moonvm"))
        let command = QEMUCommand(config: config, bundle: bundle, toolchain: toolchain(), sockets: RuntimeSockets(directory: "/t/mv"))
        XCTAssertEqual(command.display, .virtioGPU)
        XCTAssertFalse(command.arguments.contains("-spice"))
        XCTAssertNil(command.environment["NPT_BACKEND"])
    }

    func testVMNetInstallScriptAndPlist() throws {
        var config = VMConfig(name: "Netz", guestOS: .windows11, cpuCount: 2, memoryMB: 4096, diskSizeGB: 64)
        config.networkMode = .vmnet
        let service = try XCTUnwrap(VMNet.service(for: config))
        XCTAssertEqual(service.socketPath, "/var/run/moonvisor-vmnet-shared.sock")
        XCTAssertTrue(service.arguments.contains("--vmnet-gateway=192.168.105.1"))
        _ = try XMLDocument(xmlString: VMNet.plist(for: service))
        let script = VMNet.installScript(for: service, engine: URL(fileURLWithPath: "/Users/luna/Library/Application Support/Moonvisor/Engine/1"))
        XCTAssertTrue(script.contains("launchctl bootstrap system '/Library/LaunchDaemons/io.github.luna-os.moonvisor.vmnet.shared.plist'"))
        XCTAssertTrue(script.contains("'/Users/luna/Library/Application Support/Moonvisor/Engine/1/libexec/socket_vmnet'"))
        config.networkMode = .shared
        XCTAssertNil(VMNet.service(for: config))
    }

    func testSnapshotRestoresHardwareButKeepsName() {
        var snapshot = VMConfig(name: "Alt", guestOS: .windows11, cpuCount: 4, memoryMB: 8192, diskSizeGB: 64)
        snapshot.graphics = .virtio
        snapshot.soundEnabled = false
        var current = snapshot
        current.name = "Neu"
        current.cpuCount = 2
        current.memoryMB = 4096
        current.soundEnabled = true
        current.networkMode = .vmnet
        Snapshots.applyHardware(from: snapshot, to: &current)
        XCTAssertEqual(current.name, "Neu")
        XCTAssertEqual(current.cpuCount, 4)
        XCTAssertEqual(current.memoryMB, 8192)
        XCTAssertFalse(current.soundEnabled)
        XCTAssertEqual(current.networkMode, .vmnet)
    }

    func testTransferPathsStayInsideTarget() {
        XCTAssertEqual(FileTransfer.safeComponents("../../etc/passwd"), ["etc", "passwd"])
        XCTAssertEqual(FileTransfer.safeComponents("/Ordner\\Unter/./a:b.txt"), ["Ordner", "Unter", "a_b.txt"])
    }

    func testFileTransferListsFolderContents() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("transfer-\(UUID())/Projekt")
        try fm.createDirectory(at: root.appendingPathComponent("leer"), withIntermediateDirectories: true)
        try Data("hallo".utf8).write(to: root.appendingPathComponent("a.txt"))
        defer { try? fm.removeItem(at: root.deletingLastPathComponent()) }
        let items = FileTransfer.items(below: root)
        XCTAssertEqual(Set(items.map(\.relativePath)), ["Projekt", "Projekt/leer", "Projekt/a.txt"])
        XCTAssertEqual(FileTransfer.totalSize([root]), 5)
    }

    func testEngineManifestDecodes() throws {
        let json = #"{"version":"1","archive":"moonvisor-engine-1-arm64.tar.xz","folder":"moonvisor-engine-1-arm64","sha256":"ab","size":10,"unpackedSize":20,"directX":true}"#
        let manifest = try JSONDecoder().decode(EngineStore.Manifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.folder, "moonvisor-engine-1-arm64")
        XCTAssertTrue(manifest.directX)
    }

    func testDirectXUsesNeptuneAndSpiceWithEngine() throws {
        let fm = FileManager.default
        let engine = fm.temporaryDirectory.appendingPathComponent("engine-\(UUID())")
        try fm.createDirectory(at: engine.appendingPathComponent("Frameworks/dxmt-native.framework"), withIntermediateDirectories: true)
        try fm.createDirectory(at: engine.appendingPathComponent("libexec"), withIntermediateDirectories: true)
        let server = engine.appendingPathComponent("libexec/virgl_render_server")
        fm.createFile(atPath: server.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        defer { try? fm.removeItem(at: engine) }

        var config = VMConfig(name: "3D", guestOS: .windows11, cpuCount: 4, memoryMB: 8192, diskSizeGB: 64)
        config.graphics = .directX
        let bundle = VMBundle(url: URL(fileURLWithPath: "/vms/3D.moonvm"))
        let command = QEMUCommand(config: config, bundle: bundle, toolchain: toolchain(engine: engine), sockets: RuntimeSockets(directory: "/t/mv"))
        XCTAssertEqual(command.display, .virtioGPUGL)
        let args = command.arguments
        XCTAssertTrue(args.contains { $0.hasPrefix("virtio-gpu-gl-pci,") && $0.contains("neptune=true") && $0.contains("blob=true") })
        XCTAssertEqual(args[args.firstIndex(of: "-spice")! + 1], "unix=on,addr=/t/mv/spice,disable-ticketing=on,gl=es,image-compression=off,playback-compression=off,streaming-video=off")
        XCTAssertFalse(args.contains("-vnc"))
        XCTAssertEqual(command.environment["NPT_BACKEND"], "dxmt")
        XCTAssertEqual(command.environment["RENDER_SERVER_EXEC_PATH"], server.path)
        XCTAssertEqual(GraphicsMode.selectable(directX: false).contains(.directX), false)
        XCTAssertEqual(GraphicsMode.selectable(directX: true).last, .directX)
    }

    func testToolsDiscContainsDirectXSetup() {
        XCTAssertTrue(GuestTools.directXSetupScript.contains("viogpu3d.inf"))
        XCTAssertTrue(GuestTools.agentScript.contains("'install-3d'"))
        XCTAssertTrue(GuestTools.agentScript.contains("$version = \(GuestTools.version)"))
    }

    func testTPMWithoutPPIOptionForOlderQEMU() {
        let config = VMConfig(name: "TPM", guestOS: .windows11, cpuCount: 2, memoryMB: 4096, diskSizeGB: 64)
        var tools = toolchain()
        tools.tpmHasPPI = false
        let args = QEMUCommand(config: config, bundle: VMBundle(url: URL(fileURLWithPath: "/vms/TPM.moonvm")),
                               toolchain: tools, sockets: RuntimeSockets(directory: "/t/mv")).arguments
        XCTAssertTrue(args.contains("tpm-tis-device,tpmdev=tpm0"))
        XCTAssertFalse(args.contains { $0.contains("ppi") })
    }
}
