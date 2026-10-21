import Foundation

/// „Moonvisor Tools“ für Windows-Gäste: installiert die ARM64-virtio-Treiber und einen kleinen Agenten,
/// der über einen virtio-serial-Port mit dem Mac spricht (Auflösung ans Fenster anpassen, Zwischenablage).
///
/// Protokoll (zeilenweise, UTF-8):
///   Mac → Gast:  `hello-host`, `resize <breite> <höhe>`, `clip <base64>`
///   Gast → Mac:  `hello <version>`, `clip <base64>`, `display <breite> <höhe>`
public enum GuestTools {
    public static let version = 2
    public static let portName = "io.moonvisor.agent"
    public static let volumeName = "MOONTOOLS"

    /// Erzeugt die Tools-CD, falls sie fehlt oder veraltet ist.
    public static func ensureDisc(for bundle: VMBundle) throws {
        let marker = "moonvisor-tools \(version)"
        let stamp = bundle.url.appendingPathComponent(".tools-version")
        if FileManager.default.fileExists(atPath: bundle.toolsDiscURL.path),
           (try? String(contentsOf: stamp, encoding: .utf8)) == marker {
            return
        }
        try buildDisc(at: bundle.toolsDiscURL)
        try marker.write(to: stamp, atomically: true, encoding: .utf8)
    }

    static func windowsText(_ text: String) -> Data {
        // PowerShell 5 liest Skripte ohne BOM als ANSI; mit BOM bleiben Umlaute korrekt.
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        return data
    }

    public static func buildDisc(at output: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("moontools-\(UUID().uuidString)")
        let tools = staging.appendingPathComponent("moon-tools")
        try fm.createDirectory(at: tools, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try windowsText(installScript).write(to: tools.appendingPathComponent("install.ps1"))
        try windowsText(agentScript).write(to: tools.appendingPathComponent("moon-agent.ps1"))
        try "\(version)".write(to: tools.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
        try Data("@echo off\r\npowershell -NoProfile -ExecutionPolicy Bypass -File \"%~dp0moon-tools\\install.ps1\"\r\n".utf8)
            .write(to: staging.appendingPathComponent("Moonvisor Tools installieren.cmd"))

        if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
        let result = try ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/hdiutil"),
            ["makehybrid", "-iso", "-joliet", "-default-volume-name", volumeName, "-o", output.path, staging.path]
        )
        guard result.status == 0 else { throw MoonError.processFailed("hdiutil", result.output) }
    }

    /// Installiert Treiber (von der virtio-Treiber-CD) und den Agenten. Fordert bei Bedarf Adminrechte an.
    static let installScript = #"""
    # Moonvisor Tools – Installation
    $ErrorActionPreference = 'Continue'
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        exit
    }

    $base = Join-Path $env:ProgramData 'Moonvisor'
    New-Item -ItemType Directory -Force -Path (Join-Path $base 'Tools') | Out-Null
    Start-Transcript -Path (Join-Path $base 'tools-install.log') -Append | Out-Null

    # ARM64-virtio-Treiber von der Treiber-CD
    foreach ($root in (Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root })) {
        if (Test-Path (Join-Path $root 'NetKVM')) {
            Write-Output "Treiber-CD: $root"
            Get-ChildItem -Path $root -Directory | ForEach-Object {
                $dir = Join-Path $_.FullName 'w11\ARM64'
                if (Test-Path $dir) {
                    Get-ChildItem -Path $dir -Filter *.inf | ForEach-Object { pnputil.exe /add-driver $_.FullName /install }
                }
            }
        }
    }

    # Agent installieren und bei jeder Anmeldung unsichtbar starten
    $agent = Join-Path $base 'Tools\moon-agent.ps1'
    Copy-Item -Force (Join-Path $PSScriptRoot 'moon-agent.ps1') $agent
    Copy-Item -Force (Join-Path $PSScriptRoot 'version.txt') (Join-Path $base 'Tools\version.txt')
    $command = "conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$agent`""
    Set-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'MoonvisorAgent' -Value $command

    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*moon-agent.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Start-Process conhost.exe -ArgumentList "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$agent`""

    Write-Output 'Moonvisor Tools installiert.'
    Stop-Transcript | Out-Null
    """#

    /// Läuft unsichtbar in der Benutzersitzung.
    static let agentScript = #"""
    # Moonvisor Agent: Fenstergröße und Zwischenablage zwischen Mac und Windows
    $ErrorActionPreference = 'SilentlyContinue'
    Add-Type -TypeDefinition @'
    using System;
    using System.IO;
    using System.Text;
    using System.Threading;
    using System.Collections.Concurrent;
    using System.Runtime.InteropServices;
    using Microsoft.Win32.SafeHandles;

    public static class MoonAgent {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

        static FileStream port;
        public static ConcurrentQueue<string> Inbox = new ConcurrentQueue<string>();
        static BlockingCollection<byte[]> outbox = new BlockingCollection<byte[]>(64);
        public static bool Connected { get { return port != null; } }

        public static bool Open(string name) {
            SafeFileHandle handle = CreateFile(@"\\.\Global\" + name, 0xC0000000, 0, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero);
            if (handle.IsInvalid) return false;
            port = new FileStream(handle, FileAccess.ReadWrite, 4096, true);
            Thread reader = new Thread(ReadLoop);
            reader.IsBackground = true;
            reader.Start();
            Thread writer = new Thread(WriteLoop);
            writer.IsBackground = true;
            writer.Start();
            return true;
        }

        // Schreiben blockiert, solange der Mac nicht verbunden ist – daher eigener Thread.
        static void WriteLoop() {
            FileStream p = port;
            try {
                foreach (byte[] data in outbox.GetConsumingEnumerable()) {
                    if (p != port) { outbox.TryAdd(data); return; }
                    p.Write(data, 0, data.Length);
                    p.Flush();
                }
            } catch (Exception) { Close(p); }
        }

        static void Close(FileStream p) {
            if (p == null) return;
            if (port == p) port = null;
            try { p.Dispose(); } catch (Exception) { }
        }

        static void ReadLoop() {
            FileStream p = port;
            byte[] buffer = new byte[65536];
            MemoryStream line = new MemoryStream();
            try {
                while (true) {
                    int n = p.Read(buffer, 0, buffer.Length);
                    if (n <= 0) { Thread.Sleep(200); continue; }
                    for (int i = 0; i < n; i++) {
                        if (buffer[i] == 10) {
                            Inbox.Enqueue(Encoding.UTF8.GetString(line.ToArray()));
                            line.SetLength(0);
                        } else {
                            line.WriteByte(buffer[i]);
                        }
                    }
                }
            } catch (Exception) {
                Close(p);
            }
        }

        public static void Send(string text) {
            // Volle Warteschlange: ältere Nachricht verwerfen statt zu blockieren.
            byte[] data = Encoding.UTF8.GetBytes(text + "\n");
            byte[] dropped;
            while (!outbox.TryAdd(data)) outbox.TryTake(out dropped);
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct DEVMODE {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
            public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
            public int dmFields;
            public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
            public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
            public short dmLogPixels;
            public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
            public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE devMode);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int ChangeDisplaySettingsEx(string device, ref DEVMODE devMode, IntPtr hwnd, int flags, IntPtr param);

        static DEVMODE NewMode() {
            DEVMODE m = new DEVMODE();
            m.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            return m;
        }

        public static string Current() {
            DEVMODE m = NewMode();
            EnumDisplaySettings(null, -1, ref m);
            return m.dmPelsWidth + " " + m.dmPelsHeight;
        }

        /// Wählt den größten verfügbaren Modus, der in das Mac-Fenster passt.
        public static string Resize(int width, int height) {
            DEVMODE current = NewMode();
            EnumDisplaySettings(null, -1, ref current);
            DEVMODE best = current;
            long bestArea = 0;
            for (int i = 0; ; i++) {
                DEVMODE m = NewMode();
                if (!EnumDisplaySettings(null, i, ref m)) break;
                if (m.dmBitsPerPel < 24 || m.dmPelsWidth > width || m.dmPelsHeight > height) continue;
                long area = (long)m.dmPelsWidth * m.dmPelsHeight;
                if (area > bestArea) { bestArea = area; best = m; }
            }
            if (bestArea == 0) return "none";
            if (best.dmPelsWidth == current.dmPelsWidth && best.dmPelsHeight == current.dmPelsHeight) return "same";
            best.dmFields = 0x00080000 | 0x00100000;
            int result = ChangeDisplaySettingsEx(null, ref best, IntPtr.Zero, 1, IntPtr.Zero);
            return result + " " + best.dmPelsWidth + "x" + best.dmPelsHeight;
        }
    }
    '@

    $name = 'io.moonvisor.agent'
    function Connect-Host {
        while (-not [MoonAgent]::Open($name)) { Start-Sleep -Seconds 5 }
        [MoonAgent]::Send('hello 1')
    }
    Connect-Host

    $last = Get-Clipboard -Raw
    $msg = $null
    while ($true) {
        while ([MoonAgent]::Inbox.TryDequeue([ref]$msg)) {
            $parts = $msg.Split(' ', 2)
            switch ($parts[0]) {
                'hello-host' { [MoonAgent]::Send('hello 1') }
                'resize' {
                    $wh = $parts[1].Split(' ')
                    [MoonAgent]::Resize([int]$wh[0], [int]$wh[1]) | Out-Null
                    [MoonAgent]::Send('display ' + [MoonAgent]::Current())
                }
                'clip' {
                    $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[1]))
                    $last = $text
                    Set-Clipboard -Value $text
                }
            }
        }
        $now = Get-Clipboard -Raw
        if ($null -ne $now -and $now -ne $last) {
            $last = $now
            [MoonAgent]::Send('clip ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($now)))
        }
        if (-not [MoonAgent]::Connected) { Connect-Host }
        Start-Sleep -Milliseconds 400
    }
    """#
}

/// Verbindung der App zum Agenten im Gast.
public final class AgentChannel: @unchecked Sendable {
    public var onMessage: ((String, String) -> Void)?
    public var onClose: (() -> Void)?
    private let path: String
    private var socket: UnixSocket?
    private let writeQueue = DispatchQueue(label: "moonvisor.agent.write")
    private var stopped = false

    public init(path: String) {
        self.path = path
    }

    public func start() {
        Thread.detachNewThread { [weak self] in self?.run() }
    }

    public func stop() {
        stopped = true
        socket?.shutdown()
    }

    private func run() {
        for _ in 0..<50 where !stopped {
            if let s = try? UnixSocket(path: path) {
                socket = s
                break
            }
            usleep(200_000)
        }
        guard let socket, !stopped else { return }
        send("hello-host")
        while !stopped {
            guard let line = try? socket.readLine() else { break }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let command = parts.first else { continue }
            let argument = parts.count > 1 ? parts[1] : ""
            DispatchQueue.main.async { self.onMessage?(command, argument) }
        }
        DispatchQueue.main.async { self.onClose?() }
    }

    public func send(_ line: String) {
        writeQueue.async { [weak self] in
            try? self?.socket?.write(Data((line + "\n").utf8))
        }
    }

    public func sendClipboard(_ text: String) {
        send("clip " + Data(text.utf8).base64EncodedString())
    }

    public func requestResolution(width: Int, height: Int) {
        send("resize \(width) \(height)")
    }
}
