import Foundation

/// Kurze Socket-Pfade für eine laufende VM. macOS erlaubt höchstens 104 Bytes pro Unix-Socket-Pfad,
/// deshalb liegen sie nicht im VM-Ordner, sondern unter dem kurzen Benutzer-Temp-Verzeichnis.
public struct RuntimeSockets: Codable, Hashable, Sendable {
    public var directory: String
    public var qmp: String { directory + "/qmp" }
    public var vnc: String { directory + "/vnc" }
    public var tpm: String { directory + "/tpm" }
    public var agent: String { directory + "/agent" }

    public init(directory: String) {
        self.directory = directory
    }

    public static func make(for id: UUID) -> RuntimeSockets {
        var base = NSTemporaryDirectory()
        if base.utf8.count > 60 { base = "/tmp/" }
        if !base.hasSuffix("/") { base += "/" }
        let short = id.uuidString.prefix(8).lowercased()
        return RuntimeSockets(directory: base + "mv-" + short)
    }
}

public enum DisplayDevice: String, Sendable {
    /// Einfacher Framebuffer, funktioniert in Windows ohne Treiber (Setup und Basic Display).
    case ramfb
    /// virtio-gpu, für Linux-Gäste mit dynamischer Auflösung.
    case virtioGPU
}

/// Baut die QEMU-Argumente für eine VM. Reine Funktion, damit sie testbar ist.
public struct QEMUCommand: Sendable {
    public var config: VMConfig
    public var bundle: VMBundle
    public var toolchain: Toolchain
    public var sockets: RuntimeSockets
    /// Zusätzliche CDs (z. B. Treiber-CD), die nach dem Installationsmedium angehängt werden.
    public var extraDiscs: [URL] = []
    /// Schnappschuss, der beim Start geladen wird (`-loadvm`).
    public var loadSnapshot: String?

    public init(config: VMConfig, bundle: VMBundle, toolchain: Toolchain, sockets: RuntimeSockets, extraDiscs: [URL] = []) {
        self.config = config
        self.bundle = bundle
        self.toolchain = toolchain
        self.sockets = sockets
        self.extraDiscs = extraDiscs
    }

    public var display: DisplayDevice {
        switch config.graphics {
        case .basic: return .ramfb
        case .virtio: return .virtioGPU
        case .automatic: return config.guestOS == .windows11 ? .ramfb : .virtioGPU
        }
    }

    /// QEMU trennt Optionen mit Kommas; Kommas in Werten werden verdoppelt.
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: ",", with: ",,")
    }

    public var arguments: [String] {
        var a: [String] = []
        let e = Self.escape

        a += ["-name", e(config.name)]
        a += ["-nodefaults", "-no-user-config"]
        a += ["-machine", "virt,highmem=on"]
        a += ["-accel", "hvf", "-cpu", "host"]
        a += ["-smp", "\(max(1, config.cpuCount))"]
        a += ["-m", "\(max(512, config.memoryMB))"]

        // Die Festplatte zuerst anlegen: savevm speichert den Arbeitsspeicher im ersten schnappschussfähigen Laufwerk.
        a += ["-drive", "if=none,id=hd0,format=qcow2,discard=unmap,detect-zeroes=unmap,file=\(e(bundle.diskURL.path))"]
        a += ["-drive", "if=pflash,format=raw,unit=0,readonly=on,file=\(e(toolchain.firmwareCode.path))"]
        a += ["-drive", "if=pflash,format=qcow2,unit=1,file=\(e(bundle.efiVarsURL.path))"]

        if config.tpmEnabled {
            a += ["-chardev", "socket,id=chrtpm,path=\(e(sockets.tpm))"]
            a += ["-tpmdev", "emulator,id=tpm0,chardev=chrtpm"]
            // PPI belegt eine Speicherregion, die Hypervisor.framework auf 16K-Seiten nicht abbilden kann.
            a += ["-device", "tpm-tis-device,tpmdev=tpm0,ppi=off"]
        }

        switch display {
        case .ramfb: a += ["-device", "ramfb"]
        case .virtioGPU: a += ["-device", "virtio-gpu-pci"]
        }

        a += ["-device", "qemu-xhci,id=xhci"]
        a += ["-device", "usb-kbd,bus=xhci.0"]
        a += ["-device", "usb-tablet,bus=xhci.0"]

        var discs: [URL] = []
        if config.installMediaAttached, let iso = config.installMediaPath {
            discs.append(URL(fileURLWithPath: iso))
        }
        discs += extraDiscs
        for (index, disc) in discs.enumerated() {
            a += ["-drive", "if=none,id=cd\(index),media=cdrom,readonly=on,file=\(e(disc.path))"]
            a += ["-device", "usb-storage,bus=xhci.0,drive=cd\(index),removable=on,bootindex=\(index == 0 ? 1 : 10 + index)"]
        }

        if config.guestOS == .windows11 {
            // Windows on ARM bringt einen NVMe-Treiber mit, aber keinen virtio-blk-Treiber.
            a += ["-device", "nvme,drive=hd0,serial=moonvisor0,bootindex=0"]
        } else {
            a += ["-device", "virtio-blk-pci,drive=hd0,bootindex=0"]
        }

        switch config.networkMode {
        case .shared:
            var netdev = "user,id=net0"
            for fwd in config.portForwards {
                netdev += ",hostfwd=\(fwd.proto)::\(fwd.hostPort)-:\(fwd.guestPort)"
            }
            a += ["-netdev", netdev]
            a += ["-device", "virtio-net-pci,netdev=net0,mac=\(config.macAddress)"]
        case .disconnected:
            break
        }

        if config.soundEnabled {
            a += ["-audiodev", "coreaudio,id=snd0,in.voices=0"]
            a += ["-device", "intel-hda", "-device", "hda-output,audiodev=snd0"]
        }

        // Kanal zu den Moonvisor Tools im Gast (Auflösung, Zwischenablage).
        a += ["-chardev", "socket,id=agent0,path=\(e(sockets.agent)),server=on,wait=off"]
        a += ["-device", "virtio-serial-pci,id=vser0"]
        a += ["-device", "virtserialport,bus=vser0.0,chardev=agent0,name=\(GuestTools.portName)"]

        a += ["-device", "virtio-balloon-pci"]
        a += ["-device", "virtio-rng-pci"]

        if config.guestOS == .windows11 {
            a += ["-rtc", "base=localtime"]
        }

        a += ["-display", "none"]
        a += ["-vnc", "unix:\(e(sockets.vnc))"]
        a += ["-qmp", "unix:\(e(sockets.qmp)),server=on,wait=off"]
        if let loadSnapshot {
            a += ["-loadvm", loadSnapshot]
        }
        return a
    }

    public var swtpmArguments: [String] {
        [
            "socket", "--tpm2",
            "--tpmstate", "dir=\(bundle.tpmStateURL.path)",
            "--ctrl", "type=unixio,path=\(sockets.tpm)",
            "--terminate",
        ]
    }
}
