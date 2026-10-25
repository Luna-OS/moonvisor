import AppKit
import MoonvisorCore
import SwiftUI

struct FocusedVMKey: FocusedValueKey {
    typealias Value = VMEntry
}

extension FocusedValues {
    var focusedVM: VMEntry? {
        get { self[FocusedVMKey.self] }
        set { self[FocusedVMKey.self] = newValue }
    }
}

struct VMWindowView: View {
    let id: String
    @Environment(AppModel.self) private var model

    var body: some View {
        if let entry = model.entry(id) {
            VMWindowContent(entry: entry)
                .focusedSceneValue(\.focusedVM, entry)
        } else {
            ZStack {
                MoonBackground()
                Text("Diese VM gibt es nicht mehr.").foregroundStyle(Moon.textMuted)
            }
            .frame(minWidth: 480, minHeight: 320)
        }
    }
}

struct VMWindowContent: View {
    @Bindable var entry: VMEntry
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var snapshotPrompt = false
    @State private var snapshotName = ""
    @State private var directXHintHidden = false
    /// Die Tools melden sich erst einige Zeit nach dem Windows-Start: vorher keinen Hinweis auf fehlende Tools zeigen.
    @State private var toolsOverdue = false
    /// Während der Windows-Installation kommen die Tools erst nach dem ersten Anmelden. Melden sie sich auch nach
    /// einer Stunde nicht, ist wohl etwas schiefgegangen.
    @State private var setupOverdue = false
    /// Die Startanzeige steht schon lange: dann erklären und einen Neustart anbieten.
    @State private var waitingOverdue = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if entry.state != .stopped {
                VMDisplayView(session: entry.display, commandAsControl: entry.config.commandAsControl,
                              autoResize: entry.config.usesVirtioGPU && entry.config.fixedResolution == nil,
                              onDropFiles: entry.toolsActive ? { urls in model.dropFiles(urls, into: entry) } : nil)
                    .ignoresSafeArea()
                // Bis Firmware oder Windows ein Bild ausgeben, zeigt QEMU nur einen englischen Hinweis
                // („Guest has not initialized the display“). Den deckt die Startanzeige ab.
                if showsWaitingOverlay {
                    // Hatte die VM schon ein Bild, ist der Bildschirm meist nur im Ruhezustand: Maus und Tastatur
                    // gehen weiter an den Gast, damit er aufwacht.
                    overlay(passThrough: displayAsleep) {
                        ProgressView().controlSize(.large).tint(Moon.accent)
                        Text(waitingText)
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(Moon.text)
                        if waitingOverdue, entry.state == .running {
                            Text(waitingHelp)
                                .font(.system(size: 12)).foregroundStyle(Moon.textMuted)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 460)
                            // Einen Neustart nur anbieten, wenn die VM seit dem Start kein Bild hatte: sonst geht ungesicherte Arbeit verloren.
                            if !entry.directXSetupRunning && !displayAsleep {
                                Button("Neu starten") { model.restart(entry) }.buttonStyle(MoonPrimaryButtonStyle())
                            }
                        }
                        if let error = entry.display.lastError {
                            Text("Bildschirm: \(error)")
                                .font(.system(size: 11)).foregroundStyle(Moon.textMuted)
                                .multilineTextAlignment(.center)
                                .textSelection(.enabled)
                                .frame(maxWidth: 480)
                        }
                        if entry.state == .running {
                            Button("Protokoll öffnen") { model.openLog(entry) }.buttonStyle(.link)
                        }
                    }
                }
                if entry.display.connected, entry.state == .running, !directXHintHidden, let hint = directXHint {
                    VStack {
                        Spacer()
                        directXBanner(hint)
                    }
                    .padding(16)
                }
                if entry.state == .paused {
                    overlay {
                        Image(systemName: "pause.circle.fill").font(.system(size: 56)).foregroundStyle(Moon.gold)
                        Text("Angehalten").font(.system(size: 15, weight: .medium)).foregroundStyle(Moon.text)
                        Button("Fortsetzen") { model.resume(entry) }.buttonStyle(MoonPrimaryButtonStyle())
                    }
                }
            } else {
                stoppedView
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .navigationTitle(entry.config.name)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .toolbarBackground(Moon.panel, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .modifier(FullScreenToolbar())
        .sheet(isPresented: $snapshotPrompt) { snapshotSheet }
        .task(id: waitingKey) {
            waitingOverdue = false
            guard showsWaitingOverlay, entry.state == .running else { return }
            try? await Task.sleep(for: .seconds(entry.display.hasShownGuest ? 30 : 60))
            if !Task.isCancelled { waitingOverdue = true }
        }
        .task(id: entry.display.connected) {
            toolsOverdue = false
            setupOverdue = false
            guard entry.display.connected else { return }
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled else { return }
            toolsOverdue = true
            try? await Task.sleep(for: .seconds(60 * 60 - 90))
            if !Task.isCancelled { setupOverdue = true }
        }
        .onAppear {
            if entry.config.startOnOpen && entry.state == .stopped { model.start(entry) }
        }
    }

    /// Bis Firmware oder Windows ein Bild ausgeben, zeigt QEMU nur einen englischen Hinweis.
    private var showsWaitingOverlay: Bool {
        !entry.display.connected || (entry.display.waitingForGuest && entry.state != .paused)
    }

    private var waitingKey: String {
        "\(entry.display.connected)|\(entry.display.waitingForGuest)|\(entry.state.rawValue)"
    }

    /// Die VM hatte in dieser Sitzung schon ein Bild und zeigt gerade keins.
    private var displayAsleep: Bool {
        entry.display.connected && entry.display.hasShownGuest
    }

    private var waitingHelp: String {
        if entry.directXSetupRunning {
            return "Der DirectX-Treiber wird eingerichtet. Windows startet dafür neu und zeigt so lange kein Bild."
        }
        if entry.display.hasShownGuest {
            return "Der Bildschirm ist im Ruhezustand, oder der Grafiktreiber wechselt gerade. Eine Taste oder Mausbewegung weckt ihn."
        }
        return "Die VM zeigt seit dem Start kein Bild. Meist hilft ein Neustart. Bleibt es dabei, hilft das Protokoll bei der Fehlersuche."
    }

    private var waitingText: String {
        if entry.state == .stopping { return "Wird heruntergefahren …" }
        if entry.display.hasShownGuest { return "Der Bildschirm von \(entry.config.name) ist aus" }
        return "\(entry.config.name) startet …"
    }

    private var subtitle: String {
        if let busy = entry.busyMessage { return busy }
        if entry.transfers > 0 { return "Dateien werden in die VM übertragen …" }
        if entry.directXSetupRunning { return "DirectX-Treiber wird eingerichtet – Windows startet dafür neu …" }
        if entry.display.connected, entry.display.resolution.width > 0 {
            return "\(entry.state.displayName) · \(Int(entry.display.resolution.width))×\(Int(entry.display.resolution.height))"
        }
        return entry.state.displayName
    }

    private enum HintAction { case installTools, setUpDirectX }

    /// Hinweis unten im VM-Fenster: Tools-Installation läuft, Tools fehlen, oder warum DirectX noch nicht läuft.
    private var directXHint: (text: String, action: HintAction?)? {
        if entry.toolsInstallRequested && !entry.toolsActive {
            return ("Moonvisor Tools werden installiert. Windows fragt nach Administratorrechten – klicke im VM-Fenster auf „Ja“. Danach verbinden sich die Tools nach etwa einer Minute von selbst.", nil)
        }
        guard entry.config.graphics == .directX, entry.gpuDriver != "viogpu3d" else { return nil }
        if !entry.toolsActive {
            // Während der Windows-Installation nicht drängeln: Die Tools (und DirectX) kommen nach dem ersten
            // Anmelden von selbst. Der Hinweis erscheint erst, wenn Windows fertig sein müsste.
            if entry.windowsSetupPending {
                guard setupOverdue else { return nil }
                return ("Die Moonvisor Tools haben sich noch nicht gemeldet. Ist Windows fertig eingerichtet und bist du angemeldet, installiert Moonvisor sie mit einem Klick.", .installTools)
            }
            guard toolsOverdue else { return nil }
            return ("DirectX braucht die Moonvisor Tools. Melde dich in Windows an, dann installiert Moonvisor sie für dich.", .installTools)
        }
        if (entry.toolsVersion ?? 0) < 5 {
            return ("Die Moonvisor Tools in Windows sind zu alt für DirectX.", .installTools)
        }
        if entry.directXSetupRunning {
            return ("DirectX-Treiber wird eingerichtet. Windows startet dafür zwei- bis dreimal neu; zwischendurch ist kurz kein Bild zu sehen. Das dauert einige Minuten – die VM bitte nicht ausschalten.", nil)
        }
        if DriverStore.cachedDirectXISO == nil {
            return ("Die DirectX-Treiber fehlen. Schalte die VM aus und starte sie neu, dann lädt Moonvisor sie herunter.", nil)
        }
        guard entry.gpuDriver != nil else { return nil }
        return ("DirectX ist in Windows noch nicht aktiv: Windows nutzt den einfachen Grafiktreiber, Spiele finden deshalb keine 3D-Grafikkarte.", .setUpDirectX)
    }

    private func directXBanner(_ hint: (text: String, action: HintAction?)) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.directXSetupRunning || entry.toolsInstallRequested ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
                .foregroundStyle(Moon.gold)
            Text(hint.text)
                .font(.system(size: 12)).foregroundStyle(Moon.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            switch hint.action {
            case .installTools:
                Button("Moonvisor Tools installieren") { model.installTools(entry) }
                    .buttonStyle(MoonPrimaryButtonStyle())
                    .help("Moonvisor öffnet in Windows „Ausführen“ und startet die Installation. Windows muss dafür angemeldet sein.")
            case .setUpDirectX:
                Button("DirectX-Treiber einrichten") { model.setUpDirectX(entry) }
                    .buttonStyle(MoonPrimaryButtonStyle())
                    .help("Windows startet dafür zwei- bis dreimal neu. Speichere vorher deine Arbeit.")
            case nil:
                EmptyView()
            }
            Button { directXHintHidden = true } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(Moon.textMuted)
                .help("Hinweis ausblenden")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 720)
        .background(RoundedRectangle(cornerRadius: 10).fill(Moon.deep.opacity(0.92)))
    }

    private var resolutionSelection: Binding<GuestResolution?> {
        Binding(get: { entry.config.fixedResolution }, set: { model.setResolution(entry, $0) })
    }

    private func overlay<Content: View>(passThrough: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Moon.deep.opacity(0.82).ignoresSafeArea().allowsHitTesting(!passThrough)
            VStack(spacing: 14) { content() }
        }
    }

    private var stoppedView: some View {
        ZStack {
            if let image = entry.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .blur(radius: 6)
                    .opacity(0.35)
            } else {
                MoonBackground()
            }
            VStack(spacing: 16) {
                Button { model.start(entry) } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Moon.text)
                        .frame(width: 88, height: 88)
                        .background(Circle().fill(Moon.accentGradient))
                        .shadow(color: Moon.accent.opacity(0.6), radius: 18)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                Text("\(entry.config.name) ist ausgeschaltet")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Moon.text)
                if entry.config.installMediaAttached {
                    Text(Installation.shouldConfirmCDBoot(bundle: entry.bundle, config: entry.config)
                         ? "Beim Start wird die Installation von der ISO begonnen." : "Installationsmedium ist eingelegt.")
                        .font(.system(size: 12)).foregroundStyle(Moon.textMuted)
                }
                if let failure = entry.lastFailure {
                    VStack(spacing: 8) {
                        Label("Letzter Start fehlgeschlagen", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Moon.gold)
                        Text(failure)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Moon.textSecondary)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                            .frame(maxWidth: 560, alignment: .leading)
                        Button("Protokoll öffnen") { model.openLog(entry) }.buttonStyle(.link)
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Moon.deep.opacity(0.85)))
                } else if let error = entry.display.lastError, entry.thumbnail == nil {
                    Text(error).font(.system(size: 11)).foregroundStyle(Moon.textMuted)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Circle().fill(entry.state.color).frame(width: 9, height: 9).help(entry.state.displayName)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            switch entry.state {
            case .stopped:
                Button { model.start(entry) } label: { Label("Starten", systemImage: "play.fill") }
                    .help("Starten")
            case .paused:
                Button { model.resume(entry) } label: { Label("Fortsetzen", systemImage: "play.fill") }
                    .help("Fortsetzen")
            default:
                Button { model.pause(entry) } label: { Label("Anhalten", systemImage: "pause.fill") }
                    .help("Anhalten")
                    .disabled(entry.state != .running)
            }
            Menu {
                Button("Herunterfahren") { model.shutdown(entry) }
                Button("Neu starten") { model.restart(entry) }
                Divider()
                Button("Ausschalten (sofort)", role: .destructive) { model.powerOff(entry) }
            } label: {
                Label("Ausschalten", systemImage: "power")
            }
            .help("Herunterfahren oder ausschalten")
            .disabled(entry.state == .stopped)

            if entry.config.usesVirtioGPU {
                Menu {
                    Picker("Auflösung", selection: resolutionSelection) {
                        Text("An Fenster anpassen").tag(GuestResolution?.none)
                        ForEach(GuestResolution.presets) { resolution in
                            Text(resolution.name).tag(GuestResolution?.some(resolution))
                        }
                    }
                    .pickerStyle(.inline)
                    if !entry.toolsActive {
                        Divider()
                        Text("Wird angewendet, sobald die Moonvisor Tools in Windows laufen.")
                    }
                } label: {
                    Label("Auflösung", systemImage: "display")
                }
                .help("Auflösung von Windows")
            }

            Button { model.ctrlAltDelete(entry) } label: { Label("Strg+Alt+Entf", systemImage: "keyboard") }
                .help("Strg+Alt+Entf senden")
                .disabled(entry.state != .running)

            Button {
                snapshotName = "Schnappschuss \(Date().formatted(date: .abbreviated, time: .shortened))"
                snapshotPrompt = true
            } label: { Label("Schnappschuss", systemImage: "camera") }
                .help("Schnappschuss erstellen")

            Button { openWindow(id: "config", value: entry.id) } label: { Label("Konfigurieren", systemImage: "gearshape") }
                .help("Konfigurieren")
        }
    }

    private var snapshotSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Schnappschuss erstellen").font(.system(size: 15, weight: .semibold)).foregroundStyle(Moon.text)
            Text(entry.state == .stopped
                 ? "Sichert den aktuellen Stand der Festplatte."
                 : "Sichert Festplatte und Arbeitsspeicher der laufenden VM. Die VM pausiert dafür kurz.")
                .font(.system(size: 12)).foregroundStyle(Moon.textMuted)
            TextField("Name", text: $snapshotName).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Abbrechen") { snapshotPrompt = false }.buttonStyle(MoonSecondaryButtonStyle())
                Button("Erstellen") {
                    snapshotPrompt = false
                    model.takeSnapshot(entry, name: snapshotName.trimmingCharacters(in: .whitespaces))
                }
                .buttonStyle(MoonPrimaryButtonStyle())
                .disabled(snapshotName.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Moon.card)
    }
}

/// Im Vollbild gehört der Bildschirm der VM: die Werkzeugleiste erscheint nur, wenn die Maus an den oberen Rand fährt.
private struct FullScreenToolbar: ViewModifier {
    @State private var window: NSWindow?
    @State private var fullScreen = false

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.windowToolbarFullScreenVisibility(.onHover)
        } else {
            // macOS 14: Leiste im Vollbild ausblenden; die Befehle bleiben über die Menüleiste erreichbar.
            content
                .toolbar(fullScreen ? .hidden : .visible, for: .windowToolbar)
                .background(WindowReader(window: $window))
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
                    if note.object as? NSWindow === window { fullScreen = true }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { note in
                    if note.object as? NSWindow === window { fullScreen = false }
                }
        }
    }
}

/// Liefert das NSWindow, in dem eine SwiftUI-Ansicht liegt.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if window !== view.window {
            DispatchQueue.main.async { window = view.window }
        }
    }
}
