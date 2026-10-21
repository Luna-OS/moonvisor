import AppKit
import MoonvisorCore
import SwiftUI

/// `Moonvisor --render-previews <ordner>` zeichnet die Hauptansichten als PNG (für README und Tests)
/// und holt über den eingebauten VNC-Client ein Bild einer laufenden VM.
@MainActor
enum PreviewRenderer {
    /// `Moonvisor --vnc-input-test <datei.png>`: drückt über den eingebauten VNC-Client die Windows-Taste,
    /// tippt „notepad“ + Enter und speichert danach ein Bildschirmfoto. Prüft den kompletten Eingabeweg.
    static func runInputTestIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--vnc-input-test"), index + 1 < args.count else { return }
        let output = URL(fileURLWithPath: args[index + 1])
        guard let bundle = VMLibrary.list().first(where: { VMRunner.runtime(of: $0) != nil }),
              let info = VMRunner.runtime(of: bundle) else {
            print("✗ keine laufende VM")
            exit(1)
        }
        let client = VNCClient(path: info.sockets.vnc)
        var started = false
        client.onFrame = { _ in
            guard !started else { return }
            started = true
            let letters: [Character: UInt32] = ["n": 0x31, "o": 0x18, "t": 0x14, "e": 0x12, "p": 0x19, "a": 0x1E, "d": 0x20]
            DispatchQueue.global().async {
                client.sendPointer(x: client.width / 2, y: client.height / 2, buttons: 0)
                client.sendKey(scancode: KeyMap.windowsKey, down: true)
                usleep(80_000)
                client.sendKey(scancode: KeyMap.windowsKey, down: false)
                usleep(2_500_000)
                for ch in "notepad" {
                    client.sendKey(scancode: letters[ch]!, down: true)
                    usleep(40_000)
                    client.sendKey(scancode: letters[ch]!, down: false)
                    usleep(60_000)
                }
                usleep(2_000_000)
                client.sendKey(scancode: 0x1C, down: true)
                usleep(50_000)
                client.sendKey(scancode: 0x1C, down: false)
                usleep(5_000_000)
                for ch in "notepad" {
                    client.sendKey(scancode: letters[ch]!, down: true)
                    usleep(40_000)
                    client.sendKey(scancode: letters[ch]!, down: false)
                    usleep(60_000)
                }
                usleep(1_500_000)
                do {
                    try VMRunner.withQMP(bundle) { try $0.screendump(to: output) }
                    print("✓ Eingabetest: \(output.path) (Scancodes: \(client.canSendScancodes ? "ja" : "nein"))")
                    exit(0)
                } catch {
                    print("✗ \(error.localizedDescription)")
                    exit(1)
                }
            }
        }
        client.onDisconnect = { error in
            print("✗ VNC: \(error?.localizedDescription ?? "getrennt")")
            exit(1)
        }
        client.start()
    }

    /// `Moonvisor --vnc-resize-test <breite>x<höhe>`: fordert eine neue Gastauflösung an und meldet,
    /// welche Auflösung der Gast danach liefert.
    static func runResizeTestIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--vnc-resize-test"), index + 1 < args.count else { return }
        let parts = args[index + 1].split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2,
              let bundle = VMLibrary.list().first(where: { VMRunner.runtime(of: $0) != nil }),
              let info = VMRunner.runtime(of: bundle) else {
            print("✗ Aufruf: --vnc-resize-test 1600x1000 (mit laufender VM)")
            exit(1)
        }
        let client = VNCClient(path: info.sockets.vnc)
        var requested = false
        client.onFrame = { image in
            if !requested {
                requested = true
                print("Vorher: \(image.width)×\(image.height), Größenänderung unterstützt: \(client.supportsDesktopResize)")
                client.requestDesktopSize(width: parts[0], height: parts[1])
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    print("Nachher: \(client.width)×\(client.height)")
                    print(client.width == parts[0] & ~7 && client.height == parts[1] ? "✓ Auflösung angepasst" : "✗ Auflösung unverändert")
                    exit(0)
                }
            }
        }
        client.onDisconnect = { error in
            print("✗ VNC: \(error?.localizedDescription ?? "getrennt")")
            exit(1)
        }
        client.start()
    }

    static func runIfRequested() {
        runInputTestIfRequested()
        runResizeTestIfRequested()
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
