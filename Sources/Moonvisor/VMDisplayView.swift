import MoonvisorCore
import AppKit
import Carbon.HIToolbox
import IOSurface
import SwiftUI

/// Zeigt den Bildschirm der VM und leitet Tastatur und Maus an den Gast weiter.
final class VMDisplayNSView: NSView {
    var client: DisplayClient? {
        didSet { releaseAllKeys(oldClient: oldValue) }
    }
    /// Mauszeiger des Gasts (SPICE). Bei VNC zeichnet der Gast ihn selbst ins Bild.
    var guestCursor: NSCursor? {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    private var usesGuestCursor = false
    var commandAsControl = false
    /// Gastauflösung an die Fenstergröße anpassen (nur mit virtio-GPU möglich).
    var autoResize = false
    /// Wird mit der gewünschten Gastauflösung aufgerufen (Moonvisor Tools im Gast).
    var onResizeRequest: ((Int, Int) -> Void)?
    /// Dateien, die auf den Bildschirm gezogen wurden (gehen über die Moonvisor Tools in den Gast).
    var onDropFiles: (([URL]) -> Void)?
    private var resizeWork: DispatchWorkItem?
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
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func show(_ image: CGImage) {
        usesGuestCursor = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }

    /// Bildfläche aus dem DirectX-Modus. Core Animation zeigt die IOSurface direkt an.
    func show(surface: IOSurfaceRef) {
        if !usesGuestCursor {
            usesGuestCursor = true
            window?.invalidateCursorRects(for: self)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = surface
        CATransaction.commit()
    }

    /// Inhalt der IOSurface hat sich geändert: neu zusammensetzen lassen.
    func refreshSurface() {
        guard let surface = layer?.contents else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = nil
        layer?.contents = surface
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    /// Bei VNC zeichnet der Gast seinen Mauszeiger selbst; bei SPICE kommt er als eigenes Bild.
    private var cursorInImage: NSCursor {
        usesGuestCursor ? (guestCursor ?? Self.invisibleCursor) : Self.invisibleCursor
    }

    override func resetCursorRects() {
        addCursorRect(imageRect(), cursor: cursorInImage)
    }

    override func cursorUpdate(with event: NSEvent) {
        if imageRect().contains(convert(event.locationInWindow, from: nil)) {
            cursorInImage.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
        scheduleGuestResize()
    }

    func scheduleGuestResize() {
        guard autoResize else { return }
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let w = Int(self.bounds.width), h = Int(self.bounds.height)
            self.client?.requestDesktopSize(width: w, height: h)
            self.onResizeRequest?(w, h)
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
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

    // MARK: Drag & Drop

    private func droppedFiles(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDropFiles != nil && !droppedFiles(sender).isEmpty ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedFiles(sender)
        guard let onDropFiles, !urls.isEmpty else { return false }
        onDropFiles(urls)
        return true
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

    private func releaseAllKeys(oldClient: DisplayClient?) {
        for code in pressed { oldClient?.sendKey(scancode: code, down: false) }
        pressed.removeAll()
        buttons = 0
    }
}

struct VMDisplayView: NSViewRepresentable {
    let session: DisplaySession
    var commandAsControl: Bool
    var autoResize: Bool
    /// Nil, solange die Moonvisor Tools nicht verbunden sind.
    var onDropFiles: (([URL]) -> Void)?

    func makeNSView(context: Context) -> VMDisplayNSView {
        let view = VMDisplayNSView()
        view.onResizeRequest = { [weak session] w, h in session?.agent?.requestResolution(width: w, height: h) }
        session.attach(view)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: VMDisplayNSView, context: Context) {
        view.commandAsControl = commandAsControl
        view.onDropFiles = onDropFiles
        if view.autoResize != autoResize {
            view.autoResize = autoResize
            view.scheduleGuestResize()
        }
        if session.view !== view { session.attach(view) }
    }
}

/// Verbindet einen Bildschirm-View mit der Sitzung einer laufenden VM (VNC, im DirectX-Modus SPICE).
@Observable
final class DisplaySession {
    private(set) var connected = false
    /// QEMU zeigt nur sein Ersatzbild („Guest has not initialized the display“): Moonvisor deckt es mit der
    /// Startanzeige ab, bis Firmware oder Windows ein Bild ausgeben.
    private(set) var waitingForGuest = false
    /// In dieser Sitzung kam schon ein echtes Bild (danach heißt das Ersatzbild nicht mehr „startet“).
    private(set) var hasShownGuest = false
    private(set) var resolution: CGSize = .zero
    var lastError: String?
    /// Die Verbindung zum Bildschirm ist beendet, obwohl niemand `disconnect()` aufgerufen hat. Läuft die VM noch,
    /// verbindet das AppModel neu.
    @ObservationIgnored private(set) var finished = false
    @ObservationIgnored weak var view: VMDisplayNSView?
    @ObservationIgnored var agent: AgentChannel?
    @ObservationIgnored private var client: DisplayClient?
    @ObservationIgnored private var lastImage: CGImage?
    @ObservationIgnored private var lastSurface: IOSurfaceRef?
    @ObservationIgnored private var guestCursor: NSCursor?
    /// Nach einem neuen Scanout erst beim nächsten Zeichnen prüfen: QEMU füllt die IOSurface erst danach.
    @ObservationIgnored private var checkSurface = false

    func attach(_ view: VMDisplayNSView) {
        self.view = view
        view.client = client
        view.guestCursor = guestCursor
        if let lastSurface {
            view.show(surface: lastSurface)
        } else if let lastImage {
            view.show(lastImage)
        }
    }

    func connect(socketPath: String) {
        disconnect()
        let client = VNCClient(path: socketPath)
        client.onFrame = { [weak self, weak client] image in
            // Meldungen eines abgelösten Clients ignorieren.
            guard let self, let client, self.client === client else { return }
            self.receivedFrame()
            self.setWaiting(client.lastFrameIsPlaceholder)
            self.lastImage = image
            self.updateResolution(width: client.width, height: client.height)
            self.view?.show(image)
        }
        client.onDisconnect = { [weak self, weak client] error in
            guard let self, let client, self.client === client else { return }
            self.lost(error)
        }
        self.client = client
        view?.client = client
        client.start()
    }

    /// DirectX-Modus: Bild als IOSurface über SPICE.
    func connect(spicePath: String, logURL: URL? = nil) {
        disconnect()
        let client = SpiceClient(path: spicePath)
        if let logURL {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let handle = try? FileHandle(forWritingTo: logURL)
            let queue = DispatchQueue(label: "moonvisor.spice.log")
            client.log = { line in
                queue.async {
                    let stamp = ISO8601DateFormatter().string(from: Date())
                    try? handle?.write(contentsOf: Data("\(stamp) \(line)\n".utf8))
                }
            }
        }
        client.onScanout = { [weak self, weak client] surface in
            guard let self, let client, self.client === client else { return }
            self.receivedFrame()
            self.lastSurface = surface
            self.checkSurface = true
            self.updateResolution(width: client.width, height: client.height)
            self.view?.show(surface: surface)
        }
        client.onDraw = { [weak self, weak client] in
            guard let self, let client, self.client === client else { return }
            // Nur nach einem Scanout und solange das Ersatzbild zu sehen ist prüfen: Mit DirectX kommen sonst bis zu
            // 60 Bilder pro Sekunde.
            if self.checkSurface || self.waitingForGuest, let surface = self.lastSurface {
                self.checkSurface = false
                self.setWaiting(DisplayPlaceholder.matches(surface: surface, width: client.width, height: client.height))
            }
            self.view?.refreshSurface()
        }
        client.onCursor = { [weak self] cursor in
            self?.guestCursor = cursor
            self?.view?.guestCursor = cursor
        }
        client.onDisconnect = { [weak self, weak client] error in
            guard let self, let client, self.client === client else { return }
            self.lost(error)
        }
        self.client = client
        view?.client = client
        client.start()
    }

    private func receivedFrame() {
        if !connected { connected = true }
        if lastError != nil { lastError = nil }
    }

    private func lost(_ error: Error?) {
        connected = false
        finished = true
        if let error { lastError = error.localizedDescription }
    }

    /// Nur bei Änderung setzen: Jede Zuweisung würde die Fensteransicht neu aufbauen, und Bilder kommen laufend.
    private func setWaiting(_ waiting: Bool) {
        if waitingForGuest != waiting { waitingForGuest = waiting }
        if !waiting && !hasShownGuest { hasShownGuest = true }
    }

    private func updateResolution(width: Int, height: Int) {
        let size = CGSize(width: width, height: height)
        guard resolution != size else { return }
        resolution = size
        if let view { view.window?.invalidateCursorRects(for: view) }
    }

    func disconnect() {
        client?.stop()
        client = nil
        view?.client = nil
        lastSurface = nil
        guestCursor = nil
        view?.guestCursor = nil
        connected = false
        finished = false
        checkSurface = false
        waitingForGuest = false
        hasShownGuest = false
    }

    var snapshotImage: CGImage? { lastImage }

    /// Nach dem Verbinden der Tools die aktuelle Fenstergröße anfragen.
    func requestCurrentSize() {
        view?.scheduleGuestResize()
    }
}

extension DisplayPlaceholder {
    /// Prüft die IOSurface aus dem DirectX-Modus (SPICE mit OpenGL).
    static func matches(surface: IOSurfaceRef, width: Int, height: Int) -> Bool {
        guard IOSurfaceGetBytesPerElement(surface) == 4,
              IOSurfaceLock(surface, .readOnly, nil) == KERN_SUCCESS else { return false }
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let w = min(width, IOSurfaceGetWidth(surface)), h = min(height, IOSurfaceGetHeight(surface))
        return matches(IOSurfaceGetBaseAddress(surface), width: w, height: h, bytesPerRow: IOSurfaceGetBytesPerRow(surface))
    }
}
