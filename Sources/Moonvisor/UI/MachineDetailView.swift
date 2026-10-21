import AppKit
import SwiftUI

struct MachineDetailView: View {
    @ObservedObject var item: VirtualMachineItem
    @ObservedObject var runner: VMRunner
    @Binding var selection: URL?
    @EnvironmentObject private var library: VMLibrary
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingDelete = false
    @State private var namingSnapshot = false
    @State private var snapshotName = ""
    @State private var actionError: String?

    var body: some View {
        Form {
            Section {
                header
                controls
                if let error = actionError ?? runner.lastError ?? item.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section {
                TextField("Name", text: binding(\.name))
                Stepper(value: binding(\.cpuCount), in: 1...HostLimits.maxCPU) {
                    LabeledContent("Processors", value: "\(item.config.cpuCount)")
                }
                Stepper(value: binding(\.memoryGB), in: HostLimits.minMemoryGB...HostLimits.maxMemoryGB) {
                    LabeledContent("Memory", value: "\(item.config.memoryGB) GB")
                }
                Picker("Display", selection: binding(\.display)) {
                    ForEach(DisplayPreset.all) { preset in
                        Text(preset.name).tag(preset.size)
                    }
                }
                LabeledContent("Disk", value: "\(item.config.diskGB) GB")
                LabeledContent("Network", value: "Shared (NAT)")
            } header: {
                Text("Hardware")
            } footer: {
                if !item.isEditable {
                    Text(runner.isSuspended
                         ? "The machine is suspended. Resume and shut it down, or discard the saved state, to change its hardware."
                         : "Shut down the machine to change its hardware.")
                }
            }
            .disabled(!item.isEditable)

            sharedFolders
            snapshots

            Section {
                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.bundle.url])
                    }
                    Button("Duplicate") {
                        perform {
                            let url = try library.clone(item)
                            selection = library.item(for: url)?.id
                        }
                    }
                    .disabled(runner.isActive)
                    Spacer()
                    Button("Move to Trash…", role: .destructive) { confirmingDelete = true }
                        .disabled(runner.isActive)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(item.config.name)
        .confirmationDialog("Move “\(item.config.name)” to the Trash?", isPresented: $confirmingDelete) {
            Button("Move to Trash", role: .destructive) {
                perform {
                    try library.delete(item)
                    selection = library.items.first?.id
                }
            }
        } message: {
            Text("The virtual machine, its disk and all its snapshots are moved to the Trash.")
        }
        .alert("Take Snapshot", isPresented: $namingSnapshot) {
            TextField("Name", text: $snapshotName)
            Button("Take Snapshot") { item.takeSnapshot(named: snapshotName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current disk so you can return to it later.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.config.name)
                    .font(.title2.weight(.semibold))
                Text(["macOS " + (item.config.osVersion ?? ""), runner.statusText].joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var controls: some View {
        HStack {
            if runner.isActive {
                Button {
                    openWindow(value: item.id)
                } label: {
                    Label("Show Window", systemImage: "macwindow")
                }
                .buttonStyle(.borderedProminent)
                if runner.state == .paused {
                    Button { runner.resume() } label: { Label("Resume", systemImage: "play.fill") }
                } else {
                    Button { runner.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                        .disabled(runner.state != .running)
                }
                if runner.canSuspend {
                    Button { Task { await runner.suspend() } } label: { Label("Suspend", systemImage: "moon.zzz.fill") }
                        .disabled(runner.state != .running && runner.state != .paused)
                }
                Menu {
                    Button("Shut Down") { runner.shutDown() }
                    Button("Force Stop") { Task { await runner.forceStop() } }
                } label: {
                    Label("Shut Down", systemImage: "power")
                } primaryAction: {
                    runner.shutDown()
                }
                .fixedSize()
            } else {
                Button {
                    item.start()
                    openWindow(value: item.id)
                } label: {
                    Label(runner.isSuspended ? "Resume" : "Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                if runner.isSuspended {
                    Button("Discard Saved State") { runner.discardSavedState() }
                }
            }
        }
    }

    private var sharedFolders: some View {
        Section {
            ForEach(item.config.sharedFolders) { folder in
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text(folder.url.lastPathComponent)
                        Text(folder.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Toggle("Read-only", isOn: Binding(
                        get: { folder.readOnly },
                        set: { readOnly in
                            item.update { config in
                                if let index = config.sharedFolders.firstIndex(where: { $0.id == folder.id }) {
                                    config.sharedFolders[index].readOnly = readOnly
                                }
                            }
                        }))
                        .toggleStyle(.checkbox)
                    Button {
                        item.update { config in config.sharedFolders.removeAll { $0.id == folder.id } }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Stop sharing")
                }
            }
            Button("Share Folder…", action: chooseSharedFolders)
        } header: {
            Text("Shared Folders")
        } footer: {
            Text("Shared folders appear in the guest under /Volumes/My Shared Files.")
        }
        .disabled(!item.isEditable)
    }

    private var snapshots: some View {
        Section {
            ForEach(item.snapshots.reversed()) { snapshot in
                HStack {
                    Image(systemName: snapshot.includesSavedState ? "moon.zzz" : "camera")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading) {
                        Text(snapshot.name)
                        Text(snapshot.created.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore") { item.restore(snapshot) }
                        .disabled(runner.isActive)
                    Button {
                        item.delete(snapshot)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete Snapshot")
                }
            }
            Button("Take Snapshot…") {
                snapshotName = "Snapshot \(item.snapshots.count + 1)"
                namingSnapshot = true
            }
            .disabled(runner.isActive)
        } header: {
            Text("Snapshots")
        } footer: {
            Text("Snapshots can be taken while the machine is shut down or suspended. Restoring replaces the current disk.")
        }
    }

    private func chooseSharedFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Share"
        guard panel.runModal() == .OK else { return }
        item.update { config in
            let known = Set(config.sharedFolders.map(\.path))
            config.sharedFolders += panel.urls
                .map(\.path)
                .filter { !known.contains($0) }
                .map { SharedFolder(path: $0) }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<VMConfig, Value>) -> Binding<Value> {
        Binding(
            get: { item.config[keyPath: keyPath] },
            set: { value in item.update { config in config[keyPath: keyPath] = value } })
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }
}
