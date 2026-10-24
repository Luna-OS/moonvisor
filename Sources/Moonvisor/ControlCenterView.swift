import AppKit
import MoonvisorCore
import SwiftUI

struct ControlCenterView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var hovered: String?
    @State private var confirmDelete: VMEntry?

    var body: some View {
        ZStack {
            MoonBackground()
            VStack(spacing: 0) {
                header
                if !model.toolchainStatus.isComplete || model.engineProgress != nil || model.engineError != nil {
                    EngineBanner()
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
                if model.update != nil {
                    UpdateBanner()
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
                if model.entries.isEmpty {
                    emptyState
                } else {
                    MoonScroll {
                        LazyVStack(spacing: 10) {
                            ForEach(model.entries) { entry in
                                row(entry)
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { openWindow(id: "assistant") } label: { Image(systemName: "plus") }
                    .help("Neue virtuelle Maschine")
            }
        }
        .confirmationDialog("„\(confirmDelete?.config.name ?? "")“ in den Papierkorb legen?", isPresented: .init(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }
        )) {
            Button("In den Papierkorb", role: .destructive) {
                if let entry = confirmDelete { model.moveToTrash(entry) }
            }
        } message: {
            Text("Die virtuelle Festplatte und alle Schnappschüsse werden mit verschoben.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            MoonLogo(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Moonvisor")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Moon.text)
                Text("Kontrollcenter")
                    .font(.system(size: 11))
                    .foregroundStyle(Moon.textMuted)
            }
            Spacer()
            if model.runningCount > 0 {
                Label("\(model.runningCount) aktiv", systemImage: "circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Moon.mint)
                    .labelStyle(.titleAndIcon)
                    .imageScale(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            MoonLogo(size: 72)
            Text("Noch keine virtuelle Maschine")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(Moon.text)
            Text("Installiere Windows 11 auf deinem Mac mit Apple-Chip –\nin wenigen Schritten, vollautomatisch.")
                .multilineTextAlignment(.center)
                .font(.system(size: 13))
                .foregroundStyle(Moon.textMuted)
            Button("Neue VM erstellen") { openWindow(id: "assistant") }
                .buttonStyle(MoonPrimaryButtonStyle())
            Spacer()
        }
        .padding(30)
    }

    private func row(_ entry: VMEntry) -> some View {
        MoonCard(selected: model.selectedID == entry.id) {
            HStack(spacing: 14) {
                thumbnail(entry)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.config.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Moon.text)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Circle().fill(entry.state.color).frame(width: 7, height: 7)
                        Text(entry.busyMessage ?? entry.state.displayName)
                            .font(.system(size: 11))
                            .foregroundStyle(Moon.textSecondary)
                    }
                    Text("\(entry.config.guestOS.displayName) · \(entry.config.cpuCount) Kerne · \(entry.config.memoryMB / 1024) GB RAM")
                        .font(.system(size: 11))
                        .foregroundStyle(Moon.textMuted)
                }
                Spacer()
                if entry.state == .stopped {
                    Button { model.start(entry); openWindow(id: "vm", value: entry.id) } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Moon.text)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Moon.accentGradient))
                    }
                    .buttonStyle(.plain)
                    .help("Starten")
                    .opacity(hovered == entry.id ? 1 : 0.75)
                }
            }
            .padding(10)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? entry.id : (hovered == entry.id ? nil : hovered) }
        .onTapGesture(count: 2) { openWindow(id: "vm", value: entry.id) }
        .onTapGesture { model.selectedID = entry.id }
        .contextMenu { contextMenu(entry) }
    }

    private func thumbnail(_ entry: VMEntry) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Moon.deep)
            if let image = entry.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(entry.state == .stopped ? 0.55 : 1)
            } else {
                Image(systemName: entry.symbolName)
                    .font(.system(size: 26))
                    .foregroundStyle(Moon.accentLight)
            }
        }
        .frame(width: 112, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Moon.line))
    }

    @ViewBuilder
    private func contextMenu(_ entry: VMEntry) -> some View {
        Button("Öffnen") { openWindow(id: "vm", value: entry.id) }
        if entry.state == .stopped {
            Button("Starten") { model.start(entry); openWindow(id: "vm", value: entry.id) }
        } else {
            Button("Herunterfahren") { model.shutdown(entry) }
            Button("Ausschalten") { model.powerOff(entry) }
        }
        Divider()
        Button("Konfigurieren …") { openWindow(id: "config", value: entry.id) }
        Button("Im Finder zeigen") { model.revealInFinder(entry) }
        Divider()
        Button("In den Papierkorb legen …", role: .destructive) { confirmDelete = entry }
            .disabled(entry.state != .stopped)
    }
}

struct EngineBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.engineError == nil ? "shippingbox" : "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundStyle(Moon.gold)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Moon.text)
                if let fraction {
                    ProgressView(value: fraction).tint(Moon.accent)
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Moon.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.engineProgress == nil {
                Button(model.engineError == nil ? "Herunterladen" : "Erneut versuchen") { model.installEngine() }
                    .buttonStyle(MoonPrimaryButtonStyle())
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Moon.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Moon.gold.opacity(0.4)))
    }

    private var title: String {
        switch model.engineProgress {
        case .checking: return "Virtualisierungs-Engine wird vorbereitet …"
        case .downloading: return "Virtualisierungs-Engine wird geladen …"
        case .verifying: return "Engine wird geprüft …"
        case .unpacking: return "Engine wird eingerichtet …"
        case .done: return "Engine ist bereit"
        case nil: return model.engineError == nil ? "Virtualisierungs-Engine fehlt" : "Engine konnte nicht geladen werden"
        }
    }

    private var fraction: Double? {
        switch model.engineProgress {
        case .downloading(let value): return value
        case .checking: return 0
        case .verifying, .unpacking, .done: return 1
        case nil: return nil
        }
    }

    private var detail: String {
        if let error = model.engineError { return error }
        if model.engineProgress != nil {
            return "Einmaliger Download von QEMU, TPM, UEFI-Firmware und den 3D-Bausteinen. Danach läuft alles ohne Internet."
        }
        return "Moonvisor lädt die Engine (QEMU, TPM, UEFI-Firmware, 3D-Bausteine) einmalig herunter."
    }
}

/// Neue Moonvisor-Version: Fortschritt beim Laden, danach „Jetzt neu starten“.
struct UpdateBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let update = model.update {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(Moon.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(update))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Moon.text)
                    if case .downloading(let value) = model.updatePhase {
                        ProgressView(value: value).tint(Moon.accent)
                    }
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Moon.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Was ist neu?", destination: update.pageURL)
                        .font(.system(size: 11))
                }
                Spacer()
                actions(update)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Moon.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Moon.accent.opacity(0.4)))
        }
    }

    @ViewBuilder
    private func actions(_ update: AppUpdater.Release) -> some View {
        switch model.updatePhase {
        case .ready:
            Button("Jetzt neu starten") { model.installUpdateNow() }
                .buttonStyle(MoonPrimaryButtonStyle())
        case .idle, .failed:
            if AppUpdater.installedApp == nil {
                Button("Auf GitHub laden") { NSWorkspace.shared.open(update.pageURL) }
                    .buttonStyle(MoonPrimaryButtonStyle())
            } else {
                Button(isFailed ? "Erneut versuchen" : "Laden") { model.downloadUpdate() }
                    .buttonStyle(MoonPrimaryButtonStyle())
            }
        case .checking, .downloading:
            EmptyView()
        }
    }

    private var isFailed: Bool {
        if case .failed = model.updatePhase { return true }
        return false
    }

    private var icon: String {
        isFailed ? "exclamationmark.triangle" : "arrow.down.circle"
    }

    private func title(_ update: AppUpdater.Release) -> String {
        switch model.updatePhase {
        case .downloading: return "Moonvisor \(update.version) wird geladen …"
        case .ready: return "Moonvisor \(update.version) ist bereit"
        case .failed: return "Update auf \(update.version) fehlgeschlagen"
        case .idle, .checking: return "Moonvisor \(update.version) ist verfügbar"
        }
    }

    private var detail: String {
        switch model.updatePhase {
        case .ready:
            return "Wird beim Beenden installiert, oder gleich mit „Jetzt neu starten“. Laufende VMs laufen dabei weiter."
        case .failed(let message):
            return message
        case .downloading:
            return "Das Update wird geprüft und beim Beenden installiert."
        case .idle, .checking:
            return AppUpdater.installedApp == nil
                ? "Moonvisor läuft nicht aus dem Programme-Ordner und kann sich deshalb nicht selbst aktualisieren."
                : "Lädt etwa 2 MB und installiert das Update beim Beenden."
        }
    }
}
