import CoreGraphics
import ImageIO
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
        // Schnappschüsse älterer Versionen kennen den Gerätesatz nicht.
        current.deviceRevision = 2
        Snapshots.applyHardware(from: snapshot, to: &current)
        XCTAssertNil(current.deviceRevision)
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
        XCTAssertEqual(command.environment["XDG_RUNTIME_DIR"], "/t/mv")
        XCTAssertTrue(args.contains { $0.contains("hostmem=8192M") })
        XCTAssertEqual(args[args.firstIndex(of: "-accel")! + 1], "hvf,ipa-granule-size=0x1000")
        XCTAssertEqual(GraphicsMode.selectable(directX: false).contains(.directX), false)
        XCTAssertEqual(GraphicsMode.selectable(directX: true).last, .directX)
    }

    func testAppRequiresTheEngineTheRepositoryBuilds() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let version = try String(contentsOf: root.appendingPathComponent("engine/VERSION"), encoding: .utf8)
        XCTAssertEqual(version.trimmingCharacters(in: .whitespacesAndNewlines), EngineStore.requiredVersion)
    }

    func testCDBootIsConfirmedUntilWindowsIsOnTheDisk() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("cdboot-\(UUID()).moonvm")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let bundle = VMBundle(url: folder)
        var config = VMConfig(name: "Neu", guestOS: .windows11, cpuCount: 4, memoryMB: 8192, diskSizeGB: 64)
        config.installMediaPath = "/tmp/win11.iso"
        config.installMediaAttached = true

        fm.createFile(atPath: bundle.diskURL.path, contents: Data(count: 200_000))
        XCTAssertTrue(Installation.shouldConfirmCDBoot(bundle: bundle, config: config))

        // Nach dem ersten Teil des Setups ist die Platte mehrere GB groß: dann von der Platte starten.
        let handle = try FileHandle(forWritingTo: bundle.diskURL)
        try handle.truncate(atOffset: 3 << 30)
        try handle.close()
        XCTAssertFalse(Installation.shouldConfirmCDBoot(bundle: bundle, config: config))

        // Ohne eingelegte ISO nie, auch bei leerer Platte.
        fm.createFile(atPath: bundle.diskURL.path, contents: Data(count: 200_000))
        config.installMediaAttached = false
        XCTAssertFalse(Installation.shouldConfirmCDBoot(bundle: bundle, config: config))
    }

    func testQcow2VirtualSizeIsReadFromHeader() throws {
        // Kopf einer mit qemu-img 10 aus edk2-arm-vars.fd erzeugten Datei (virtuelle Größe 329 216 Bytes).
        var header = [UInt8](repeating: 0, count: 104)
        header.replaceSubrange(0..<8, with: [0x51, 0x46, 0x49, 0xFB, 0, 0, 0, 3])
        header.replaceSubrange(24..<32, with: [0, 0, 0, 0, 0, 0x05, 0x06, 0x00])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vars-\(UUID()).qcow2")
        try Data(header).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(Toolchain.qcow2VirtualSize(url), 329216)
        try Data(repeating: 0, count: 64).write(to: url)
        XCTAssertNil(Toolchain.qcow2VirtualSize(url))
    }

    func testVirtualSizeIsReadFromImageInfo() {
        let info = #"{"virtual-size": 329216, "filename": "efi-vars.qcow2", "format": "qcow2", "actual-size": 200704}"#
        XCTAssertEqual(Toolchain.virtualSize(fromImageInfo: info), 329216)
        XCTAssertEqual(Toolchain.virtualSize(fromImageInfo: "warning: x\n" + info), 329216)
        XCTAssertNil(Toolchain.virtualSize(fromImageInfo: "kaputt"))
    }

    func testCrashLogSkipsRendererNoise() {
        let log = """
        qemu-system-aarch64: virtio-gpu: blob mapping failed
        Assertion failed: (res), function x, file y.c, line 1.
        Oct 23 03:32:02  virgl_render_server[1] <Debug>: npt: destroying Neptune context 9
        swtpm: Data client disconnected
        Oct 23 03:32:02  virgl_render_server[1] <Debug>: worker 2 exited with status 16777215
        """
        XCTAssertEqual(VMRunner.relevantLines(log), "qemu-system-aarch64: virtio-gpu: blob mapping failed\nAssertion failed: (res), function x, file y.c, line 1.")
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

    private func command(_ config: VMConfig, ramfb: Bool = true, engine: URL? = nil, snapshot: String? = nil) -> QEMUCommand {
        var tools = toolchain(engine: engine)
        tools.hasVirtioRamfb = ramfb
        var command = QEMUCommand(config: config, bundle: VMBundle(url: URL(fileURLWithPath: "/vms/G.moonvm")),
                                  toolchain: tools, sockets: RuntimeSockets(directory: "/t/mv"))
        command.loadSnapshot = snapshot
        return command
    }

    func testWindowsShowsFirmwareAndDriverOnVirtioRamfb() {
        var config = VMConfig(name: "Win", guestOS: .windows11, cpuCount: 4, memoryMB: 8192, diskSizeGB: 64)
        XCTAssertEqual(command(config).display, .virtioRamfb)
        XCTAssertTrue(command(config).arguments.contains("virtio-ramfb"))
        XCTAssertTrue(command(config).arguments.contains("-vnc"))
        config.graphics = .virtio
        XCTAssertEqual(command(config).display, .virtioRamfb)
        // Die Firmware der Engine kennt kein einzelnes ramfb: auch „Basis“ braucht virtio-ramfb.
        config.graphics = .basic
        XCTAssertEqual(command(config).display, .virtioRamfb)
        XCTAssertFalse(command(config).arguments.contains("ramfb"))
        // Homebrew-QEMU kennt virtio-ramfb nicht, seine Firmware dafür ramfb.
        XCTAssertEqual(command(config, ramfb: false).display, .ramfb)
        config.graphics = .automatic
        XCTAssertEqual(command(config, ramfb: false).display, .ramfb)
        config.graphics = .virtio
        XCTAssertEqual(command(config, ramfb: false).display, .virtioGPU)
        // Linux bleibt bei virtio-gpu.
        var linux = VMConfig(name: "Tux", guestOS: .linux, cpuCount: 2, memoryMB: 4096, diskSizeGB: 32)
        XCTAssertEqual(command(linux).display, .virtioGPU)
        linux.graphics = .basic
        XCTAssertEqual(command(linux).display, .virtioRamfb)
    }

    func testOldSnapshotsKeepTheirDisplayDevice() throws {
        var config = VMConfig(name: "Win", guestOS: .windows11, cpuCount: 4, memoryMB: 8192, diskSizeGB: 64)
        XCTAssertEqual(command(config, snapshot: "alt").deviceRevision, 1)
        XCTAssertEqual(command(config, snapshot: "alt").display, .ramfb)
        XCTAssertTrue(command(config, snapshot: "alt").arguments.contains("-loadvm"))
        config.graphics = .virtio
        XCTAssertEqual(command(config, snapshot: "alt").display, .virtioGPU)
        config.deviceRevision = 2
        XCTAssertEqual(command(config, snapshot: "neu").display, .virtioRamfb)
        // Ohne Schnappschuss gilt immer der aktuelle Gerätesatz.
        config.deviceRevision = 1
        XCTAssertEqual(command(config).deviceRevision, QEMUCommand.currentDeviceRevision)
        XCTAssertEqual(command(config).display, .virtioRamfb)

        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(VMConfig.self, from: data).deviceRevision, 1)
    }

    func testDirectXUsesVirtioRamfbGLWithEngine() throws {
        let fm = FileManager.default
        let engine = fm.temporaryDirectory.appendingPathComponent("engine-\(UUID())")
        try fm.createDirectory(at: engine.appendingPathComponent("Frameworks/dxmt-native.framework"), withIntermediateDirectories: true)
        try fm.createDirectory(at: engine.appendingPathComponent("libexec"), withIntermediateDirectories: true)
        fm.createFile(atPath: engine.appendingPathComponent("libexec/virgl_render_server").path, contents: Data(),
                      attributes: [.posixPermissions: 0o755])
        defer { try? fm.removeItem(at: engine) }

        var config = VMConfig(name: "3D", guestOS: .windows11, cpuCount: 4, memoryMB: 8192, diskSizeGB: 64)
        config.graphics = .directX
        let gl = command(config, engine: engine)
        XCTAssertEqual(gl.display, .virtioRamfbGL)
        XCTAssertTrue(gl.display.usesGL)
        let args = gl.arguments
        XCTAssertTrue(args.contains("virtio-ramfb-gl,hostmem=8192M,blob=true,neptune=true"))
        XCTAssertTrue(args.contains("-spice"))
        XCTAssertFalse(args.contains("-vnc"))
        XCTAssertEqual(args[args.firstIndex(of: "-accel")! + 1], "hvf,ipa-granule-size=0x1000")
        XCTAssertEqual(gl.environment["NPT_BACKEND"], "dxmt")
        // Ohne 3D-Bausteine bleibt virtio-ramfb ohne OpenGL.
        XCTAssertEqual(command(config).display, .virtioRamfb)
        XCTAssertFalse(command(config).arguments.contains("-spice"))
    }

    func testCDBootIsConfirmedUntilWindowsLoadsFromTheISO() {
        var confirmation = CDBootConfirmation()
        XCTAssertEqual(confirmation.next(read: 0, running: true, elapsed: 0.5), .press)
        XCTAssertEqual(confirmation.next(read: 2 << 20, running: true, elapsed: 0.5), .press)
        // Angehalten: warten, die Zeit zählt nicht.
        for _ in 0..<200 { XCTAssertEqual(confirmation.next(read: 2 << 20, running: false, elapsed: 0.5), .wait) }
        XCTAssertEqual(confirmation.next(read: 300 << 20, running: true, elapsed: 0.5), .done)
        XCTAssertEqual(confirmation.presses, 2)

        // Abfrage verpasst: nach einem Versuch neu starten, nach zwei Neustarts aufgeben.
        var missed = CDBootConfirmation()
        var steps: [CDBootConfirmation.Step] = []
        for _ in 0..<400 {
            let step = missed.next(read: 160_000, running: true, elapsed: 0.5)
            if step != .press { steps.append(step) }
            if step == .giveUp { break }
        }
        XCTAssertEqual(steps, [.reset, .reset, .giveUp])
        XCTAssertEqual(missed.resets, 2)

        // Nach einem Neustart zählt QEMU weiter: Was vorher gelesen wurde, zählt nicht.
        var restarted = CDBootConfirmation()
        XCTAssertEqual(restarted.next(read: 900 << 20, running: true, elapsed: 0.5), .press)
        XCTAssertEqual(restarted.next(read: 901 << 20, running: true, elapsed: 0.5), .press)
        XCTAssertEqual(restarted.next(read: 1000 << 20, running: true, elapsed: 0.5), .done)
    }

    func testReadBytesComeFromBlockStats() throws {
        let json = #"[{"device":"hd0","stats":{"rd_bytes":5}},{"device":"cd0","qdev":"/machine/peripheral-anon/device[4]","stats":{"rd_bytes":167938048,"wr_bytes":0}}]"#
        let result = try JSONSerialization.jsonObject(with: Data(json.utf8))
        XCTAssertEqual(CDBootConfirmation.readBytes(fromBlockStats: result, drive: QEMUCommand.installMediaDrive), 167938048)
        XCTAssertNil(CDBootConfirmation.readBytes(fromBlockStats: result, drive: "cd7"))
        XCTAssertNil(CDBootConfirmation.readBytes(fromBlockStats: nil, drive: "cd0"))
    }

    func testCDBootNeedsAnInstallMediumPath() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("cdpath-\(UUID()).moonvm")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        var config = VMConfig(name: "Neu", guestOS: .windows11, cpuCount: 4, memoryMB: 8192, diskSizeGB: 64)
        config.installMediaAttached = true
        XCTAssertFalse(Installation.shouldConfirmCDBoot(bundle: VMBundle(url: folder), config: config))
    }

    /// Schwarzes Bild wie QEMUs Ersatzbild, optional mit grauer Schrift in Zeile `textRow`.
    private func frame(width: Int = 640, height: Int = 480, bytesPerPixel: Int = 4, textRow: Int?, extra: (Int, Int, UInt8)? = nil) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        func set(_ x: Int, _ y: Int, _ value: UInt8) {
            for c in 0..<3 { pixels[(y * width + x) * bytesPerPixel + c] = value }
            if bytesPerPixel == 4 { pixels[(y * width + x) * 4 + 3] = 0xFF }
        }
        if let textRow {
            for y in textRow..<(textRow + 12) { for x in stride(from: 200, to: 440, by: 3) { set(x, y, 0xAA) } }
        }
        if case let (x, y, v)? = extra { set(x, y, v) }
        return pixels
    }

    private func isPlaceholder(_ pixels: [UInt8], width: Int = 640, height: Int = 480, bytesPerPixel: Int = 4) -> Bool {
        pixels.withUnsafeBytes {
            DisplayPlaceholder.matches($0.baseAddress!, width: width, height: height, bytesPerRow: width * bytesPerPixel,
                                       bytesPerPixel: bytesPerPixel)
        }
    }

    func testQEMUPlaceholderScreensAreRecognised() {
        // 480 Zeilen: QEMU schreibt in Zeichenzeile 14, also ab Pixelzeile 224.
        XCTAssertEqual(DisplayPlaceholder.textRows(height: 480), 224..<240)
        XCTAssertEqual(DisplayPlaceholder.textRows(height: 600), 288..<304)
        XCTAssertTrue(isPlaceholder(frame(textRow: 226)))
        XCTAssertTrue(isPlaceholder(frame(textRow: 242)), "über OpenGL steht das Bild auf dem Kopf")
        XCTAssertTrue(isPlaceholder(frame(bytesPerPixel: 3, textRow: 226), bytesPerPixel: 3))
        XCTAssertFalse(isPlaceholder(frame(textRow: nil)), "ein schwarzes Bild ist ein echtes Bild")
        XCTAssertFalse(isPlaceholder(frame(textRow: 10)), "Text oben links kommt von der Firmware")
        XCTAssertFalse(isPlaceholder(frame(textRow: 226, extra: (5, 5, 0xAA))))
        XCTAssertFalse(isPlaceholder(frame(textRow: 226, extra: (300, 230, 0xFF))), "weiße Schrift ist nicht von QEMU")
    }

    func testPlaceholderScreenshotIsNotUsedAsThumbnail() throws {
        let width = 640, height = 480
        var pixels = frame(textRow: 226)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("placeholder-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        func writePNG() throws {
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let image = try pixels.withUnsafeMutableBytes { raw -> CGImage in
                let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                                      bytesPerRow: width * 4, space: space,
                                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                return try XCTUnwrap(context.makeImage())
            }
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        try writePNG()
        XCTAssertTrue(DisplayPlaceholder.matches(pngAt: url))
        pixels[(10 * width + 10) * 4] = 0x40
        try writePNG()
        XCTAssertFalse(DisplayPlaceholder.matches(pngAt: url))
    }

    func testEFIVarsTemplateFormatIsDetected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vars-\(UUID()).fd")
        defer { try? FileManager.default.removeItem(at: url) }
        var header = [UInt8](repeating: 0, count: 64)
        header[0..<4] = [0x51, 0x46, 0x49, 0xFB]
        header[28] = 0x04 // 64 MiB
        try Data(header).write(to: url)
        XCTAssertEqual(Toolchain.imageFormat(of: url), "qcow2")
        try Data(repeating: 0xFF, count: 64).write(to: url)
        XCTAssertEqual(Toolchain.imageFormat(of: url), "raw")
    }

    func testDeviceProbeReadsTheHelpOutput() {
        XCTAssertTrue(Toolchain.deviceListed("virtio-ramfb", inHelp: "virtio-ramfb options:\n  blob=<bool>"))
        XCTAssertFalse(Toolchain.deviceListed("virtio-ramfb", inHelp: "qemu-system-aarch64: -device virtio-ramfb,help: Device 'virtio-ramfb' not found"))
    }
}
