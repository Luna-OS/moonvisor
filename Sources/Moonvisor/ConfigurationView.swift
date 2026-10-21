import AppKit
import MoonvisorCore
import SwiftUI

struct ConfigurationWindow: View {
    let id: String
    @Environment(AppModel.self) private var model

    var body: some View {
        if let entry = model.entry(id) {
            ConfigurationView(entry: entry, draft: entry.config)
        } else {
            Text("Diese VM gibt es nicht mehr.").padding(40)
        }
    }
}

struct ConfigurationView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "Allgemein", hardware = "Hardware", network = "Netzwerk", options = "Optionen", snapshots = "Schnappschüsse"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "info.circle"
            case .hardware: return "cpu"
            case .network: return "network"
            case .options: return "slider.horizontal.3"
            case .snapshots: return "camera"
            }
        }
    }

    let entry: VMEntry
    @State var draft: VMConfig
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .general
    @State private var snapshots: [Snapshot] = []
    @State private var snapshotSelection: String?
    @State private var message: String?
    @State private var newHostPort = ""
    @State private var newGuestPort = ""

    private var running: Bool { entry.state != .stopped }
    private var hostCPUs: Int { Toolchain.hostCPUCount }
    private var hostMemoryGB: Int { Toolchain.hostMemoryMB / 1024 }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Moon.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                MoonScroll {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(tab.rawValue).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(Moon.text)
                        if running && (tab == .hardware || tab == .network) {
                            notice("Die VM läuft. Hardware-Änderungen gelten ab dem nächsten Start.")
                        }
                        switch tab {
                        case .general: general
                        case .hardware: hardware
                        case .network: network
                        case .options: options
                        case .snapshots: snapshotsTab
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
            }
        }
        .background(MoonBackground())
        .frame(width: 720, height: 520)
        .navigationTitle("\(entry.config.name) – Konfiguration")
        .onAppear(perform: loadSnapshots)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: entry.symbolName).foregroundStyle(Moon.accentLight)
                Text(entry.config.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Moon.text).lineLimit(1)
            }
            .padding(.bottom, 12)
            ForEach(Tab.allCases) { t in
                Button { tab = t } label: {
                    Label(t.rawValue, systemImage: t.icon)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(tab == t ? Moon.accent.opacity(0.25) : .clear))
                        .foregroundStyle(tab == t ? Moon.text : Moon.textSecondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(14)
        .frame(width: 190)
        .background(Moon.panel.opacity(0.7))
    }

    private var footer: some View {
        HStack {
            if let message {
                Text(message).font(.system(size: 11)).foregroundStyle(Moon.textMuted).lineLimit(2)
            }
            Spacer()
            Button("Abbrechen") { dismiss() }.buttonStyle(MoonSecondaryButtonStyle())
            Button("Sichern") {
                model.save(entry, config: draft)
                dismiss()
            }
            .buttonStyle(MoonPrimaryButtonStyle())
            .disabled(draft == entry.config)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .background(Moon.panel.opacity(0.85))
    }

    // MARK: Tabs

    private var general: some View {
        section {
            row("Name") { TextField("", text: $draft.name).textFieldStyle(.roundedBorder) }
            row("System") { Text(draft.guestOS.displayName).foregroundStyle(Moon.text) }
            row("Speicherort") {
                HStack {
                    Text(entry.bundle.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .foregroundStyle(Moon.textSecondary).lineLimit(1).truncationMode(.middle)
                    Button("Zeigen") { model.revealInFinder(entry) }.buttonStyle(.link)
                }
            }
            row("Belegt") {
                Text("\(formatBytes(allocatedSize(of: entry.bundle.diskURL))) von \(draft.diskSizeGB) GB")
                    .foregroundStyle(Moon.textSecondary)
            }
            row("Notizen") {
                TextEditor(text: $draft.notes)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Moon.deep))
                    .frame(height: 90)
            }
        }
    }

    private var hardware: some View {
        VStack(alignment: .leading, spacing: 16) {
            section {
                row("Prozessoren") {
                    Stepper(value: $draft.cpuCount, in: 1...hostCPUs) {
                        Text("\(draft.cpuCount) von \(hostCPUs) Kernen").foregroundStyle(Moon.text)
                    }
                }
                row("Arbeitsspeicher") {
                    HStack {
                        Slider(value: Binding(get: { Double(draft.memoryMB / 1024) }, set: { draft.memoryMB = Int($0) * 1024 }),
                               in: 1...Double(max(2, hostMemoryGB - 2)), step: 1).tint(Moon.accent)
                        Text("\(draft.memoryMB / 1024) GB").monospacedDigit().foregroundStyle(Moon.text).frame(width: 56, alignment: .trailing)
                    }
                }
                row("Grafik") {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $draft.graphics) {
                            ForEach(GraphicsMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        if draft.guestOS == .windows11 && draft.graphics == .virtio {
                            Text("Benötigt den virtio-GPU-Treiber in Windows (wird bei der Express-Installation eingerichtet).")
                                .font(.system(size: 11)).foregroundStyle(Moon.textMuted)
                        }
                    }
                }
                row("TPM 2.0") { Toggle("", isOn: $draft.tpmEnabled).labelsHidden().toggleStyle(.switch).tint(Moon.accent) }
                row("Ton") { Toggle("", isOn: $draft.soundEnabled).labelsHidden().toggleStyle(.switch).tint(Moon.accent) }
            }
            section(title: "Festplatte") {
                row("Größe") {
                    HStack {
                        Text("\(entry.config.diskSizeGB) GB").foregroundStyle(Moon.text)
                        Menu("Vergrößern") {
                            ForEach([64, 96, 128, 192, 256, 384, 512].filter { $0 > entry.config.diskSizeGB }, id: \.self) { gb in
                                Button("\(gb) GB") { grow(to: gb) }
                            }
                        }
                        .fixedSize()
                        .disabled(running)
                        Button("Bereinigen") { compact() }
                            .disabled(running)
                            .help("Gibt im Gast gelöschten Speicher an den Mac zurück")
                    }
                }
            }
            section(title: "CD/DVD") {
                row("Medium") {
                    HStack {
                        Text(draft.installMediaAttached ? (draft.installMediaPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "–") : "Kein Medium")
                            .foregroundStyle(Moon.textSecondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if draft.installMediaAttached {
                            Button("Auswerfen") { draft.installMediaAttached = false }
                        }
                        Button("ISO wählen …") { pickISO() }
                    }
                }
                row("Treiber-CD") {
                    Toggle("virtio-Treiber einlegen", isOn: $draft.attachDriversDisc)
                        .toggleStyle(.switch).tint(Moon.accent)
                        .disabled(DriverStore.cachedVirtioISO == nil)
                }
            }
        }
    }

    private var network: some View {
        VStack(alignment: .leading, spacing: 16) {
            section {
                row("Modus") {
                    Picker("", selection: $draft.networkMode) {
                        ForEach(NetworkMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
                row("MAC-Adresse") {
                    HStack {
                        Text(draft.macAddress).font(.system(size: 12, design: .monospaced)).foregroundStyle(Moon.textSecondary)
                        Button("Neu") { draft.macAddress = VMConfig.randomMAC() }.buttonStyle(.link)
                    }
                }
            }
            section(title: "Portweiterleitung (Mac → VM)") {
                ForEach(draft.portForwards) { fwd in
                    HStack {
                        Text("\(fwd.proto.uppercased())  localhost:\(fwd.hostPort)  →  VM:\(fwd.guestPort)")
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Moon.text)
                        Spacer()
                        Button { draft.portForwards.removeAll { $0 == fwd } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(Moon.rose)
                    }
                }
                HStack {
                    TextField("Mac-Port", text: $newHostPort).textFieldStyle(.roundedBorder).frame(width: 90)
                    Image(systemName: "arrow.right").foregroundStyle(Moon.textMuted)
                    TextField("VM-Port", text: $newGuestPort).textFieldStyle(.roundedBorder).frame(width: 90)
                    Button("Hinzufügen") {
                        if let h = Int(newHostPort), let g = Int(newGuestPort), (1...65535).contains(h), (1...65535).contains(g) {
                            draft.portForwards.append(PortForward(hostPort: h, guestPort: g))
                            newHostPort = ""; newGuestPort = ""
                        }
                    }
                    Spacer()
                    if draft.guestOS == .windows11 && !draft.portForwards.contains(where: { $0.guestPort == 3389 }) {
                        Button("Remotedesktop (3389)") { draft.portForwards.append(PortForward(hostPort: 3389, guestPort: 3389)) }
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private var options: some View {
        section {
            row("Beim Öffnen") {
                Toggle("VM automatisch starten, wenn ihr Fenster geöffnet wird", isOn: $draft.startOnOpen)
                    .toggleStyle(.switch).tint(Moon.accent)
            }
            row("Zwischenablage") {
                Toggle("Text-Zwischenablage mit der VM teilen", isOn: $draft.sharedClipboard)
                    .toggleStyle(.switch).tint(Moon.accent)
            }
            row("Moonvisor Tools") {
                Text(entry.toolsActive ? "Aktiv – Auflösung und Zwischenablage werden abgeglichen." : "Nicht verbunden. In Windows die CD „MOONTOOLS“ öffnen und „Moonvisor Tools installieren“ ausführen.")
                    .font(.system(size: 12)).foregroundStyle(entry.toolsActive ? Moon.mint : Moon.textMuted)
            }
            row("Tastatur") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("⌘ als Strg senden (⌘C, ⌘V wie auf dem Mac)", isOn: $draft.commandAsControl)
                        .toggleStyle(.switch).tint(Moon.accent)
                    Text(draft.commandAsControl ? "⌘ wirkt im Gast als Strg." : "⌘ wirkt im Gast als Windows-Taste.")
                        .font(.system(size: 11)).foregroundStyle(Moon.textMuted)
                }
            }
        }
    }

    private var snapshotsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if snapshots.isEmpty {
                Text("Noch keine Schnappschüsse. Erstelle einen über die Werkzeugleiste des VM-Fensters oder hier.")
                    .font(.system(size: 12)).foregroundStyle(Moon.textMuted)
            }
            ForEach(snapshots) { snap in
                MoonCard(selected: snapshotSelection == snap.name) {
                    HStack {
                        Image(systemName: "camera.fill").foregroundStyle(Moon.accentLight)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snap.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Moon.text)
                            Text("\(snap.date?.formatted(date: .abbreviated, time: .shortened) ?? "") · \(snap.vmStateSize)")
                                .font(.system(size: 11)).foregroundStyle(Moon.textMuted)
                        }
                        Spacer()
                    }
                    .padding(10)
                }
                .contentShape(Rectangle())
                .onTapGesture { snapshotSelection = snap.name }
            }
            HStack {
                Button("Neu") {
                    let name = "Schnappschuss \(snapshots.count + 1)"
                    snapshotAction { try Snapshots.create(entry.bundle, name: name, toolchain: $0) }
                }
                Button("Wiederherstellen") {
                    if let name = snapshotSelection { snapshotAction { try Snapshots.revert(entry.bundle, name: name, toolchain: $0) } }
                }
                .disabled(snapshotSelection == nil)
                Button("Löschen", role: .destructive) {
                    if let name = snapshotSelection { snapshotAction { try Snapshots.delete(entry.bundle, name: name, toolchain: $0) } }
                }
                .disabled(snapshotSelection == nil || running)
            }
        }
    }

    // MARK: Bausteine

    private func section<Content: View>(title: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Moon.textMuted)
            }
            MoonCard {
                VStack(alignment: .leading, spacing: 12) { content() }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).font(.system(size: 12)).foregroundStyle(Moon.textSecondary).frame(width: 110, alignment: .trailing)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.system(size: 12))
            .foregroundStyle(Moon.gold)
    }

    // MARK: Aktionen

    private func pickISO() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url {
            draft.installMediaPath = url.path
            draft.installMediaAttached = true
        }
    }

    private func loadSnapshots() {
        guard let toolchain = try? Toolchain.locate(requireTPM: false) else { return }
        snapshots = (try? Snapshots.list(entry.bundle, toolchain: toolchain)) ?? []
    }

    private func snapshotAction(_ body: @escaping (Toolchain) throws -> Void) {
        message = "Bitte warten …"
        DispatchQueue.global(qos: .userInitiated).async {
            let result: String
            do {
                try body(try Toolchain.locate(requireTPM: false))
                result = "Erledigt."
            } catch {
                result = error.localizedDescription
            }
            DispatchQueue.main.async {
                message = result
                loadSnapshots()
            }
        }
    }

    private func grow(to gb: Int) {
        do {
            try DiskTool.grow(entry.bundle, toGB: gb, toolchain: try Toolchain.locate(requireTPM: false))
            var config = entry.config
            config.diskSizeGB = gb
            model.save(entry, config: config)
            draft.diskSizeGB = gb
            message = "Festplatte auf \(gb) GB vergrößert. Erweitere die Partition im Gast (Datenträgerverwaltung)."
        } catch {
            message = error.localizedDescription
        }
    }

    private func compact() {
        message = "Festplatte wird bereinigt …"
        let bundle = entry.bundle
        DispatchQueue.global(qos: .userInitiated).async {
            let before = allocatedSize(of: bundle.diskURL)
            let result: String
            do {
                try DiskTool.compact(bundle, toolchain: try Toolchain.locate(requireTPM: false))
                result = "Bereinigt: \(formatBytes(before)) → \(formatBytes(allocatedSize(of: bundle.diskURL)))"
            } catch {
                result = error.localizedDescription
            }
            DispatchQueue.main.async { message = result }
        }
    }
}
