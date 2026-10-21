import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Zeigt den Bildschirm der VM und leitet Tastatur und Maus an den Gast weiter.
final class VMDisplayNSView: NSView {
    var client: VNCClient? {
        didSet { releaseAllKeys(oldClient: oldValue) }
    }
    var commandAsControl = false
    private var pressed: Set<UInt32> = []
    private var buttons: UInt8 = 0
    private var scrollAccumulator = CGPoint.zero
    private var trackingArea: NSTrackingArea?
    private static let invisibleCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: image, hotSpot: .zero)
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func show(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        // Der Gast zeichnet seinen eigenen Mauszeiger; der Mac-Zeiger wird im Bildschirm ausgeblendet.
        addCursorRect(imageRect(), cursor: Self.invisibleCursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        if imageRect().contains(convert(event.locationInWindow, from: nil)) {
            Self.invisibleCursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    /// Bereich, in dem das Gastbild (seitenverhältnistreu) dargestellt wird.
    private func imageRect() -> CGRect {
        guard let client, client.width > 0, client.height > 0 else { return bounds }
        let scale = min(bounds.width / CGFloat(client.width), bounds.height / CGFloat(client.height))
        let w = CGFloat(client.width) * scale, h = CGFloat(client.height) * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func guestPoint(_ event: NSEvent) -> (Int, Int) {
        guard let client else { return (0, 0) }
        let p = convert(event.locationInWindow, from: nil)
        let r = imageRect()
        let x = (p.x - r.minX) / r.width * CGFloat(client.width)
        let y = (p.y - r.minY) / r.height * CGFloat(client.height)
        return (Int(x), Int(y))
    }

    private func sendPointer(_ event: NSEvent) {
        let (x, y) = guestPoint(event)
        client?.sendPointer(x: x, y: y, buttons: buttons)
    }

    // MARK: Maus

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        buttons |= event.modifierFlags.contains(.control) ? 4 : 1
        sendPointer(event)
    }

    override func mouseUp(with event: NSEvent) {
        buttons &= ~UInt8(5)
        sendPointer(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        buttons |= 4
        sendPointer(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        buttons &= ~UInt8(4)
        sendPointer(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        buttons |= 2
        sendPointer(event)
    }

    override func otherMouseUp(with event: NSEvent) {
        buttons &= ~UInt8(2)
        sendPointer(event)
    }

    override func mouseMoved(with event: NSEvent) { sendPointer(event) }
    override func mouseDragged(with event: NSEvent) { sendPointer(event) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(event) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event) }

    override func scrollWheel(with event: NSEvent) {
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 14 : 1
        scrollAccumulator.x += event.scrollingDeltaX
        scrollAccumulator.y += event.scrollingDeltaY
        let (x, y) = guestPoint(event)
        while abs(scrollAccumulator.y) >= step {
            let up = scrollAccumulator.y > 0
            let bit: UInt8 = up ? 8 : 16
            client?.sendPointer(x: x, y: y, buttons: buttons | bit)
            client?.sendPointer(x: x, y: y, buttons: buttons)
            scrollAccumulator.y += up ? -step : step
        }
        while abs(scrollAccumulator.x) >= step {
            let left = scrollAccumulator.x > 0
            let bit: UInt8 = left ? 32 : 64
            client?.sendPointer(x: x, y: y, buttons: buttons | bit)
            client?.sendPointer(x: x, y: y, buttons: buttons)
            scrollAccumulator.x += left ? -step : step
        }
        if event.phase == .ended || event.momentumPhase == .ended { scrollAccumulator = .zero }
    }

    // MARK: Tastatur

    private func key(_ code: UInt32, down: Bool) {
        if down { pressed.insert(code) } else { pressed.remove(code) }
        client?.sendKey(scancode: code, down: down)
    }

    override func keyDown(with event: NSEvent) {
        guard let code = KeyMap.scancode(for: event.keyCode, commandAsControl: commandAsControl) else { return }
        key(code, down: true)
        // Solange ⌘ gedrückt ist, schickt macOS kein keyUp – daher direkt loslassen.
        if event.modifierFlags.contains(.command) { key(code, down: false) }
    }

    override func keyUp(with event: NSEvent) {
        guard let code = KeyMap.scancode(for: event.keyCode, commandAsControl: commandAsControl) else { return }
        key(code, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let code = KeyMap.scancode(for: event.keyCode, commandAsControl: commandAsControl) else { return }
        if Int(event.keyCode) == kVK_CapsLock {
            key(code, down: true)
            key(code, down: false)
            return
        }
        if let down = KeyMap.modifierIsDown(keyCode: event.keyCode, rawFlags: event.modifierFlags.rawValue) {
            key(code, down: down)
        }
    }

    /// Tastenkürzel gehen an den Gast, außer ⌘Q und ⌃⌘F (Vollbild), die Moonvisor selbst behandelt.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased()
        if flags == .command && chars == "q" { return false }
        if flags == [.command, .control] && chars == "f" { return false }
        keyDown(with: event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        releaseAllKeys(oldClient: client)
        return super.resignFirstResponder()
    }

    private func releaseAllKeys(oldClient: VNCClient?) {
        for code in pressed { oldClient?.sendKey(scancode: code, down: false) }
        pressed.removeAll()
        buttons = 0
    }
}

struct VMDisplayView: NSViewRepresentable {
    let session: DisplaySession
    var commandAsControl: Bool

    func makeNSView(context: Context) -> VMDisplayNSView {
        let view = VMDisplayNSView()
        session.attach(view)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: VMDisplayNSView, context: Context) {
        view.commandAsControl = commandAsControl
        if session.view !== view { session.attach(view) }
    }
}

/// Verbindet einen Bildschirm-View mit der VNC-Sitzung einer laufenden VM.
@Observable
final class DisplaySession {
    private(set) var connected = false
    private(set) var resolution: CGSize = .zero
    var lastError: String?
    @ObservationIgnored weak var view: VMDisplayNSView?
    @ObservationIgnored private var client: VNCClient?
    @ObservationIgnored private var lastImage: CGImage?

    func attach(_ view: VMDisplayNSView) {
        self.view = view
        view.client = client
        if let lastImage { view.show(lastImage) }
    }

    func connect(socketPath: String) {
        disconnect()
        let client = VNCClient(path: socketPath)
        client.onFrame = { [weak self, weak client] image in
            guard let self else { return }
            self.connected = true
            self.lastImage = image
            if let client, self.resolution != CGSize(width: client.width, height: client.height) {
                self.resolution = CGSize(width: client.width, height: client.height)
                self.view?.window?.invalidateCursorRects(for: self.view!)
            }
            self.view?.show(image)
        }
        client.onDisconnect = { [weak self] error in
            self?.connected = false
            if let error { self?.lastError = error.localizedDescription }
        }
        self.client = client
        view?.client = client
        client.start()
    }

    func disconnect() {
        client?.stop()
        client = nil
        view?.client = nil
        connected = false
    }

    var snapshotImage: CGImage? { lastImage }
}
