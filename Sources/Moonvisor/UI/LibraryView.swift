import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: VMLibrary
    @State private var selection: URL?
    @State private var showingNewMachine = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(library.items) { item in
                    MachineRow(item: item, runner: item.runner)
                        .tag(item.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                ToolbarItem {
                    Button { showingNewMachine = true } label: {
                        Label("New Virtual Machine", systemImage: "plus")
                    }
                    .help("New Virtual Machine")
                }
            }
        } detail: {
            if let selection, let item = library.item(for: selection) {
                MachineDetailView(item: item, runner: item.runner, selection: $selection)
                    .id(item.id)
            } else {
                ContentUnavailableView {
                    Label(library.items.isEmpty ? "No Virtual Machines" : "No Selection", systemImage: "moon.stars")
                } description: {
                    Text(library.items.isEmpty
                         ? "Create a macOS virtual machine to get started."
                         : "Select a virtual machine in the sidebar.")
                } actions: {
                    if library.items.isEmpty {
                        Button("New Virtual Machine…") { showingNewMachine = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .sheet(isPresented: $showingNewMachine) {
            NewMachineSheet { url in selection = library.item(for: url)?.id }
                .environmentObject(library)
        }
        .onAppear {
            if selection == nil { selection = library.items.first?.id }
        }
    }
}

struct MachineRow: View {
    @ObservedObject var item: VirtualMachineItem
    @ObservedObject var runner: VMRunner

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(.tint)
                .overlay(alignment: .bottomTrailing) {
                    if runner.isActive {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.config.name)
                    .lineLimit(1)
                Text(runner.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
