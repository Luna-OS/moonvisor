import SwiftUI
import Virtualization

struct VMWindowView: View {
    let url: URL?
    @EnvironmentObject private var library: VMLibrary

    var body: some View {
        if let url, let item = library.item(for: url) {
            MachineScreen(item: item, runner: item.runner)
        } else {
            ContentUnavailableView("Virtual Machine Not Found", systemImage: "questionmark.square.dashed")
                .frame(minWidth: 480, minHeight: 320)
        }
    }
}

struct MachineScreen: View {
    @ObservedObject var item: VirtualMachineItem
    @ObservedObject var runner: VMRunner

    var body: some View {
        Group {
            if let machine = runner.machine {
                MachineDisplay(machine: machine)
            } else {
                ContentUnavailableView {
                    Label(item.config.name, systemImage: runner.isSuspended ? "moon.zzz" : "moon")
                } description: {
                    Text(runner.lastError ?? runner.statusText)
                } actions: {
                    if !runner.isActive {
                        Button(runner.isSuspended ? "Resume" : "Start") { item.start() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .navigationTitle(item.config.name)
        .navigationSubtitle(runner.statusText)
        .toolbar {
            ToolbarItemGroup {
                if runner.machine != nil {
                    if runner.state == .paused {
                        Button { runner.resume() } label: { Label("Resume", systemImage: "play.fill") }
                            .help("Resume")
                    } else {
                        Button { runner.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                            .help("Pause")
                            .disabled(runner.state != .running)
                    }
                    if runner.canSuspend {
                        Button { Task { await runner.suspend() } } label: { Label("Suspend", systemImage: "moon.zzz.fill") }
                            .help("Suspend")
                    }
                    Button { runner.shutDown() } label: { Label("Shut Down", systemImage: "power") }
                        .help("Shut Down")
                }
            }
        }
    }
}

/// Shows the guest's screen and forwards keyboard, mouse and trackpad input.
struct MachineDisplay: NSViewRepresentable {
    let machine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.capturesSystemKeys = true
        // Resizing the window resizes the guest's display.
        view.automaticallyReconfiguresDisplay = true
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== machine {
            view.virtualMachine = machine
        }
    }
}
