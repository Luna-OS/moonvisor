# 🌙 Moonvisor

**Windows 11 auf dem Mac mit Apple-Chip – Open Source, im Moon-Design.**

Moonvisor ist eine Virtualisierungs-App für macOS nach dem Vorbild von Parallels Desktop: Kontrollcenter, Installationsassistent mit Express-Installation, VM-Fenster mit eingebautem Bildschirm, Konfiguration, Schnappschüsse und eine Kommandozeile. Alles in Nachtblau und Lila.

![Kontrollcenter](docs/control-center.png)

| Installationsassistent | Windows 11 in Moonvisor – Text aus der Mac-Zwischenablage eingefügt |
| --- | --- |
| ![Assistent](docs/assistant.png) | ![Windows 11](docs/windows11.jpg) |

## Was kann Moonvisor?

| | |
| --- | --- |
| **Windows 11 ARM** | Läuft nativ über Apple **Hypervisor.framework** (keine Emulation). UEFI-Firmware, **TPM 2.0**, NVMe-Festplatte. |
| **Express-Installation** | ISO auswählen, Benutzername eingeben, fertig. Partitionierung, Edition, lokales Konto, Datenschutzseiten und Treiber erledigt Moonvisor – ohne einen Klick im Windows-Setup. |
| **Automatische Treiber** | Lädt die virtio-Treiber (Netzwerk, Grafik, Speicher, Balloon …) und installiert die ARM64-Versionen beim ersten Login. |
| **Moonvisor Tools** | Kleiner Agent im Gast (wie die Parallels Tools): **gemeinsame Zwischenablage** für Text in beide Richtungen und **Auflösung passend zum Fenster**. Wird bei der Express-Installation automatisch eingerichtet, sonst per Doppelklick von der CD „MOONTOOLS“. |
| **Kontrollcenter** | Alle VMs mit Live-Vorschau, Status und Schnellstart. |
| **VM-Fenster** | Bildschirm direkt im Fenster, Tastatur positionsgenau (deutsches Layout, AltGr, Funktionstasten), Maus ohne „Einfangen“, Anhalten, Herunterfahren, Neustart, Strg+Alt+Entf. |
| **Schnappschüsse** | Von laufenden VMs inklusive Arbeitsspeicher (dauert wenige Sekunden) oder von ausgeschalteten. Beim Wiederherstellen setzt Windows genau an der Stelle fort. |
| **Konfiguration** | CPU, RAM, Festplatte vergrößern und bereinigen, CD/DVD, Netzwerk mit Portweiterleitung (z. B. Remotedesktop), Ton, TPM, Grafikmodus, ⌘ als Strg. |
| **Parallels-Import** | Übernimmt VMs aus `~/Parallels` (Name, CPU, RAM, Festplatte). Das Original bleibt unangetastet. |
| **`moonctl`** | Alles auch im Terminal, ähnlich wie `prlctl`. |
| **Hintergrund-VMs** | VMs laufen weiter, wenn die App geschlossen wird. Beim nächsten Öffnen verbindet sich Moonvisor wieder. |

## Voraussetzungen

- Mac mit **Apple-Chip** (M1 bis M4 und neuer), macOS 14 Sonoma oder neuer
- [Homebrew](https://brew.sh) für die Virtualisierungs-Engine:
  ```bash
  brew install qemu swtpm
  ```
  Fehlt die Engine, zeigt Moonvisor einen Hinweis mit **Installieren**-Knopf, der genau diesen Befehl im Terminal ausführt.
- Eine **Windows 11 ARM64-ISO** – kostenlos bei Microsoft:
  [microsoft.com/software-download/windows11arm64](https://www.microsoft.com/de-de/software-download/windows11arm64)
  (Moonvisor findet ISOs in *Downloads* und im Parallels-Download-Ordner automatisch.)
- Etwa 20 GB freier Speicher pro Windows-VM (die Festplatte wächst nur mit den belegten Daten)

## Installation

1. `Moonvisor-…-arm64.dmg` aus den [Releases](https://github.com/Luna-OS/moonvisor/releases) laden und Moonvisor in *Programme* ziehen.
2. Moonvisor ist (noch) nicht von Apple notarisiert. Beim ersten Start daher **Rechtsklick → Öffnen**, oder einmal im Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Moonvisor.app
   ```
3. Moonvisor öffnen → **Neue VM erstellen** → *Windows 11 installieren*.

Optional die Kommandozeile verfügbar machen:

```bash
sudo ln -sf /Applications/Moonvisor.app/Contents/Resources/bin/moonctl /usr/local/bin/moonctl
```

## Kommandozeile

```text
moonctl list                               Alle VMs mit Status
moonctl doctor                             Prüft QEMU, swtpm und Firmware
moonctl create-windows --iso <pfad> [--name N] [--user U] [--password P]
                       [--cpus 4] [--memory 4096] [--disk 64] [--edition pro|home] [--manual]
moonctl import-parallels <pfad.pvm>        Parallels-VM übernehmen
moonctl start <vm> [--wait]                Starten
moonctl stop <vm> [--force]                Herunterfahren (--force: sofort aus)
moonctl restart | pause | resume | ctrl-alt-del <vm>
moonctl screenshot <vm> <datei.png>
moonctl snapshot list|create|revert|delete <vm> [name]
moonctl delete <vm>                        In den Papierkorb legen
```

## Wie funktioniert das?

Vor dem Bau hat Moonvisor sich angesehen, **wie Parallels Desktop aufgebaut ist** – nur von außen: Bundle-Struktur, verlinkte System-Frameworks, Entitlements und das offene XML-Format der VM-Konfiguration. Es wurde kein Parallels-Code dekompiliert oder übernommen; Moonvisor ist komplett eigenständig geschrieben.

Die wichtigste Erkenntnis: Parallels startet Windows-VMs in einem eigenen Prozess auf Apples **Hypervisor.framework** mit eigener Geräteemulation (macOS-VMs dagegen über Virtualization.framework, das Windows nicht unterstützt). Moonvisor macht dasselbe mit offener Software:

```
┌─────────────────────────────── Moonvisor.app (SwiftUI) ───────────────────────────────┐
│  Kontrollcenter · Assistent · VM-Fenster · Konfiguration           moonctl (CLI)      │
│        │                         │ RFB/VNC über Unix-Socket            │              │
│        └──────────── MoonvisorCore ──────────┴──── QMP (JSON) ─────────┘              │
└────────────────────────────────────┬──────────────────────────────────────────────────┘
                                     │ startet
        ┌────────────────────────────┼─────────────────────────────┐
        ▼                            ▼                             ▼
  QEMU (virt, -accel hvf)       swtpm (TPM 2.0)            edk2 UEFI-Firmware
  Hypervisor.framework          pro VM eigener Zustand     + NVRAM pro VM
  NVMe · virtio-net · ramfb/virtio-gpu · xHCI-Tastatur/Tablet · HDA-Ton
```

- **Eine VM ist ein Ordner** `~/Moonvisor/Name.moonvm` mit `config.json`, `disk.qcow2` (dünn belegt, interne Schnappschüsse), `efi-vars.fd`, `tpm/` und der Setup-CD.
- **Express-Installation:** Moonvisor erzeugt eine kleine CD `MOONSETUP` mit `autounattend.xml` (Partitionierung, Edition per generischem Microsoft-Installationsschlüssel ohne Aktivierung, lokales Konto, Überspringen der Hardware- und Online-Prüfungen) und einem Skript für den ersten Login, das die ARM64-virtio-Treiber per `pnputil` installiert.
- **Moonvisor Tools:** ein virtio-serial-Port `io.moonvisor.agent` verbindet die App mit einem PowerShell/C#-Agenten im Gast, der per `ChangeDisplaySettingsEx` die Auflösung umstellt und die Zwischenablage abgleicht.
- **Bildschirm:** ein eigener RFB-Client mit QEMU-Scancode-Erweiterung, damit jede Mac-Taste positionsgenau ankommt.
- **Steuerung:** QMP über einen Unix-Socket (Anhalten, Herunterfahren, Schnappschüsse, Bildschirmfotos).

## Grenzen (ehrlich)

Moonvisor ist jung. Was Parallels kann und Moonvisor (noch) nicht:

- **Keine 3D-Beschleunigung** (DirectX/Metal). Für Office, Browser und Entwicklung reicht es, für aktuelle Spiele nicht.
- **Bildschirmauflösung:** Während des Setups 800×600. Danach schaltet Moonvisor automatisch auf virtio-GPU um; die Moonvisor Tools wählen dann die größte Windows-Auflösung, die ins Fenster passt (keine beliebigen Zwischengrößen).
- **Kein Coherence-Modus** und kein Drag & Drop von Dateien. Die Zwischenablage teilt nur Text. Dateien lassen sich über Netzwerkfreigaben austauschen.
- **Schnappschüsse mit Arbeitsspeicher** passen nur zur Hardware-Konfiguration, mit der sie erstellt wurden. Nach Änderungen an CPU, RAM, Grafik oder Ton startet die VM aus einem solchen Schnappschuss nicht; Schnappschüsse ausgeschalteter VMs sind davon nicht betroffen.
- **Ton** nur als Ausgabe, kein Mikrofon.
- **Netzwerk** als NAT. Der Mac erreicht die VM über Portweiterleitungen (z. B. Remotedesktop auf Port 3389).
- Windows-Aktivierung erfordert eine eigene Lizenz.

## Selbst bauen

```bash
git clone https://github.com/Luna-OS/moonvisor.git
cd moonvisor
swift test                       # Unit-Tests
scripts/build-app.sh 0.1.0       # baut dist/Moonvisor.app, ZIP und DMG
```

Benötigt Xcode 16 oder neuer (Swift 5.10+).

## Lizenz

Moonvisor steht unter der [MIT-Lizenz](LICENSE).

Moonvisor bündelt keine Fremdsoftware. Zur Laufzeit verwendet es separat installierte Komponenten unter deren eigenen Lizenzen: [QEMU](https://www.qemu.org) (GPL-2.0), [swtpm](https://github.com/stefanberger/swtpm) (BSD-3-Clause), [edk2](https://github.com/tianocore/edk2) (BSD-2-Clause-Patent) und die [virtio-win-Treiber](https://github.com/virtio-win/virtio-win-pkg-scripts) (BSD-3-Clause/GPL-2.0).

Moonvisor ist ein unabhängiges Projekt und steht in keiner Verbindung zu Parallels International GmbH oder Microsoft. „Parallels“ und „Windows“ sind Marken ihrer jeweiligen Inhaber.
