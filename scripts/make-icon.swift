// Renders the 1024 px app icon: a crescent moon over a night sky.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// macOS icon grid: 824 pt rounded square centred in the canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x100F27))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let sky = CGGradient(colorsSpace: space, colors: [color(0x2A2650), color(0x131230), color(0x100F27)] as CFArray,
                     locations: [0, 0.6, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 330, y: 924), end: CGPoint(x: 700, y: 100), options: [])
let haze = CGGradient(colorsSpace: space, colors: [color(0xC9B3F0, 0.22), color(0xC9B3F0, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(haze, startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 560), endRadius: 460, options: [])

let stars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (230, 800, 7, 0.95), (330, 720, 4, 0.7), (760, 820, 6, 0.9), (820, 660, 4, 0.6),
    (200, 560, 5, 0.75), (300, 300, 4, 0.55), (800, 300, 5, 0.7), (680, 210, 3.5, 0.5),
    (430, 860, 3.5, 0.6), (880, 470, 3.5, 0.5),
]
for (x, y, r, a) in stars {
    ctx.setFillColor(color(0xF8F3E0, a))
    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}

// Crescent: a cream disc with an offset disc cut out, glowing lavender.
ctx.setShadow(offset: .zero, blur: 70, color: color(0xC9B3F0, 0.75))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
let moon = CGRect(x: 512 - 250, y: 512 - 250, width: 500, height: 500)
ctx.addEllipse(in: moon)
ctx.clip()
let moonFill = CGGradient(colorsSpace: space, colors: [color(0xFFFAF0), color(0xF8F3E0), color(0xC9B3F0)] as CFArray,
                          locations: [0, 0.55, 1])!
ctx.drawLinearGradient(moonFill, start: CGPoint(x: 330, y: 740), end: CGPoint(x: 640, y: 280), options: [])
ctx.setBlendMode(.clear)
ctx.fillEllipse(in: CGRect(x: 512 - 120, y: 512 - 160, width: 470, height: 470))
ctx.endTransparencyLayer()
ctx.restoreGState()

NSGraphicsContext.current = nil
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
