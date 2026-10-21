// Zeichnet das Moonvisor-App-Icon (Mondsichel über einem VM-Bildschirm, Moon-Farben)
// und schreibt ein .iconset. Aufruf: swift scripts/make-icon.swift <ausgabe.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // macOS-Icon-Raster: 824/1024 große, abgerundete Fläche.
    let inset = s * 100 / 1024
    let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0x000000, 0.45))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x10121C))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let sky = CGGradient(colorsSpace: nil, colors: [color(0x2F2380), color(0x130F28), color(0x0E0B1F)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: [])

    // Sterne
    var seed: UInt64 = 42
    func rnd() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
    }
    for _ in 0..<38 {
        let r = s * (0.002 + rnd() * 0.005)
        let p = CGPoint(x: tile.minX + rnd() * tile.width, y: tile.minY + tile.height * 0.35 + rnd() * tile.height * 0.65)
        ctx.setFillColor(color(0xE2DCFF, 0.25 + rnd() * 0.6))
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }

    // Bildschirm (die VM)
    let screen = CGRect(x: tile.minX + tile.width * 0.17, y: tile.minY + tile.height * 0.16, width: tile.width * 0.66, height: tile.height * 0.44)
    let screenPath = CGPath(roundedRect: screen, cornerWidth: s * 0.035, cornerHeight: s * 0.035, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.05, color: color(0x8E7CFF, 0.55))
    ctx.addPath(screenPath)
    ctx.setFillColor(color(0x1A1535))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(screenPath)
    ctx.setStrokeColor(color(0xB8ABFF))
    ctx.setLineWidth(s * 0.014)
    ctx.strokePath()
    // Fensterinhalt: Titelleiste mit drei Punkten und Textzeilen
    let bar = CGRect(x: screen.minX, y: screen.maxY - screen.height * 0.2, width: screen.width, height: screen.height * 0.2)
    ctx.saveGState()
    ctx.addPath(screenPath)
    ctx.clip()
    ctx.setFillColor(color(0x3A3168))
    ctx.fill(bar)
    ctx.restoreGState()
    for (i, c) in [0xFF8FB1, 0xF5D78E, 0x8EE3C0].enumerated() {
        let r = bar.height * 0.18
        let cx = bar.minX + bar.height * 0.5 + CGFloat(i) * r * 3.2
        ctx.setFillColor(color(UInt32(c)))
        ctx.fillEllipse(in: CGRect(x: cx - r, y: bar.midY - r, width: r * 2, height: r * 2))
    }
    for (i, frac) in [0.62, 0.78, 0.48].enumerated() {
        let lh = screen.height * 0.075
        let line = CGRect(x: screen.minX + screen.width * 0.1, y: bar.minY - screen.height * 0.17 - CGFloat(i) * lh * 2.1,
                          width: screen.width * 0.8 * frac, height: lh)
        ctx.addPath(CGPath(roundedRect: line, cornerWidth: lh / 2, cornerHeight: lh / 2, transform: nil))
        ctx.setFillColor(color(i == 0 ? 0x8E7CFF : 0x6A57E0, i == 0 ? 1 : 0.8))
        ctx.fillPath()
    }

    // Mondsichel
    let moonR = tile.width * 0.17
    let moonC = CGPoint(x: tile.minX + tile.width * 0.68, y: tile.minY + tile.height * 0.77)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.06, color: color(0xB8ABFF, 0.8))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    let moonGradient = CGGradient(colorsSpace: nil, colors: [color(0xEEEAFF), color(0xB8ABFF)] as CFArray, locations: [0, 1])!
    ctx.addEllipse(in: CGRect(x: moonC.x - moonR, y: moonC.y - moonR, width: moonR * 2, height: moonR * 2))
    ctx.clip()
    ctx.drawLinearGradient(moonGradient, start: CGPoint(x: moonC.x - moonR, y: moonC.y + moonR), end: CGPoint(x: moonC.x + moonR, y: moonC.y - moonR), options: [])
    ctx.setBlendMode(.clear)
    let cut = moonR * 0.86
    ctx.fillEllipse(in: CGRect(x: moonC.x - moonR * 0.38 - cut, y: moonC.y + moonR * 0.28 - cut, width: cut * 2, height: cut * 2))
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    ctx.restoreGState()
    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                     ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(size).write(to: output.appendingPathComponent("icon_\(name).png"))
}
try! render(1024).write(to: output.deletingLastPathComponent().appendingPathComponent("icon-preview.png"))
print("Icon geschrieben: \(output.path)")
