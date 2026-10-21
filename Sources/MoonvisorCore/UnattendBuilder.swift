import Foundation

public enum WindowsEdition: String, Codable, CaseIterable, Sendable {
    case pro, home

    public var displayName: String {
        switch self {
        case .pro: return "Windows 11 Pro"
        case .home: return "Windows 11 Home"
        }
    }

    /// Von Microsoft veröffentlichte generische Installationsschlüssel. Sie wählen nur die Edition aus
    /// und aktivieren Windows nicht; aktiviert wird später mit einer eigenen Lizenz.
    var genericSetupKey: String {
        switch self {
        case .pro: return "VK7JG-NPHTM-C97JM-9MPGT-3V66T"
        case .home: return "YTMG3-N6DKC-DKB77-7M9GH-8HVX7"
        }
    }
}

public struct ExpressInstallOptions: Codable, Hashable, Sendable {
    public var userName: String
    public var password: String
    public var computerName: String
    public var edition: WindowsEdition
    public var locale: String
    public var timeZone: String

    public init(
        userName: String,
        password: String,
        computerName: String,
        edition: WindowsEdition = .pro,
        locale: String = WindowsLocale.guess(isoPath: nil),
        timeZone: String = WindowsLocale.windowsTimeZone(for: TimeZone.current)
    ) {
        self.userName = userName
        self.password = password
        self.computerName = computerName
        self.edition = edition
        self.locale = locale
        self.timeZone = timeZone
    }
}

public enum WindowsLocale {
    static let inputLocales: [String: String] = [
        "de-DE": "0407:00000407", "de-AT": "0c07:00000407", "de-CH": "0807:00000807",
        "en-US": "0409:00000409", "en-GB": "0809:00000809",
        "fr-FR": "040c:0000040c", "es-ES": "0c0a:0000040a", "it-IT": "0410:00000410",
        "nl-NL": "0413:00020409", "pl-PL": "0415:00000415", "pt-BR": "0416:00000416",
        "tr-TR": "041f:0000041f",
    ]

    /// Sprache aus dem ISO-Namen (Microsoft-ISOs enden auf z. B. `_de-de.iso`), sonst vom Mac.
    public static func guess(isoPath: String?) -> String {
        if let iso = isoPath?.lowercased(),
           let match = iso.range(of: #"_([a-z]{2})-([a-z]{2})\.iso$"#, options: .regularExpression) {
            let code = String(iso[match]).dropFirst().dropLast(4)
            let parts = code.split(separator: "-")
            if parts.count == 2 {
                let candidate = "\(parts[0])-\(parts[1].uppercased())"
                if inputLocales[candidate] != nil { return candidate }
            }
        }
        let host = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        if inputLocales[host] != nil { return host }
        if host.hasPrefix("de") { return "de-DE" }
        return "en-US"
    }

    public static func inputLocale(for locale: String) -> String {
        inputLocales[locale] ?? "0409:00000409"
    }

    public static func windowsTimeZone(for zone: TimeZone) -> String {
        let map: [String: String] = [
            "Europe/Berlin": "W. Europe Standard Time", "Europe/Vienna": "W. Europe Standard Time",
            "Europe/Zurich": "W. Europe Standard Time", "Europe/Amsterdam": "W. Europe Standard Time",
            "Europe/Rome": "W. Europe Standard Time", "Europe/Paris": "Romance Standard Time",
            "Europe/Madrid": "Romance Standard Time", "Europe/Brussels": "Romance Standard Time",
            "Europe/London": "GMT Standard Time", "Europe/Warsaw": "Central European Standard Time",
            "Europe/Istanbul": "Turkey Standard Time",
            "America/New_York": "Eastern Standard Time", "America/Chicago": "Central Standard Time",
            "America/Denver": "Mountain Standard Time", "America/Los_Angeles": "Pacific Standard Time",
        ]
        return map[zone.identifier] ?? "UTC"
    }
}

/// Erzeugt die Setup-CD `MOONSETUP` mit `autounattend.xml` und dem Einrichtungsskript für den ersten Login.
public enum UnattendBuilder {
    public static let volumeName = "MOONSETUP"

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// NetBIOS-taugliche Computernamen: max. 15 Zeichen, nur A–Z, 0–9 und Bindestrich.
    public static func sanitizeComputerName(_ name: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let cleaned = String(name.uppercased().map { allowed.contains($0) ? $0 : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let result = String(cleaned.prefix(15))
        return result.isEmpty ? "MOONVISOR-VM" : result
    }

    static let labConfigBypasses = [
        "BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck", "BypassStorageCheck", "BypassCPUCheck",
    ]

    static func bypassCommands(startOrder: Int) -> String {
        labConfigBypasses.enumerated().map { index, key in
            """
                            <RunSynchronousCommand wcm:action="add">
                                <Order>\(startOrder + index)</Order>
                                <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v \(key) /t REG_DWORD /d 1 /f</Path>
                            </RunSynchronousCommand>
            """
        }.joined(separator: "\n")
    }

    static let component = #"processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance""#

    /// Nur die Hardwareprüfungen überspringen; der Benutzer führt das Setup selbst durch.
    public static func manualXML(locale: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">
            <settings pass="windowsPE">
                <component name="Microsoft-Windows-Setup" \(component)>
                    <RunSynchronous>
        \(bypassCommands(startOrder: 1))
                    </RunSynchronous>
                </component>
            </settings>
            <settings pass="specialize">
                <component name="Microsoft-Windows-Deployment" \(component)>
                    <RunSynchronous>
                        <RunSynchronousCommand wcm:action="add">
                            <Order>1</Order>
                            <Path>reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                        </RunSynchronousCommand>
                    </RunSynchronous>
                </component>
            </settings>
            <settings pass="oobeSystem">
                <component name="Microsoft-Windows-Shell-Setup" \(component)>
                    <FirstLogonCommands>
        \(firstLogonCommand)
                    </FirstLogonCommands>
                </component>
            </settings>
        </unattend>
        """
    }

    static let firstLogonCommand = """
                        <SynchronousCommand wcm:action="add">
                            <Order>1</Order>
                            <Description>Moonvisor Gasteinrichtung</Description>
                            <CommandLine>cmd /c for %d in (D E F G H I J K) do if exist %d:\\moon-setup.ps1 powershell -NoProfile -ExecutionPolicy Bypass -File %d:\\moon-setup.ps1</CommandLine>
                        </SynchronousCommand>
    """

    public static func expressXML(_ o: ExpressInstallOptions) -> String {
        let user = xmlEscape(o.userName)
        let password = xmlEscape(o.password)
        let input = WindowsLocale.inputLocale(for: o.locale)
        let computer = sanitizeComputerName(o.computerName)
        let international = { (pe: Bool) -> String in
            """
                    <component name="Microsoft-Windows-International-Core\(pe ? "-WinPE" : "")" \(component)>
            \(pe ? "                <SetupUILanguage><UILanguage>\(o.locale)</UILanguage></SetupUILanguage>\n" : "")                <InputLocale>\(input)</InputLocale>
                        <SystemLocale>\(o.locale)</SystemLocale>
                        <UILanguage>\(o.locale)</UILanguage>
                        <UserLocale>\(o.locale)</UserLocale>
                    </component>
            """
        }
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">
            <settings pass="windowsPE">
        \(international(true))
                <component name="Microsoft-Windows-Setup" \(component)>
                    <RunSynchronous>
        \(bypassCommands(startOrder: 1))
                    </RunSynchronous>
                    <DiskConfiguration>
                        <Disk wcm:action="add">
                            <DiskID>0</DiskID>
                            <WillWipeDisk>true</WillWipeDisk>
                            <CreatePartitions>
                                <CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>260</Size></CreatePartition>
                                <CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>
                                <CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>
                            </CreatePartitions>
                            <ModifyPartitions>
                                <ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>
                                <ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>
                            </ModifyPartitions>
                        </Disk>
                    </DiskConfiguration>
                    <ImageInstall>
                        <OSImage>
                            <InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo>
                        </OSImage>
                    </ImageInstall>
                    <UserData>
                        <AcceptEula>true</AcceptEula>
                        <ProductKey><Key>\(o.edition.genericSetupKey)</Key><WillShowUI>OnError</WillShowUI></ProductKey>
                    </UserData>
                </component>
            </settings>
            <settings pass="specialize">
                <component name="Microsoft-Windows-Shell-Setup" \(component)>
                    <ComputerName>\(computer)</ComputerName>
                    <TimeZone>\(xmlEscape(o.timeZone))</TimeZone>
                </component>
                <component name="Microsoft-Windows-Deployment" \(component)>
                    <RunSynchronous>
                        <RunSynchronousCommand wcm:action="add">
                            <Order>1</Order>
                            <Path>reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                        </RunSynchronousCommand>
                    </RunSynchronous>
                </component>
            </settings>
            <settings pass="oobeSystem">
        \(international(false))
                <component name="Microsoft-Windows-Shell-Setup" \(component)>
                    <OOBE>
                        <HideEULAPage>true</HideEULAPage>
                        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                        <ProtectYourPC>3</ProtectYourPC>
                    </OOBE>
                    <UserAccounts>
                        <LocalAccounts>
                            <LocalAccount wcm:action="add">
                                <Name>\(user)</Name>
                                <DisplayName>\(user)</DisplayName>
                                <Group>Administrators</Group>
                                <Password><Value>\(password)</Value><PlainText>true</PlainText></Password>
                            </LocalAccount>
                        </LocalAccounts>
                    </UserAccounts>
                    <AutoLogon>
                        <Enabled>true</Enabled>
                        <LogonCount>1</LogonCount>
                        <Username>\(user)</Username>
                        <Password><Value>\(password)</Value><PlainText>true</PlainText></Password>
                    </AutoLogon>
                    <FirstLogonCommands>
        \(firstLogonCommand)
                    </FirstLogonCommands>
                </component>
            </settings>
        </unattend>
        """
    }

    /// Läuft beim ersten Login im Gast: installiert die ARM64-virtio-Treiber (Netzwerk, Grafik, Balloon …)
    /// von der Treiber-CD und stellt Energieoptionen für eine VM passend ein.
    public static let guestSetupScript = #"""
    # Moonvisor Gasteinrichtung (wird einmal beim ersten Login ausgeführt)
    $ErrorActionPreference = 'Continue'
    $log = Join-Path $env:ProgramData 'Moonvisor\setup.log'
    New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
    Start-Transcript -Path $log -Append | Out-Null

    # Treiber und Agent installieren die Moonvisor Tools (eigene CD „MOONTOOLS“).
    foreach ($root in (Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root })) {
        $installer = Join-Path $root 'moon-tools\install.ps1'
        if (Test-Path $installer) {
            Write-Output "Moonvisor Tools: $installer"
            & $installer
        }
    }

    powercfg /change standby-timeout-ac 0
    powercfg /change monitor-timeout-ac 0
    powercfg /change hibernate-timeout-ac 0

    Set-Content -Path (Join-Path $env:ProgramData 'Moonvisor\setup-done.txt') -Value (Get-Date -Format o)
    Stop-Transcript | Out-Null
    """#

    /// Schreibt die Setup-CD als ISO 9660/Joliet-Abbild.
    public static func buildSetupDisc(at output: URL, unattendXML: String) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("moonsetup-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try unattendXML.write(to: staging.appendingPathComponent("autounattend.xml"), atomically: true, encoding: .utf8)
        // PowerShell 5 liest Skripte ohne BOM als ANSI; mit BOM bleiben Umlaute korrekt.
        var script = Data([0xEF, 0xBB, 0xBF])
        script.append(Data(guestSetupScript.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        try script.write(to: staging.appendingPathComponent("moon-setup.ps1"))

        if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
        let result = try ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/hdiutil"),
            ["makehybrid", "-iso", "-joliet", "-default-volume-name", volumeName, "-o", output.path, staging.path]
        )
        guard result.status == 0 else {
            throw MoonError.processFailed("hdiutil", result.output)
        }
    }
}
