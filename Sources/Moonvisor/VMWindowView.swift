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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if entry.state != .stopped {
                VMDisplayView(session: entry.display, commandAsControl: entry.config.commandAsControl,
                              autoResize: entry.config.usesVirtioGPU,
                              onDropFiles: entry.toolsActive ? { urls in model.dropFiles(urls, into: entry) } : nil)
                    .ignoresSafeArea()
                if !entry.display.connected {
                    overlay {
                        ProgressView().controlSize(.large).tint(Moon.accent)
                        Text(entry.state == .stopping ? "Wird heruntergefahren …" : "\(entry.config.name) startet …")
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(Moon.text)
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
        .onAppear {
            if entry.config.startOnOpen && entry.state == .stopped { model.start(entry) }
        }
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

    private func overlay<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Moon.deep.opacity(0.82).ignoresSafeArea()
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
                    Text(entry.config.autoConfirmCDBoot ? "Beim Start wird die Installation von der ISO begonnen." : "Installationsmedium ist eingelegt.")
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
