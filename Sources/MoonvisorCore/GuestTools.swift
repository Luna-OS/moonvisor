import Foundation

/// „Moonvisor Tools“ für Windows-Gäste: installiert die ARM64-virtio-Treiber und einen kleinen Agenten,
/// der über einen virtio-serial-Port mit dem Mac spricht (Auflösung, Zwischenablage, Dateien).
///
/// Protokoll (zeilenweise, UTF-8, Binärdaten als Base64):
///   Mac → Gast:  `hello-host`, `resize <breite> <höhe>`, `update <skript>`, `install-3d`, `report`
///   Gast → Mac:  `hello <version>`, `display <breite> <höhe>`, `gpu viogpu3d|viogpudo|none`,
///                `gpu-setup started|missing-tools|missing-drivers`, `report <text>`
///   beide:       `clip <text>`, `img <png>`,
///                `xfer-begin <id> drop|clip`, `xfer-dir <id> <pfad>`, `xfer-file <id> <pfad> <größe>`,
///                `xfer-data <id> <daten>`, `xfer-end <id>`
public enum GuestTools {
    public static let version = 7
    public static let portName = "io.moonvisor.agent"
    public static let volumeName = "MOONTOOLS"

    /// Erzeugt die Tools-CD, falls sie fehlt oder veraltet ist.
    public static func ensureDisc(for bundle: VMBundle) throws {
        let marker = "moonvisor-tools \(version)"
        let stamp = stampURL(bundle)
        if FileManager.default.fileExists(atPath: bundle.toolsDiscURL.path),
           (try? String(contentsOf: stamp, encoding: .utf8)) == marker {
            return
        }
        try buildDisc(at: bundle.toolsDiscURL)
        try marker.write(to: stamp, atomically: true, encoding: .utf8)
    }

    static func stampURL(_ bundle: VMBundle) -> URL { bundle.url.appendingPathComponent(".tools-version") }

    /// Version der Tools-CD, mit der die VM zuletzt gestartet wurde (die CD wird nur beim Start erneuert).
    public static func discVersion(of bundle: VMBundle) -> Int? {
        guard let marker = try? String(contentsOf: stampURL(bundle), encoding: .utf8) else { return nil }
        return Int(marker.replacingOccurrences(of: "moonvisor-tools ", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Ab dieser CD-Version liegt `moontools.cmd` darauf, das „Moonvisor Tools installieren“ in der App braucht.
    public static let firstDiscWithLauncher = 7

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
        try windowsText(directXSetupScript).write(to: tools.appendingPathComponent("setup-directx.ps1"))
        try windowsText(agentScript).write(to: tools.appendingPathComponent("moon-agent.ps1"))
        try "\(version)".write(to: tools.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
        let launcher = Data("@echo off\r\npowershell -NoProfile -ExecutionPolicy Bypass -File \"%~dp0moon-tools\\install.ps1\"\r\n".utf8)
        try launcher.write(to: staging.appendingPathComponent("Moonvisor Tools installieren.cmd"))
        // Kurzer Name ohne Leerzeichen: den tippt Moonvisor über „Ausführen“ (GuestKeyboard.installToolsCommand).
        try launcher.write(to: staging.appendingPathComponent("moontools.cmd"))

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

    # DirectX-CD eingelegt und noch kein Grafiktreiber da (neue VM mit DirectX): gleich Triton einrichten. Den
    # einfachen Grafiktreiber später wieder zu entfernen braucht mehrere Neustarts und kann Windows durcheinanderbringen.
    $hasDirectXDisc = $false
    foreach ($root in (Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root })) {
        if (Test-Path (Join-Path $root 'Drivers\viogpu3d\w11\ARM64\viogpu3d.inf')) { $hasDirectXDisc = $true }
    }
    $tritonDone = Test-Path (Join-Path $env:ProgramData 'Moonvisor\DirectX\installed.txt')
    $installTriton = $hasDirectXDisc -and -not $tritonDone -and -not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\VioGpuDod')
    if ($installTriton) { Write-Output 'Neue VM mit DirectX: Triton statt des einfachen Grafiktreibers.' }

    # ARM64-virtio-Treiber von der Treiber-CD
    foreach ($root in (Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root })) {
        if (Test-Path (Join-Path $root 'NetKVM')) {
            Write-Output "Treiber-CD: $root"
            # Mit DirectX-Treiber (Triton) den einfachen Grafiktreiber nicht (wieder) installieren.
            $skipGpu = $tritonDone -or $installTriton
            Get-ChildItem -Path $root -Directory | Where-Object { -not ($skipGpu -and $_.Name -eq 'viogpudo') } | ForEach-Object {
                $dir = Join-Path $_.FullName 'w11\ARM64'
                if (Test-Path $dir) {
                    Get-ChildItem -Path $dir -Filter *.inf | ForEach-Object { pnputil.exe /add-driver $_.FullName /install }
                }
            }
        }
    }

    # Agent installieren. Der virtio-serial-Port lässt sich nur mit Adminrechten öffnen, deshalb startet
    # eine geplante Aufgabe den Agenten bei jeder Anmeldung mit höchsten Rechten in der Benutzersitzung.
    $agent = Join-Path $base 'Tools\moon-agent.ps1'
    Copy-Item -Force (Join-Path $PSScriptRoot 'moon-agent.ps1') $agent
    Copy-Item -Force (Join-Path $PSScriptRoot 'version.txt') (Join-Path $base 'Tools\version.txt')
    Get-ChildItem (Join-Path $base 'Tools') | ForEach-Object { $_.IsReadOnly = $false }
    Remove-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'MoonvisorAgent' -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$agent`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName 'Moonvisor Agent' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*moon-agent.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    if ($installTriton) {
        # Richtet Triton ein und startet Windows neu; den Agenten startet danach die Anmeldung.
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'setup-directx.ps1') -Phase 1
    } else {
        Start-Process conhost.exe -ArgumentList "--headless powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$agent`""
    }

    Write-Output 'Moonvisor Tools installiert.'
    Stop-Transcript | Out-Null
    """#

    /// Richtet den DirectX-Treiber Triton (viogpu3d) ein. Der einfache Treiber viogpudo lässt sich im laufenden
    /// Betrieb nicht entladen: Phase 1 schaltet ihn ab und startet neu, Phase 2 (beim Start als SYSTEM) entfernt
    /// ihn und installiert Triton. Danach startet Windows noch einmal neu.
    static let directXSetupScript = #"""
    # Moonvisor: DirectX-Treiber (Triton) einrichten
    param([int]$Phase = 1)
    $ErrorActionPreference = 'Continue'
    $base = Join-Path $env:ProgramData 'Moonvisor\DirectX'
    New-Item -ItemType Directory -Force -Path $base | Out-Null
    Start-Transcript -Path (Join-Path $env:ProgramData 'Moonvisor\directx-setup.log') -Append | Out-Null
    $taskName = 'Moonvisor DirectX'
    $serviceKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\VioGpuDod'

    function Install-Triton {
        pnputil.exe /add-driver (Join-Path $base 'viogpu3d.inf') /install
        Write-Output "pnputil: $LASTEXITCODE"
        pnputil.exe /enum-devices /class Display /drivers
        Set-Content -Path (Join-Path $base 'installed.txt') -Value (Get-Date -Format o)
    }

    function Restart-Soon([string]$reason) {
        shutdown.exe /r /t 15 /c $reason
    }

    if ($Phase -eq 1) {
        Add-Type -AssemblyName System.ServiceProcess
        $running = [System.ServiceProcess.ServiceController]::GetDevices() | Where-Object { $_.ServiceName -eq 'VioGpu3D' -and $_.Status -eq 'Running' }
        if ($running) { Write-Output 'Triton läuft bereits.'; Stop-Transcript | Out-Null; exit 0 }
        # Treiber und Skript nach ProgramData kopieren: Phase 2 läuft ohne Benutzer beim Start.
        $source = $null
        foreach ($root in (Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root })) {
            $dir = Join-Path $root 'Drivers\viogpu3d\w11\ARM64'
            if (Test-Path (Join-Path $dir 'viogpu3d.inf')) { $source = $dir }
        }
        if (-not $source) { Write-Output 'DirectX-Treiber-CD nicht gefunden.'; Stop-Transcript | Out-Null; exit 1 }
        Copy-Item -Force -Path (Join-Path $source '*') -Destination $base
        Copy-Item -Force -Path $PSCommandPath -Destination (Join-Path $base 'setup-directx.ps1')
        if (Test-Path $serviceKey) {
            Set-ItemProperty -Path $serviceKey -Name Start -Value 4 -Type DWord
            $script = Join-Path $base 'setup-directx.ps1'
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Phase 2"
            $trigger = New-ScheduledTaskTrigger -AtStartup
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
            Restart-Soon 'Moonvisor richtet DirectX ein. Windows startet dafür neu.'
        } else {
            Install-Triton
            Restart-Soon 'Moonvisor hat den DirectX-Treiber eingerichtet. Windows startet neu.'
        }
        Stop-Transcript | Out-Null
        exit 0
    }

    # Phase 2: viogpudo ist nicht geladen und lässt sich jetzt entfernen.
    $attempts = Join-Path $base 'attempts.txt'
    $count = 0
    if (Test-Path $attempts) { $count = [int](Get-Content $attempts) }
    Set-Content -Path $attempts -Value ($count + 1)
    Get-WindowsDriver -Online | Where-Object { (Split-Path $_.OriginalFileName -Leaf) -eq 'viogpudo.inf' } | ForEach-Object {
        pnputil.exe /delete-driver $_.Driver /uninstall /force
    }
    sc.exe delete VioGpuDod | Out-Null
    sc.exe query VioGpuDod | Out-Null
    if ($LASTEXITCODE -eq 1060 -and (Test-Path $serviceKey)) {
        # Der Dienstmanager kennt den Dienst nicht mehr, nur der Schlüssel ist übrig.
        Remove-Item -Path $serviceKey -Recurse -Force
    }
    $gone = -not (Test-Path $serviceKey)
    if (-not $gone -and $count -lt 3) {
        # Der Dienstmanager gibt den alten Treiber erst nach einem weiteren Neustart frei.
        Restart-Soon 'Moonvisor richtet DirectX ein (Schritt 2).'
        Stop-Transcript | Out-Null
        exit 0
    }
    Install-Triton
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Restart-Soon 'Moonvisor hat den DirectX-Treiber eingerichtet. Windows startet neu.'
    Stop-Transcript | Out-Null
    """#

    /// Läuft unsichtbar in der Benutzersitzung.
    static let agentScript = #"""
    # Moonvisor Agent: Fenstergröße, Zwischenablage und Dateien zwischen Mac und Windows
    $ErrorActionPreference = 'SilentlyContinue'
    # Die Windows-Zwischenablage braucht einen STA-Thread.
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        Start-Process conhost.exe -ArgumentList "--headless powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
        exit
    }
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    Add-Type -TypeDefinition @'
    using System;
    using System.IO;
    using System.Text;
    using System.Threading;
    using System.Collections.Generic;
    using System.Collections.Concurrent;
    using System.Runtime.InteropServices;
    using Microsoft.Win32.SafeHandles;

    public static class MoonAgent {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("user32.dll")]
        public static extern uint GetClipboardSequenceNumber();

        static FileStream port;
        public static ConcurrentQueue<string> Inbox = new ConcurrentQueue<string>();
        // Kurze Nachrichten (verwerfbar) haben Vorrang vor Dateiübertragungen (nie verworfen).
        static BlockingCollection<byte[]> control = new BlockingCollection<byte[]>(64);
        static BlockingCollection<byte[]> bulk = new BlockingCollection<byte[]>(16);
        public static bool Connected { get { return port != null; } }

        public static bool Open(string name) {
            SafeFileHandle handle = CreateFile(@"\\.\Global\" + name, 0xC0000000, 0, IntPtr.Zero, 3, 0x40000000, IntPtr.Zero);
            if (handle.IsInvalid) return false;
            port = new FileStream(handle, FileAccess.ReadWrite, 65536, true);
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
            BlockingCollection<byte[]>[] queues = new BlockingCollection<byte[]>[] { control, bulk };
            try {
                while (true) {
                    byte[] data;
                    BlockingCollection<byte[]>.TakeFromAny(queues, out data);
                    if (p != port) { control.TryAdd(data); return; }
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
                    int start = 0;
                    for (int i = 0; i < n; i++) {
                        if (buffer[i] != 10) continue;
                        line.Write(buffer, start, i - start);
                        Dispatch(Encoding.UTF8.GetString(line.GetBuffer(), 0, (int)line.Length));
                        line.SetLength(0);
                        start = i + 1;
                    }
                    line.Write(buffer, start, n - start);
                }
            } catch (Exception) {
                Close(p);
            }
        }

        static void Dispatch(string text) {
            if (text.StartsWith("xfer-")) {
                try { Receive(text); } catch (Exception) { }
            } else {
                Inbox.Enqueue(text);
            }
        }

        public static void Send(string text) {
            // Volle Warteschlange: ältere Nachricht verwerfen statt zu blockieren.
            byte[] data = Encoding.UTF8.GetBytes(text + "\n");
            byte[] dropped;
            while (!control.TryAdd(data)) control.TryTake(out dropped);
        }

        static void SendBulk(string text) {
            bulk.Add(Encoding.UTF8.GetBytes(text + "\n"));
        }

        public static uint ClipSeq() { return GetClipboardSequenceNumber(); }

        static string B64(string text) { return Convert.ToBase64String(Encoding.UTF8.GetBytes(text)); }
        static string FromB64(string text) { return Encoding.UTF8.GetString(Convert.FromBase64String(text)); }

        // --- Dateien empfangen (Mac → Windows) ---

        class Incoming {
            public string Mode;
            public string Root;
            public FileStream Current;
            public Dictionary<string, string> TopLevel = new Dictionary<string, string>();
            public List<string> Order = new List<string>();
        }
        static Dictionary<string, Incoming> incoming = new Dictionary<string, Incoming>();

        // Keine absoluten Pfade, kein "..": alles bleibt im Zielordner.
        static string[] SafeParts(string relative) {
            List<string> parts = new List<string>();
            foreach (string part in relative.Split('/', '\\')) {
                if (part.Length == 0 || part == "." || part == "..") continue;
                string clean = part;
                foreach (char c in Path.GetInvalidFileNameChars()) clean = clean.Replace(c, '_');
                parts.Add(clean);
            }
            return parts.ToArray();
        }

        static string Unique(string folder, string name) {
            string path = Path.Combine(folder, name);
            if (!File.Exists(path) && !Directory.Exists(path)) return path;
            string stem = Path.GetFileNameWithoutExtension(name), ext = Path.GetExtension(name);
            for (int i = 2; ; i++) {
                path = Path.Combine(folder, stem + " (" + i + ")" + ext);
                if (!File.Exists(path) && !Directory.Exists(path)) return path;
            }
        }

        static string Target(Incoming t, string relative) {
            string[] parts = SafeParts(relative);
            if (parts.Length == 0) return null;
            string top;
            if (!t.TopLevel.TryGetValue(parts[0], out top)) {
                top = Unique(t.Root, parts[0]);
                t.TopLevel[parts[0]] = top;
                t.Order.Add(top);
            }
            string path = top;
            for (int i = 1; i < parts.Length; i++) path = Path.Combine(path, parts[i]);
            return path;
        }

        static void Receive(string line) {
            string[] f = line.Split(' ');
            Incoming t;
            switch (f[0]) {
                case "xfer-begin":
                    t = new Incoming();
                    t.Mode = f[2];
                    t.Root = t.Mode == "drop"
                        ? Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory)
                        : Path.Combine(Path.GetTempPath(), "Moonvisor", f[1]);
                    Directory.CreateDirectory(t.Root);
                    incoming[f[1]] = t;
                    break;
                case "xfer-dir":
                    if (!incoming.TryGetValue(f[1], out t)) return;
                    string dir = Target(t, FromB64(f[2]));
                    if (dir != null) Directory.CreateDirectory(dir);
                    break;
                case "xfer-file":
                    if (!incoming.TryGetValue(f[1], out t)) return;
                    if (t.Current != null) { t.Current.Dispose(); t.Current = null; }
                    string file = Target(t, FromB64(f[2]));
                    if (file == null) return;
                    Directory.CreateDirectory(Path.GetDirectoryName(file));
                    t.Current = new FileStream(file, FileMode.Create, FileAccess.Write);
                    break;
                case "xfer-data":
                    if (!incoming.TryGetValue(f[1], out t) || t.Current == null) return;
                    byte[] data = Convert.FromBase64String(f[2]);
                    t.Current.Write(data, 0, data.Length);
                    break;
                case "xfer-end":
                    if (!incoming.TryGetValue(f[1], out t)) return;
                    if (t.Current != null) { t.Current.Dispose(); t.Current = null; }
                    incoming.Remove(f[1]);
                    Inbox.Enqueue("xfer-done " + t.Mode + " " + B64(string.Join("\n", t.Order.ToArray())));
                    break;
            }
        }

        // --- Dateien senden (Windows → Mac) ---

        public static void SendFiles(string[] paths, string mode) {
            Thread worker = new Thread(() => {
                try { SendFilesNow(paths, mode); } catch (Exception) { }
            });
            worker.IsBackground = true;
            worker.Start();
        }

        static void SendFilesNow(string[] paths, string mode) {
            string id = "w" + DateTime.UtcNow.Ticks;
            SendBulk("xfer-begin " + id + " " + mode);
            foreach (string raw in paths) {
                string path = raw.TrimEnd('\\');
                string name = Path.GetFileName(path);
                if (Directory.Exists(path)) {
                    SendBulk("xfer-dir " + id + " " + B64(name));
                    foreach (string sub in Directory.GetDirectories(path, "*", SearchOption.AllDirectories))
                        SendBulk("xfer-dir " + id + " " + B64(name + "/" + sub.Substring(path.Length + 1).Replace('\\', '/')));
                    foreach (string file in Directory.GetFiles(path, "*", SearchOption.AllDirectories))
                        SendFile(id, file, name + "/" + file.Substring(path.Length + 1).Replace('\\', '/'));
                } else if (File.Exists(path)) {
                    SendFile(id, path, name);
                }
            }
            SendBulk("xfer-end " + id);
        }

        static void SendFile(string id, string path, string relative) {
            using (FileStream fs = File.OpenRead(path)) {
                SendBulk("xfer-file " + id + " " + B64(relative) + " " + fs.Length);
                byte[] buffer = new byte[49152];
                int n;
                while ((n = fs.Read(buffer, 0, buffer.Length)) > 0)
                    SendBulk("xfer-data " + id + " " + Convert.ToBase64String(buffer, 0, n));
            }
        }

        public static long SizeOf(string[] paths) {
            long total = 0;
            foreach (string path in paths) {
                if (Directory.Exists(path)) {
                    foreach (string file in Directory.GetFiles(path, "*", SearchOption.AllDirectories)) total += new FileInfo(file).Length;
                } else if (File.Exists(path)) {
                    total += new FileInfo(path).Length;
                }
            }
            return total;
        }

        // --- Bildschirm ---

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

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct DISPLAY_DEVICE {
            public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
            public int StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct D3DKMT_OPENADAPTERFROMHDC { public IntPtr hDc; public uint hAdapter; public uint LuidLow; public int LuidHigh; public uint VidPnSourceId; }
        [StructLayout(LayoutKind.Sequential)]
        struct D3DKMT_ESCAPE { public uint hAdapter; public uint hDevice; public int Type; public uint Flags; public IntPtr pPrivateDriverData; public uint PrivateDriverDataSize; public uint hContext; }
        [StructLayout(LayoutKind.Sequential)]
        struct D3DKMT_CLOSEADAPTER { public uint hAdapter; }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE devMode);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int ChangeDisplaySettingsEx(string device, ref DEVMODE devMode, IntPtr hwnd, int flags, IntPtr param);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplayDevices(string device, uint index, ref DISPLAY_DEVICE dd, uint flags);
        [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr CreateDC(string driver, string device, string output, IntPtr init);
        [DllImport("gdi32.dll")]
        static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll")]
        static extern int D3DKMTOpenAdapterFromHdc(ref D3DKMT_OPENADAPTERFROMHDC data);
        [DllImport("gdi32.dll")]
        static extern int D3DKMTEscape(ref D3DKMT_ESCAPE data);
        [DllImport("gdi32.dll")]
        static extern int D3DKMTCloseAdapter(ref D3DKMT_CLOSEADAPTER data);

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

        static string PrimaryDevice() {
            for (uint i = 0; i < 16; i++) {
                DISPLAY_DEVICE dd = new DISPLAY_DEVICE();
                dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
                if ((dd.StateFlags & 4) != 0) return dd.DeviceName;
            }
            return @"\\.\DISPLAY1";
        }

        /// Trägt im virtio-GPU-Treiber eine eigene Auflösung ein (VIOGPU_SET_CUSTOM_RESOLUTION).
        static bool SetCustomResolution(int width, int height) {
            IntPtr dc = CreateDC(null, PrimaryDevice(), null, IntPtr.Zero);
            if (dc == IntPtr.Zero) return false;
            try {
                D3DKMT_OPENADAPTERFROMHDC open = new D3DKMT_OPENADAPTERFROMHDC();
                open.hDc = dc;
                if (D3DKMTOpenAdapterFromHdc(ref open) != 0) return false;
                try {
                    byte[] data = new byte[8];
                    BitConverter.GetBytes((ushort)2).CopyTo(data, 0);
                    BitConverter.GetBytes((ushort)4).CopyTo(data, 2);
                    BitConverter.GetBytes((ushort)width).CopyTo(data, 4);
                    BitConverter.GetBytes((ushort)height).CopyTo(data, 6);
                    GCHandle pin = GCHandle.Alloc(data, GCHandleType.Pinned);
                    try {
                        D3DKMT_ESCAPE escape = new D3DKMT_ESCAPE();
                        escape.hAdapter = open.hAdapter;
                        escape.pPrivateDriverData = pin.AddrOfPinnedObject();
                        escape.PrivateDriverDataSize = (uint)data.Length;
                        return D3DKMTEscape(ref escape) == 0;
                    } finally { pin.Free(); }
                } finally {
                    D3DKMT_CLOSEADAPTER close = new D3DKMT_CLOSEADAPTER();
                    close.hAdapter = open.hAdapter;
                    D3DKMTCloseAdapter(ref close);
                }
            } finally { DeleteDC(dc); }
        }

        static int Apply(int width, int height) {
            DEVMODE m = NewMode();
            EnumDisplaySettings(null, -1, ref m);
            m.dmPelsWidth = width;
            m.dmPelsHeight = height;
            m.dmFields = 0x00080000 | 0x00100000;
            return ChangeDisplaySettingsEx(null, ref m, IntPtr.Zero, 1, IntPtr.Zero);
        }

        /// Stellt genau die Fenstergröße ein; geht das nicht, den größten passenden Modus.
        public static string Resize(int width, int height) {
            width = Math.Max(1024, width & ~7);
            height = Math.Max(768, height);
            DEVMODE current = NewMode();
            EnumDisplaySettings(null, -1, ref current);
            if (current.dmPelsWidth == width && current.dmPelsHeight == height) return "same";
            if (SetCustomResolution(width, height)) {
                for (int attempt = 0; attempt < 3; attempt++) {
                    if (Apply(width, height) == 0) return "exact " + width + "x" + height;
                    Thread.Sleep(300);
                }
            }
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
    $version = 7
    $clipLimit = 256MB
    function Connect-Host {
        while (-not [MoonAgent]::Open($name)) { Start-Sleep -Seconds 5 }
        Send-Hello
    }
    function From-Base64([string]$text) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($text)) }
    Add-Type -AssemblyName System.ServiceProcess
    # Welcher virtio-Grafiktreiber läuft: Triton (DirectX) oder der einfache?
    function Get-GpuDriver {
        $devices = [System.ServiceProcess.ServiceController]::GetDevices()
        foreach ($service in 'VioGpu3D', 'VioGpuDod') {
            if ($devices | Where-Object { $_.ServiceName -eq $service -and $_.Status -eq 'Running' }) { return $service.ToLower() }
        }
        return 'none'
    }
    # Diagnose für den Mac: Grafikkarten, Treiber und das Protokoll der DirectX-Einrichtung.
    function Get-Report {
        $lines = New-Object Collections.Generic.List[string]
        $lines.Add('Moonvisor-Bericht aus Windows, ' + (Get-Date -Format o))
        $lines.Add("Agent $version, Grafiktreiber: " + (Get-GpuDriver))
        $lines.Add('')
        $lines.Add('== Grafikkarten ==')
        Get-CimInstance Win32_VideoController | ForEach-Object {
            $lines.Add("$($_.Name) | Status $($_.Status) | Fehlercode $($_.ConfigManagerErrorCode) | Treiber $($_.DriverVersion) | $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)")
        }
        $lines.Add('')
        $lines.Add('== pnputil /enum-devices /class Display /drivers ==')
        pnputil.exe /enum-devices /class Display /drivers 2>&1 | ForEach-Object { $lines.Add([string]$_) }
        $log = Join-Path $env:ProgramData 'Moonvisor\directx-setup.log'
        $lines.Add('')
        $lines.Add("== $log ==")
        if (Test-Path $log) {
            Get-Content $log -Tail 300 | ForEach-Object { $lines.Add([string]$_) }
        } else {
            $lines.Add('(nicht vorhanden)')
        }
        return ($lines -join "`r`n")
    }
    function Send-Hello {
        [MoonAgent]::Send("hello $version")
        [MoonAgent]::Send('gpu ' + (Get-GpuDriver))
    }
    Connect-Host

    $lastSeq = [MoonAgent]::ClipSeq()
    $msg = $null
    while ($true) {
        while ([MoonAgent]::Inbox.TryDequeue([ref]$msg)) {
            $parts = $msg.Split(' ', 2)
            try {
                switch ($parts[0]) {
                    'hello-host' { Send-Hello }
                    'report' {
                        [MoonAgent]::Send('report ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-Report))))
                    }
                    'install-3d' {
                        # DirectX-Treiber einrichten: das Skript liegt auf der CD „MOONTOOLS“, die Treiber auf der DirectX-CD.
                        $setup = $null
                        foreach ($root in (Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Root })) {
                            $candidate = Join-Path $root 'moon-tools\setup-directx.ps1'
                            if (Test-Path $candidate) { $setup = $candidate }
                        }
                        if ($setup) {
                            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$setup`" -Phase 1"
                            [MoonAgent]::Send('gpu-setup started')
                        } else {
                            [MoonAgent]::Send('gpu-setup missing-tools')
                        }
                    }
                    'resize' {
                        $wh = $parts[1].Split(' ')
                        [MoonAgent]::Resize([int]$wh[0], [int]$wh[1]) | Out-Null
                        [MoonAgent]::Send('display ' + [MoonAgent]::Current())
                    }
                    'clip' {
                        [Windows.Forms.Clipboard]::SetText((From-Base64 $parts[1]))
                        $lastSeq = [MoonAgent]::ClipSeq()
                    }
                    'img' {
                        $stream = New-Object IO.MemoryStream(,[Convert]::FromBase64String($parts[1]))
                        $image = [Drawing.Image]::FromStream($stream)
                        [Windows.Forms.Clipboard]::SetImage($image)
                        $lastSeq = [MoonAgent]::ClipSeq()
                    }
                    'xfer-done' {
                        $info = $parts[1].Split(' ')
                        $paths = (From-Base64 $info[1]) -split "`n" | Where-Object { $_ }
                        if ($info[0] -eq 'clip' -and $paths) {
                            $list = New-Object Collections.Specialized.StringCollection
                            $list.AddRange([string[]]$paths)
                            [Windows.Forms.Clipboard]::SetFileDropList($list)
                            $lastSeq = [MoonAgent]::ClipSeq()
                        }
                    }
                    'update' {
                        # Neue Agent-Version vom Mac: sich selbst ersetzen und neu starten.
                        [IO.File]::WriteAllText($PSCommandPath, (From-Base64 $parts[1]), (New-Object Text.UTF8Encoding($true)))
                        Start-Process conhost.exe -ArgumentList "--headless powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
                        exit
                    }
                }
            } catch { }
        }
        $seq = [MoonAgent]::ClipSeq()
        if ($seq -ne $lastSeq -and [MoonAgent]::Connected) {
            try {
                if ([Windows.Forms.Clipboard]::ContainsFileDropList()) {
                    $files = [string[]]@([Windows.Forms.Clipboard]::GetFileDropList())
                    if ([MoonAgent]::SizeOf($files) -le $clipLimit) { [MoonAgent]::SendFiles($files, 'clip') }
                } elseif ([Windows.Forms.Clipboard]::ContainsText()) {
                    $text = [Windows.Forms.Clipboard]::GetText()
                    [MoonAgent]::Send('clip ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)))
                } elseif ([Windows.Forms.Clipboard]::ContainsImage()) {
                    $image = [Windows.Forms.Clipboard]::GetImage()
                    $stream = New-Object IO.MemoryStream
                    $image.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
                    if ($stream.Length -le 32MB) { [MoonAgent]::Send('img ' + [Convert]::ToBase64String($stream.ToArray())) }
                }
                # Erst nach Erfolg merken: ist die Zwischenablage gerade gesperrt, beim nächsten Durchlauf erneut versuchen.
                $lastSeq = $seq
            } catch { }
        }
        if (-not [MoonAgent]::Connected) { Connect-Host }
        Start-Sleep -Milliseconds 300
    }
    """#
}

/// Verbindung der App zum Agenten im Gast.
public final class AgentChannel: @unchecked Sendable {
    public var onMessage: ((String, String) -> Void)?
    public var onClose: (() -> Void)?
    /// Dateien aus dem Gast sind vollständig angekommen (Ordner im Cache, oberste Einträge, Modus).
    public var onFilesReceived: (([URL], String) -> Void)?
    private let path: String
    private var socket: UnixSocket?
    private let writeQueue = DispatchQueue(label: "moonvisor.agent.write")
    private let transferQueue = DispatchQueue(label: "moonvisor.agent.transfer")
    private let receiver = FileReceiver()
    private var stopped = false
    private let lock = NSLock()
    private var _guestVersion: Int?

    /// Version der Moonvisor Tools im Gast, sobald sie sich gemeldet haben.
    public var guestVersion: Int? {
        lock.lock(); defer { lock.unlock() }
        return _guestVersion
    }

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
            if line.hasPrefix("xfer-") {
                // Dateidaten direkt hier verarbeiten, nicht auf dem Main-Thread.
                if let received = receiver.handle(line) {
                    DispatchQueue.main.async { self.onFilesReceived?(received.0, received.1) }
                }
                continue
            }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let command = parts.first else { continue }
            let argument = parts.count > 1 ? parts[1] : ""
            if command == "hello" {
                lock.lock(); _guestVersion = Int(argument); lock.unlock()
            }
            DispatchQueue.main.async { self.onMessage?(command, argument) }
        }
        DispatchQueue.main.async { self.onClose?() }
    }

    public func send(_ line: String) {
        writeQueue.async { [weak self] in
            try? self?.socket?.write(Data((line + "\n").utf8))
        }
    }

    /// Wartet, bis die Zeile geschrieben ist (Gegendruck bei großen Übertragungen).
    private func sendNow(_ line: String) throws {
        try writeQueue.sync {
            guard let socket else { throw MoonError.notRunning }
            try socket.write(Data((line + "\n").utf8))
        }
    }

    public func sendClipboard(_ text: String) {
        send("clip " + Data(text.utf8).base64EncodedString())
    }

    public func sendImage(png: Data) {
        send("img " + png.base64EncodedString())
    }

    public func requestResolution(width: Int, height: Int) {
        send("resize \(width) \(height)")
    }

    /// Ersetzt einen älteren Agenten im Gast durch die aktuelle Version.
    public func sendAgentUpdate() {
        send("update " + Data(GuestTools.agentScript.replacingOccurrences(of: "\n", with: "\r\n").utf8).base64EncodedString())
    }

    /// Überträgt Dateien und Ordner in den Gast: `drop` legt sie auf den Schreibtisch, `clip` in die Zwischenablage.
    public func sendFiles(_ urls: [URL], mode: String, completion: ((Error?) -> Void)? = nil) {
        transferQueue.async { [weak self] in
            var failure: Error?
            do {
                try self?.transfer(urls, mode: mode)
            } catch {
                failure = error
            }
            DispatchQueue.main.async { completion?(failure) }
        }
    }

    private func transfer(_ urls: [URL], mode: String) throws {
        let id = "m" + String(UUID().uuidString.prefix(8)).lowercased()
        func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
        try sendNow("xfer-begin \(id) \(mode)")
        for url in urls {
            for item in FileTransfer.items(below: url) {
                if item.isDirectory {
                    try sendNow("xfer-dir \(id) \(b64(item.relativePath))")
                    continue
                }
                let handle = try FileHandle(forReadingFrom: item.url)
                defer { try? handle.close() }
                try sendNow("xfer-file \(id) \(b64(item.relativePath)) \(item.size)")
                while let chunk = try handle.read(upToCount: FileTransfer.chunkSize), !chunk.isEmpty {
                    try sendNow("xfer-data \(id) \(chunk.base64EncodedString())")
                }
            }
        }
        try sendNow("xfer-end \(id)")
    }
}

/// Hilfen für Dateiübertragungen zwischen Mac und Gast.
public enum FileTransfer {
    static let chunkSize = 48 * 1024
    /// Obergrenze für Dateien in der gemeinsamen Zwischenablage (Drag & Drop hat keine).
    public static let clipboardLimit: Int64 = 256 * 1024 * 1024

    public struct Item {
        public var url: URL
        public var relativePath: String
        public var isDirectory: Bool
        public var size: Int64
    }

    /// Die Datei selbst bzw. der Ordner mit allem Inhalt, Pfade relativ zum Elternordner.
    public static func items(below root: URL) -> [Item] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        let name = root.lastPathComponent
        let rootIsDirectory = (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard rootIsDirectory else {
            let size = (try? root.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return [Item(url: root, relativePath: name, isDirectory: false, size: Int64(size))]
        }
        var result = [Item(url: root, relativePath: name, isDirectory: true, size: 0)]
        // /var und /private/var usw.: beide Seiten auflösen, sonst stimmen die relativen Pfade nicht.
        let base = root.resolvingSymlinksInPath().pathComponents
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return result }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            let relative = url.resolvingSymlinksInPath().pathComponents.dropFirst(base.count).joined(separator: "/")
            result.append(Item(url: url, relativePath: name + "/" + relative, isDirectory: values.isDirectory == true,
                               size: Int64(values.fileSize ?? 0)))
        }
        return result
    }

    public static func totalSize(_ urls: [URL]) -> Int64 {
        urls.flatMap { items(below: $0) }.reduce(0) { $0 + $1.size }
    }

    /// Keine absoluten Pfade, kein "..": alles bleibt im Zielordner.
    static func safeComponents(_ relative: String) -> [String] {
        relative.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .map { $0.replacingOccurrences(of: ":", with: "_") }
    }
}

/// Nimmt Dateien aus dem Gast entgegen und legt sie im Cache ab.
final class FileReceiver {
    private struct Incoming {
        var mode: String
        var root: URL
        var current: FileHandle?
        var topLevel: [String] = []
    }
    private var transfers: [String: Incoming] = [:]

    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moonvisor/Übertragungen", isDirectory: true)
    }

    /// Gibt am Ende einer Übertragung die obersten Einträge und den Modus zurück.
    func handle(_ line: String) -> ([URL], String)? {
        let f = line.split(separator: " ").map(String.init)
        guard f.count >= 2 else { return nil }
        let id = f[1]
        let fm = FileManager.default
        switch f[0] {
        case "xfer-begin" where f.count >= 3:
            let root = Self.folder.appendingPathComponent(FileTransfer.safeComponents(id).joined(), isDirectory: true)
            try? fm.removeItem(at: root)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            transfers[id] = Incoming(mode: f[2], root: root)
        case "xfer-dir" where f.count >= 3:
            guard let t = transfers[id], let url = target(t, f[2]) else { return nil }
            note(id, url)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        case "xfer-file" where f.count >= 3:
            guard var t = transfers[id] else { return nil }
            try? t.current?.close()
            t.current = nil
            if let url = target(t, f[2]) {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: url.path, contents: nil)
                t.current = try? FileHandle(forWritingTo: url)
            }
            transfers[id] = t
            if let url = target(t, f[2]) { note(id, url) }
        case "xfer-data" where f.count >= 3:
            guard let handle = transfers[id]?.current, let data = Data(base64Encoded: f[2]) else { return nil }
            try? handle.write(contentsOf: data)
        case "xfer-end":
            guard let t = transfers.removeValue(forKey: id) else { return nil }
            try? t.current?.close()
            return (t.topLevel.map { t.root.appendingPathComponent($0) }, t.mode)
        default:
            break
        }
        return nil
    }

    private func target(_ t: Incoming, _ encoded: String) -> URL? {
        guard let data = Data(base64Encoded: encoded), let relative = String(data: data, encoding: .utf8) else { return nil }
        let parts = FileTransfer.safeComponents(relative)
        guard !parts.isEmpty else { return nil }
        return parts.reduce(t.root) { $0.appendingPathComponent($1) }
    }

    private func note(_ id: String, _ url: URL) {
        guard var t = transfers[id] else { return }
        let relative = url.path.dropFirst(t.root.path.count).split(separator: "/").first.map(String.init)
        if let top = relative, !t.topLevel.contains(top) {
            t.topLevel.append(top)
            transfers[id] = t
        }
    }
}
