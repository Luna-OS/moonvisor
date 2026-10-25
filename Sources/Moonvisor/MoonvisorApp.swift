import AppKit
import MoonvisorCore
import SwiftUI

@main
struct MoonvisorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Kontrollcenter", id: "control-center") {
            ControlCenterView()
                .environment(model)
                .preferredColorScheme(.dark)
                .errorAlert(model)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 520, height: 560)

        WindowGroup("Virtuelle Maschine", id: "vm", for: String.self) { $id in
            VMWindowView(id: id ?? "")
                .environment(model)
                .preferredColorScheme(.dark)
                .errorAlert(model)
        }
        .defaultSize(width: 1100, height: 760)
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))

        WindowGroup("Konfiguration", id: "config", for: String.self) { $id in
            ConfigurationWindow(id: id ?? "")
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)

        Window("Neue virtuelle Maschine", id: "assistant") {
            AssistantView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .commands { MoonCommands(model: model) }
    }
}

struct MoonCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.focusedVM) private var vm

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Nach Updates suchen …") { model.checkForUpdates(userInitiated: true) }
        }
        CommandGroup(replacing: .newItem) {
            Button("Neue virtuelle Maschine …") { openWindow(id: "assistant") }
                .keyboardShortcut("n")
            Button("Kontrollcenter") { openWindow(id: "control-center") }
                .keyboardShortcut("c", modifiers: [.command, .option])
        }
        CommandMenu("Aktionen") {
            Button(vm?.state == .paused ? "Fortsetzen" : "Starten") {
                guard let vm else { return }
                vm.state == .paused ? model.resume(vm) : model.start(vm)
            }
            .disabled(vm == nil || !(vm?.state == .stopped || vm?.state == .paused))
            Button("Anhalten") { if let vm { model.pause(vm) } }
                .disabled(vm?.state != .running)
            Divider()
            Button("Herunterfahren") { if let vm { model.shutdown(vm) } }
                .disabled(vm == nil || vm?.state == .stopped)
            Button("Neu starten") { if let vm { model.restart(vm) } }
                .disabled(vm?.state != .running)
            Button("Ausschalten") { if let vm { model.powerOff(vm) } }
                .disabled(vm == nil || vm?.state == .stopped)
            Divider()
            Button("Strg+Alt+Entf senden") { if let vm { model.ctrlAltDelete(vm) } }
                .disabled(vm?.state != .running)
            Button("Installationsmedium auswerfen") { if let vm { model.ejectInstallMedia(vm) } }
                .disabled(vm?.config.installMediaAttached != true)
            Button("Moonvisor Tools installieren") { if let vm { model.installTools(vm) } }
                .disabled(vm?.state != .running || vm?.config.guestOS != .windows11)
            Button("Protokolle öffnen") { if let vm { model.openLog(vm) } }
                .disabled(vm == nil)
            Button("Diagnose kopieren") { if let vm { model.copyDiagnostics(vm) } }
                .disabled(vm == nil)
            Divider()
            Button("Konfigurieren …") { if let vm { openWindow(id: "config", value: vm.id) } }
                .disabled(vm == nil)
                .keyboardShortcut(",", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Link("Moonvisor auf GitHub", destination: URL(string: "https://github.com/Luna-OS/moonvisor")!)
            Link("Windows 11 ARM64 herunterladen", destination: URL(string: "https://www.microsoft.com/de-de/software-download/windows11arm64")!)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { PreviewRenderer.runIfRequested() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Laufende VMs dürfen weiterlaufen (Moonvisor verbindet sich beim nächsten Start wieder),
    /// oder werden auf Wunsch heruntergefahren.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Für ein Update laufen VMs einfach weiter; die neue Version verbindet sich wieder mit ihnen.
        guard let model, model.runningCount > 0, !model.installingUpdate else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = model.runningCount == 1 ? "Eine VM läuft noch." : "\(model.runningCount) VMs laufen noch."
        alert.informativeText = "Sie können im Hintergrund weiterlaufen. Moonvisor verbindet sich beim nächsten Öffnen wieder mit ihnen."
        alert.addButton(withTitle: "Weiterlaufen lassen")
        alert.addButton(withTitle: "Alle herunterfahren")
        alert.addButton(withTitle: "Abbrechen")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .terminateNow
        case .alertSecondButtonReturn:
            // Kurze Wartezeiten: Eine hängende VM soll das Beenden nicht aufhalten.
            for entry in model.entries where entry.state != .stopped {
                try? VMRunner.captureThumbnail(entry.bundle, timeout: 2)
                try? VMRunner.shutdown(entry.bundle, timeout: 2)
            }
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.installUpdateOnQuit()
    }
}

extension View {
    func errorAlert(_ model: AppModel) -> some View {
        alert("Moonvisor", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("vmFolder") private var vmFolder = ""
    @AppStorage(AppModel.autoUpdateKey) private var autoUpdate = true

    var body: some View {
        Form {
            Section("Updates") {
                LabeledContent("Version", value: AppUpdater.currentVersion ?? "Entwicklungsversion")
                Toggle("Updates automatisch laden und beim Beenden installieren", isOn: $autoUpdate)
                    .onChange(of: autoUpdate) { if autoUpdate { model.checkForUpdates(userInitiated: false) } }
                HStack {
                    Button("Jetzt nach Updates suchen") { model.checkForUpdates(userInitiated: true) }
                        .disabled(model.updatePhase == .checking)
                    if model.updatePhase == .checking { ProgressView().controlSize(.small) }
                }
                if let update = model.update {
                    Text(updateStatus(update)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Section("Virtuelle Maschinen") {
                LabeledContent("Ordner") {
                    HStack {
                        Text(VMLibrary.defaultFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        Button("Ändern …") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url {
                                vmFolder = url.path
                                model.reload()
                            }
                        }
                    }
                }
            }
            Section("Engine") {
                let s = model.toolchainStatus
                LabeledContent("Engine", value: engineDescription(s))
                LabeledContent("DirectX (3D)", value: EngineStore.supportsDirectX ? "verfügbar (experimentell)" : "benötigt die Moonvisor-Engine")
                LabeledContent("Treiber-CD", value: DriverStore.cachedVirtioISO == nil ? "wird bei der ersten Windows-VM geladen" : "vorhanden")
                if let error = model.engineError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if model.engineProgress != nil {
                    ProgressView().controlSize(.small)
                } else if EngineStore.installedURL == nil {
                    Button("Moonvisor-Engine herunterladen") { model.installEngine() }
                }
                Button("Erneut prüfen") { model.reload() }
            }
            Section("Kommandozeile") {
                Text("Mit `moonctl` lassen sich VMs auch im Terminal steuern, z. B. `moonctl list` oder `moonctl start \"Windows 11\"`.")
                    .font(.system(size: 12))
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 560)
    }

    private func updateStatus(_ update: AppUpdater.Release) -> String {
        switch model.updatePhase {
        case .downloading(let value): return "Moonvisor \(update.version) wird geladen … \(Int(value * 100)) %"
        case .ready: return "Moonvisor \(update.version) ist geladen und wird beim Beenden installiert."
        case .failed(let message): return message
        case .idle, .checking: return "Moonvisor \(update.version) ist verfügbar."
        }
    }

    private func engineDescription(_ s: Toolchain.Status) -> String {
        guard s.isComplete, let prefix = s.prefix else { return "fehlt (\(s.missing.joined(separator: ", ")))" }
        if s.isMoonvisorEngine { return "Moonvisor-Engine \(EngineStore.requiredVersion)" }
        return prefix.path
    }
}
