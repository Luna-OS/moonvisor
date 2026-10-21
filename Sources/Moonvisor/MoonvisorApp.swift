import AppKit
import SwiftUI

@main
struct MoonvisorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = VMLibrary()

    var body: some Scene {
        Window("Moonvisor", id: "library") {
            LibraryView()
                .environmentObject(library)
                .tint(.moonvisor)
                .onAppear { appDelegate.library = library }
        }
        .defaultSize(width: 900, height: 620)

        WindowGroup("Virtual Machine", for: URL.self) { $url in
            VMWindowView(url: url)
                .environmentObject(library)
                .tint(.moonvisor)
        }
        .defaultSize(width: 1280, height: 800)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var library: VMLibrary?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Running machines are suspended (or shut down) before quitting instead of being cut off.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let library, library.hasActiveMachines else { return .terminateNow }
        Task {
            await library.stopAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

extension Color {
    /// Deep moon lavender; readable as a fill behind white text in light and dark mode.
    static let moonvisor = Color(red: 117 / 255.0, green: 89 / 255.0, blue: 201 / 255.0) // #7559C9
}
