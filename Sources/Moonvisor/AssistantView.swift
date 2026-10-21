import AppKit
import MoonvisorCore
import SwiftUI

/// Installationsassistent: Quelle wählen → Medium → Konto → Ressourcen → Erstellen.
struct AssistantView: View {
    enum Source: Hashable { case windows, parallels, other }
    enum Step: Int, CaseIterable { case source, media, account, resources, create }

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var step: Step = .source
    @State private var source: Source = .windows

    @State private var isoCandidates: [URL] = []
    @State private var iso: URL?
    @State private var parallelsVMs: [URL] = []
    @State private var parallelsVM: URL?

    @State private var express = true
    @State private var userName = NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
    @State private var password = ""
    @State private var passwordRepeat = ""
    @State private var edition: WindowsEdition = .pro

    @State private var name = "Windows 11"
    @State private var profile: ResourceProfile = .productivity
    @State private var cpus = 4
    @State private var memoryGB = 4
    @State private var diskGB = 64
    @State private var applyingProfile = false

    @State private var progressText = ""
    @State private var downloadProgress: Double?
    @State private var working = false
    @State private var failure: String?

    private let hostCPUs = Toolchain.hostCPUCount
    private let hostMemoryGB = Toolchain.hostMemoryMB / 1024

    var body: some View {
        ZStack {
            MoonBackground()
            VStack(spacing: 0) {
                stepper
                    .padding(.top, 18)
                    .padding(.horizontal, 28)
                Group {
                    switch step {
                    case .source: sourceStep
                    case .media: mediaStep
                    case .account: accountStep
                    case .resources: resourcesStep
                    case .create: createStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 28)
                .padding(.top, 18)
                footer
            }
        }
        .frame(width: 720, height: 560)
        .onAppear(perform: discover)
    }

    // MARK: Gerüst

    private var visibleSteps: [Step] {
        switch source {
        case .windows: return Step.allCases
        case .parallels: return [.source, .media, .create]
        case .other: return [.source, .media, .resources, .create]
        }
    }

    private func title(_ s: Step) -> String {
        switch s {
        case .source: return "Quelle"
        case .media: return source == .parallels ? "VM" : "Medium"
        case .account: return "Konto"
        case .resources: return "Ressourcen"
        case .create: return "Erstellen"
        }
    }

    private var stepper: some View {
        HStack(spacing: 8) {
            ForEach(visibleSteps, id: \.self) { s in
                let index = visibleSteps.firstIndex(of: s)!
                let current = visibleSteps.firstIndex(of: step) ?? 0
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(index <= current ? AnyShapeStyle(Moon.accentGradient) : AnyShapeStyle(Moon.card))
                        if index < current {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        } else {
                            Text("\(index + 1)").font(.system(size: 10, weight: .bold))
                        }
                    }
                    .frame(width: 20, height: 20)
                    .foregroundStyle(Moon.text)
                    Text(title(s))
                        .font(.system(size: 12, weight: index == current ? .semibold : .regular))
                        .foregroundStyle(index == current ? Moon.text : Moon.textMuted)
                }
                if s != visibleSteps.last {
                    Rectangle().fill(Moon.line).frame(height: 1).frame(maxWidth: 40)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if step != .source && !working {
                Button("Zurück") { move(-1) }
                    .buttonStyle(MoonSecondaryButtonStyle())
            }
            Spacer()
            if step == .create {
                if failure != nil {
                    Button("Erneut versuchen") { create() }
                        .buttonStyle(MoonPrimaryButtonStyle())
                }
            } else {
                Button(step == visibleSteps.dropLast().last ? "Erstellen" : "Weiter") { move(1) }
                    .buttonStyle(MoonPrimaryButtonStyle())
                    .disabled(!canContinue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(Moon.panel.opacity(0.85))
        .overlay(Rectangle().fill(Moon.line).frame(height: 1), alignment: .top)
    }

    private var canContinue: Bool {
        switch step {
        case .source: return true
        case .media: return source == .parallels ? parallelsVM != nil : iso != nil
        case .account: return !express || (!userName.trimmingCharacters(in: .whitespaces).isEmpty && password == passwordRepeat)
        case .resources: return !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .create: return false
        }
    }

    private func move(_ delta: Int) {
        guard let index = visibleSteps.firstIndex(of: step) else { return }
        let next = visibleSteps[max(0, min(visibleSteps.count - 1, index + delta))]
        step = next
        if next == .resources { applyProfile() }
        if next == .create { create() }
    }

    private func discover() {
        isoCandidates = VMLibrary.discoverInstallImages()
        iso = iso ?? isoCandidates.first(where: VMLibrary.looksLikeWindowsARM) ?? isoCandidates.first
        parallelsVMs = ParallelsImporter.discover()
        parallelsVM = parallelsVM ?? parallelsVMs.first
        applyProfile()
    }

    // MARK: Schritte

    private var sourceStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Was möchtest du installieren?", "Moonvisor richtet die virtuelle Maschine für deinen Mac mit Apple-Chip ein.")
            sourceTile(.windows, icon: "macwindow.on.rectangle", title: "Windows 11 installieren",
                       detail: "Express-Installation von einer Windows-11-ARM-ISO – ohne Klicks, mit TPM 2.0 und Treibern.", recommended: true)
            sourceTile(.parallels, icon: "arrow.right.doc.on.clipboard", title: "Von Parallels Desktop übernehmen",
                       detail: parallelsVMs.isEmpty ? "Keine Parallels-VMs in ~/Parallels gefunden." : "\(parallelsVMs.count) VM(s) gefunden. Die Festplatte wird kopiert, das Original bleibt unverändert.")
            sourceTile(.other, icon: "opticaldisc", title: "Linux oder anderes System",
                       detail: "Von einer beliebigen ARM64-ISO installieren (z. B. Ubuntu, Fedora, Debian).")
        }
    }

    private func sourceTile(_ value: Source, icon: String, title: String, detail: String, recommended: Bool = false) -> some View {
        MoonCard(selected: source == value) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(Moon.accentLight)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Moon.indigo.opacity(0.6)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Moon.text)
                        if recommended {
                            Text("Empfohlen")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Moon.accent.opacity(0.25)))
                                .foregroundStyle(Moon.accentLight)
                        }
                    }
                    Text(detail).font(.system(size: 12)).foregroundStyle(Moon.textMuted)
                }
                Spacer()
            }
            .padding(14)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            source = value
            name = value == .windows ? "Windows 11" : (value == .other ? "Linux" : name)
        }
    }

    private var mediaStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if source == .parallels {
                heading("Welche Parallels-VM?", "Name, CPU, RAM und Festplatte werden übernommen.")
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(parallelsVMs, id: \.self) { url in
                            fileRow(url, selected: parallelsVM == url) { parallelsVM = url }
                        }
                    }
                }
                Button("Andere .pvm wählen …") { pick(types: ["pvm"]) { parallelsVM = $0 } }
                    .buttonStyle(MoonSecondaryButtonStyle())
            } else {
                heading(source == .windows ? "Windows-11-Installationsmedium" : "Installationsmedium",
                        source == .windows ? "Wähle eine Windows 11 ARM64-ISO. Moonvisor sucht in Downloads und im Parallels-Download-Ordner." : "Wähle eine ARM64-ISO-Datei.")
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(isoCandidates, id: \.self) { url in
                            fileRow(url, selected: iso == url, badge: VMLibrary.looksLikeWindowsARM(url) ? "Windows ARM64" : nil) { iso = url }
                        }
                        if isoCandidates.isEmpty {
                            Text("Keine ISO-Dateien gefunden.")
                                .font(.system(size: 12)).foregroundStyle(Moon.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                HStack {
                    Button("Andere Datei wählen …") { pick(types: ["iso"]) { iso = $0 } }
                        .buttonStyle(MoonSecondaryButtonStyle())
                    if source == .windows {
                        Link(destination: URL(string: "https://www.microsoft.com/de-de/software-download/windows11arm64")!) {
                            Label("Windows 11 ARM64 bei Microsoft herunterladen", systemImage: "arrow.down.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(Moon.accentLight)
                        }
                    }
                }
            }
        }
    }

    private func fileRow(_ url: URL, selected: Bool, badge: String? = nil, action: @escaping () -> Void) -> some View {
        MoonCard(selected: selected) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Moon.accent : Moon.textMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent).font(.system(size: 12, weight: .medium)).foregroundStyle(Moon.text).lineLimit(1).truncationMode(.middle)
                    Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11)).foregroundStyle(Moon.textMuted).lineLimit(1)
                }
                Spacer()
                if let badge {
                    Text(badge).font(.system(size: 10, weight: .semibold)).foregroundStyle(Moon.mint)
                }
            }
            .padding(10)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    private var accountStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Express-Installation", "Moonvisor installiert Windows vollständig automatisch und legt ein lokales Konto an.")
            Toggle(isOn: $express) {
                Text("Express-Installation verwenden").foregroundStyle(Moon.text)
            }
            .toggleStyle(.switch)
            .tint(Moon.accent)
            if express {
                MoonCard {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                        GridRow {
                            label("Benutzername")
                            TextField("", text: $userName).textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            label("Passwort")
                            SecureField("optional", text: $password).textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            label("Wiederholen")
                            SecureField("", text: $passwordRepeat).textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            label("Edition")
                            Picker("", selection: $edition) {
                                ForEach(WindowsEdition.allCases, id: \.self) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 200)
                        }
                    }
                    .padding(16)
                }
                if password != passwordRepeat {
                    Text("Die Passwörter stimmen nicht überein.").font(.system(size: 11)).foregroundStyle(Moon.rose)
                }
                Text("Windows wird ohne Produktschlüssel installiert und kann später mit deiner Lizenz aktiviert werden. Sprache: \(WindowsLocale.guess(isoPath: iso?.path)).")
                    .font(.system(size: 11)).foregroundStyle(Moon.textMuted)
            } else {
                Text("Du führst das Windows-Setup selbst durch. Moonvisor überspringt nur die Hardwareprüfungen und erlaubt ein lokales Konto ohne Internet.")
                    .font(.system(size: 12)).foregroundStyle(Moon.textMuted)
            }
        }
    }

    private var resourcesStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Wofür nutzt du die VM?", "Moonvisor schlägt passende Ressourcen für deinen Mac vor (\(hostCPUs) Kerne, \(hostMemoryGB) GB RAM).")
            HStack(spacing: 10) {
                ForEach(ResourceProfile.allCases, id: \.self) { p in
                    MoonCard(selected: profile == p) {
                        VStack(alignment: .leading, spacing: 4) {
                            Image(systemName: icon(for: p)).font(.system(size: 18)).foregroundStyle(Moon.accentLight)
                            Text(p.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Moon.text)
                            Text(p.detail).font(.system(size: 10)).foregroundStyle(Moon.textMuted).lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                        .padding(10)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { profile = p; applyProfile() }
                }
            }
            MoonCard {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        label("Name")
                        TextField("", text: $name).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        label("Prozessoren")
                        HStack {
                            Slider(value: intBinding($cpus), in: 1...Double(hostCPUs), step: 1).tint(Moon.accent)
                            Text("\(cpus)").monospacedDigit().foregroundStyle(Moon.text).frame(width: 60, alignment: .trailing)
                        }
                    }
                    GridRow {
                        label("Arbeitsspeicher")
                        HStack {
                            Slider(value: intBinding($memoryGB), in: 2...Double(max(3, hostMemoryGB - 2)), step: 1).tint(Moon.accent)
                            Text("\(memoryGB) GB").monospacedDigit().foregroundStyle(Moon.text).frame(width: 60, alignment: .trailing)
                        }
                    }
                    GridRow {
                        label("Festplatte")
                        HStack {
                            Slider(value: intBinding($diskGB), in: 32...512, step: 16).tint(Moon.accent)
                            Text("\(diskGB) GB").monospacedDigit().foregroundStyle(Moon.text).frame(width: 60, alignment: .trailing)
                        }
                    }
                }
                .padding(14)
                .onChange(of: cpus) { if !applyingProfile { profile = .custom } }
                .onChange(of: memoryGB) { if !applyingProfile { profile = .custom } }
            }
            Text("Die Festplatte wächst nur mit den tatsächlich belegten Daten.")
                .font(.system(size: 11)).foregroundStyle(Moon.textMuted)
        }
    }

    private var createStep: some View {
        VStack(spacing: 18) {
            Spacer()
            if let failure {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 42)).foregroundStyle(Moon.rose)
                Text("Das hat nicht geklappt").font(.system(size: 18, weight: .semibold)).foregroundStyle(Moon.text)
                Text(failure).font(.system(size: 12)).foregroundStyle(Moon.textMuted).multilineTextAlignment(.center).textSelection(.enabled)
            } else {
                MoonLogo(size: 64)
                Text(progressText.isEmpty ? "Wird vorbereitet …" : progressText)
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(Moon.text)
                if let downloadProgress {
                    ProgressView(value: downloadProgress).tint(Moon.accent).frame(width: 320)
                    Text("\(Int(downloadProgress * 100)) %").font(.system(size: 11)).foregroundStyle(Moon.textMuted)
                } else {
                    ProgressView().controlSize(.small).tint(Moon.accent)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Helfer

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(Moon.text)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Moon.textMuted)
        }
        .padding(.bottom, 4)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Moon.textSecondary).gridColumnAlignment(.trailing)
    }

    private func icon(for p: ResourceProfile) -> String {
        switch p {
        case .productivity: return "doc.text"
        case .development: return "chevron.left.forwardslash.chevron.right"
        case .gaming: return "gamecontroller"
        case .custom: return "slider.horizontal.3"
        }
    }

    private func intBinding(_ value: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) })
    }

    private func applyProfile() {
        guard profile != .custom else { return }
        let s = profile.suggestion(hostCPUs: hostCPUs, hostMemoryMB: Toolchain.hostMemoryMB)
        applyingProfile = true
        cpus = s.cpus
        memoryGB = max(2, s.memoryMB / 1024)
        DispatchQueue.main.async { applyingProfile = false }
    }

    private func pick(types: [String], _ done: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = types.contains("pvm")
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url, types.contains(url.pathExtension.lowercased()) {
            done(url)
        }
    }

    // MARK: Erstellen

    private func create() {
        failure = nil
        working = true
        progressText = "Wird vorbereitet …"
        let source = source, iso = iso, parallelsVM = parallelsVM
        let request = CreateRequest(
            name: name.trimmingCharacters(in: .whitespaces),
            guestOS: source == .windows ? .windows11 : .linux,
            installMedia: iso,
            cpuCount: cpus, memoryMB: memoryGB * 1024, diskSizeGB: diskGB,
            profile: profile,
            installMode: source == .windows ? (express ? .express : .manual) : .none,
            express: express ? ExpressInstallOptions(userName: userName, password: password, computerName: name,
                                                     edition: edition, locale: WindowsLocale.guess(isoPath: iso?.path)) : nil
        )
        Task {
            do {
                let toolchain = try Toolchain.locate(requireTPM: source == .windows)
                if source != .other && DriverStore.cachedVirtioISO == nil {
                    progressText = "Windows-Treiber werden geladen (virtio-win) …"
                    downloadProgress = 0
                    do {
                        _ = try await DriverStore.ensureVirtioISO { value in
                            DispatchQueue.main.async { downloadProgress = value }
                        }
                    } catch {
                        throw MoonError.processFailed("Treiber-Download", DriverStore.describe(error))
                    }
                    downloadProgress = nil
                }
                let bundle: VMBundle = try await Task.detached {
                    if source == .parallels, let parallelsVM {
                        return try ParallelsImporter.importVM(parallelsVM, toolchain: toolchain) { text in
                            DispatchQueue.main.async { progressText = text }
                        }
                    }
                    return try VMFactory.create(request, toolchain: toolchain) { text in
                        DispatchQueue.main.async { progressText = text }
                    }
                }.value
                model.reload()
                working = false
                if let entry = model.entries.first(where: { $0.bundle == bundle }) {
                    if source != .parallels { model.start(entry) }
                    openWindow(id: "vm", value: entry.id)
                }
                dismissWindow(id: "assistant")
            } catch {
                working = false
                downloadProgress = nil
                failure = error.localizedDescription
            }
        }
    }
}
