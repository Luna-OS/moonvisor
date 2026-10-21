import AppKit
import MoonvisorCore
import SwiftUI

/// `Moonvisor --render-previews <ordner>` zeichnet die Hauptansichten als PNG (für README und Tests)
/// und holt über den eingebauten VNC-Client ein Bild einer laufenden VM.
@MainActor
enum PreviewRenderer {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--render-previews"), index + 1 < args.count else { return }
        let folder = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel()
        for entry in model.entries {
            entry.state = VMRunner.state(of: entry.bundle)
            if entry.state == .running { try? VMRunner.captureThumbnail(entry.bundle) }
            entry.loadThumbnail()
        }

        func render<V: View>(_ view: V, _ name: String, size: CGSize) {
            let content = view
                .environment(model)
                .environment(\.colorScheme, .dark)
                .environment(\.isPreviewRendering, true)
                .frame(width: size.width, height: size.height)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent("\(name).png"))
                print("✓ \(name).png")
            } else {
                print("✗ \(name)")
            }
        }

        render(ControlCenterView(), "control-center", size: CGSize(width: 520, height: 420))
        render(AssistantView(), "assistant", size: CGSize(width: 720, height: 560))
        if let entry = model.entries.first {
            render(ConfigurationView(entry: entry, draft: entry.config), "configuration", size: CGSize(width: 720, height: 520))
        }

        // VNC-Ende-zu-Ende-Test gegen eine laufende VM.
        let running = model.entries.compactMap { entry in VMRunner.runtime(of: entry.bundle).map { (entry, $0) } }.first
        guard let (entry, info) = running else {
            print("Keine laufende VM für den Bildschirmtest.")
            exit(0)
        }
        let client = VNCClient(path: info.sockets.vnc)
        var frames = 0
        client.onFrame = { image in
            frames += 1
            if frames == 2 {
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("vm-display.png"))
                print("✓ vm-display.png (\(image.width)×\(image.height), Scancodes: \(client.canSendScancodes ? "ja" : "nein"), VM: \(entry.config.name))")
                client.stop()
                exit(0)
            }
        }
        client.onDisconnect = { error in
            print("✗ VNC: \(error?.localizedDescription ?? "getrennt")")
            exit(1)
        }
        client.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            print("✗ VNC: kein Bild nach 20 s")
            exit(1)
        }
    }
}
