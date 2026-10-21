import SwiftUI
import UniformTypeIdentifiers
import Virtualization

struct NewMachineSheet: View {
    var onCreated: (URL) -> Void
    @EnvironmentObject private var library: VMLibrary
    @Environment(\.dismiss) private var dismiss
    @StateObject private var installer = VMInstaller()
    @State private var config = VMConfig.makeDefault(name: "macOS")
    @State private var source = Source.latest
    @State private var restoreImage: URL?
    @State private var choosingImage = false

    enum Source: Hashable {
        case latest, file
    }

    private var canCreate: Bool {
        VZVirtualMachine.isSupported
            && !installer.isBusy
            && !config.name.trimmingCharacters(in: .whitespaces).isEmpty
            && (source == .latest || restoreImage != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $config.name)
                }
                Section("Installer") {
                    Picker("Source", selection: $source) {
                        Text("Download the latest macOS from Apple").tag(Source.latest)
                        Text("Use a restore image (.ipsw)").tag(Source.file)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    if source == .file {
                        HStack {
                            Text(restoreImage?.lastPathComponent ?? "No file chosen")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Choose…") { choosingImage = true }
                        }
                    }
                }
                Section("Hardware") {
                    Stepper(value: $config.cpuCount, in: 1...HostLimits.maxCPU) {
                        LabeledContent("Processors", value: "\(config.cpuCount)")
                    }
                    Stepper(value: $config.memoryGB, in: HostLimits.minMemoryGB...HostLimits.maxMemoryGB) {
                        LabeledContent("Memory", value: "\(config.memoryGB) GB")
                    }
                    Stepper(value: $config.diskGB, in: 32...2048, step: 16) {
                        LabeledContent("Disk", value: "\(config.diskGB) GB")
                    }
                    Picker("Display", selection: $config.display) {
                        ForEach(DisplayPreset.all) { preset in
                            Text(preset.name).tag(preset.size)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(installer.isBusy)

            status
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            Divider()
            HStack {
                if !VZVirtualMachine.isSupported {
                    Text(MoonvisorError.unsupportedHost.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    installer.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    installer.install(config: config, restoreImage: source == .file ? restoreImage : nil, library: library)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
            .padding(16)
        }
        .frame(width: 520)
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [UTType(filenameExtension: "ipsw") ?? .data]) { result in
            if case .success(let url) = result { restoreImage = url }
        }
        .onChange(of: installer.phase) { _, phase in
            if case .finished(let url) = phase {
                onCreated(url)
                dismiss()
            }
        }
        .interactiveDismissDisabled(installer.isBusy)
    }

    @ViewBuilder
    private var status: some View {
        switch installer.phase {
        case .idle, .finished:
            EmptyView()
        case .fetchingCatalog:
            ProgressView("Asking Apple for the latest macOS…")
                .frame(maxWidth: .infinity, alignment: .leading)
        case .downloading(let fraction):
            ProgressView(value: fraction) {
                Text("Downloading macOS… \(fraction.formatted(.percent.precision(.fractionLength(0))))")
            }
        case .loadingImage:
            ProgressView("Checking the restore image…")
                .frame(maxWidth: .infinity, alignment: .leading)
        case .installing(let fraction):
            ProgressView(value: fraction) {
                Text("Installing macOS… \(fraction.formatted(.percent.precision(.fractionLength(0))))")
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}
