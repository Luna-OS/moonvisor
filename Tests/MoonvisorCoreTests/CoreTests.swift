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
    }
}
