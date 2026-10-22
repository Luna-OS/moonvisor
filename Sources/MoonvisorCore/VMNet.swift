import Foundation

/// vmnet-Netzwerk für VMs: eigene IP-Adresse (vom Mac aus direkt erreichbar) oder Bridge ins lokale Netz.
///
/// Apple erlaubt vmnet nur mit Administratorrechten (oder einer Berechtigung, die Apple selbst vergibt).
/// Moonvisor richtet deshalb einmalig einen kleinen Systemdienst ein: `socket_vmnet` aus der Engine,
/// gestartet von launchd. QEMU verbindet sich ohne besondere Rechte über einen Unix-Socket damit.
public enum VMNet {
    public static let labelPrefix = "io.github.luna-os.moonvisor.vmnet"
    /// Gehört root und ist für Benutzer nicht beschreibbar, damit der Dienst nichts Fremdes ausführt.
    static let installFolder = "/Library/Application Support/Moonvisor/vmnet"
    /// Netz des gemeinsamen Modus; der Mac ist 192.168.105.1.
    public static let sharedGateway = "192.168.105.1"

    public struct Service: Hashable, Sendable {
        public var mode: NetworkMode
        public var interface: String

        public var name: String {
            mode == .bridged ? "bridged-\(interface)" : "shared"
        }
        public var label: String { "\(VMNet.labelPrefix).\(name)" }
        public var socketPath: String { "/var/run/moonvisor-vmnet-\(name).sock" }
        public var plistPath: String { "/Library/LaunchDaemons/\(label).plist" }

        public var arguments: [String] {
            var args = ["\(VMNet.installFolder)/socket_vmnet", "--socket-group=staff"]
            if mode == .bridged {
                args += ["--vmnet-mode=bridged", "--vmnet-interface=\(interface)"]
            } else {
                args += ["--vmnet-mode=shared", "--vmnet-gateway=\(VMNet.sharedGateway)"]
            }
            args.append(socketPath)
            return args
        }

        /// Läuft der Dienst (der Socket existiert)?
        public var isRunning: Bool {
            var info = stat()
            return stat(socketPath, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
        }
    }

    public static func service(for config: VMConfig) -> Service? {
        guard config.networkMode.usesVMNet else { return nil }
        let interface = config.bridgeInterface.filter { $0.isLetter || $0.isNumber }
        return Service(mode: config.networkMode, interface: interface.isEmpty ? "en0" : interface)
    }

    /// Netzwerkschnittstellen des Macs für den Bridge-Modus (z. B. en0 = WLAN oder Ethernet).
    public static func interfaces() -> [String] {
        var names: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return ["en0"] }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            let name = String(cString: item.pointee.ifa_name)
            let flags = Int32(item.pointee.ifa_flags)
            if name.hasPrefix("en"), flags & IFF_UP != 0, !names.contains(name) { names.append(name) }
            cursor = item.pointee.ifa_next
        }
        return names.isEmpty ? ["en0"] : names.sorted()
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func plist(for service: Service) -> String {
        let args = service.arguments.map { "        <string>\(xmlEscape($0))</string>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(service.label)</string>
            <key>ProgramArguments</key>
            <array>
        \(args)
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardErrorPath</key>
            <string>/var/log/moonvisor-vmnet-\(service.name).log</string>
        </dict>
        </plist>
        """
    }

    static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Shell-Befehl, der den Dienst mit Administratorrechten einrichtet. `engine` ist der Engine-Ordner.
    public static func installScript(for service: Service, engine: URL) -> String {
        let binary = engine.appendingPathComponent("libexec/socket_vmnet").path
        let plistData = Data(plist(for: service).utf8).base64EncodedString()
        return [
            "set -e",
            "mkdir -p \(quote(installFolder))",
            "cp \(quote(binary)) \(quote(installFolder + "/socket_vmnet"))",
            "chown -R root:wheel \(quote(installFolder))",
            "chmod 755 \(quote(installFolder)) \(quote(installFolder + "/socket_vmnet"))",
            "echo \(quote(plistData)) | base64 -D > \(quote(service.plistPath))",
            "chown root:wheel \(quote(service.plistPath))",
            "chmod 644 \(quote(service.plistPath))",
            "launchctl bootout system/\(service.label) 2>/dev/null || true",
            "launchctl bootstrap system \(quote(service.plistPath))",
        ].joined(separator: "\n")
    }

    /// Entfernt alle von Moonvisor eingerichteten vmnet-Dienste.
    public static func uninstallScript() -> String {
        [
            "for f in /Library/LaunchDaemons/\(labelPrefix).*.plist; do",
            "  [ -f \"$f\" ] || continue",
            "  launchctl bootout system \"$f\" 2>/dev/null || true",
            "  rm -f \"$f\"",
            "done",
            "rm -rf \(quote(installFolder))",
        ].joined(separator: "\n")
    }

    /// Wartet kurz, bis der Dienst seinen Socket angelegt hat.
    public static func waitUntilRunning(_ service: Service, seconds: Double = 8) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if service.isRunning { return true }
            usleep(200_000)
        }
        return service.isRunning
    }
}
