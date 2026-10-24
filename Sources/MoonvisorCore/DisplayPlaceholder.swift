import CoreGraphics
import Foundation
import ImageIO

/// Erkennt die Ersatzbilder, die QEMU zeigt, solange der Gast kein Bild ausgibt („Guest has not initialized the
/// display (yet).“, „Display output is not active.“). QEMU malt sie schwarz mit einer Zeile grauer Schrift
/// (0xAA, VGA-Zeichensatz 8 × 16) in der Bildmitte. Moonvisor zeigt stattdessen seine eigene Startanzeige.
public enum DisplayPlaceholder {
    static let gray: UInt8 = 0xAA
    static let lineHeight = 16

    /// Zeilen der Textzeile, oben gezählt. QEMU setzt sie auf `(Höhe / 16 - 1) / 2` Zeichenzeilen.
    static func textRows(height: Int) -> Range<Int> {
        let top = max(0, (height / lineHeight - 1) / 2 * lineHeight)
        return top..<min(height, top + lineHeight)
    }

    /// `base`: Pixel mit 3 oder 4 Bytes, Farbreihenfolge egal (grau und schwarz sehen in jeder gleich aus); ein
    /// viertes Byte (Alpha, Füllbyte) wird ignoriert. Über OpenGL kommt das Bild auch auf dem Kopf stehend an.
    public static func matches(_ base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int, bytesPerPixel: Int = 4) -> Bool {
        guard width >= 8, height >= lineHeight, bytesPerPixel >= 3, bytesPerRow >= width * bytesPerPixel else { return false }
        let rows = textRows(height: height)
        let flipped = (height - rows.upperBound)..<(height - rows.lowerBound)
        var text = 0
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            let inText = rows.contains(y) || flipped.contains(y)
            for x in 0..<width {
                let p = row + x * bytesPerPixel
                if p[0] == 0 && p[1] == 0 && p[2] == 0 { continue }
                if inText && p[0] == gray && p[1] == gray && p[2] == gray {
                    text += 1
                    continue
                }
                return false
            }
        }
        return text > 0
    }

    /// Prüft ein Bildschirmfoto von QEMU (`screendump` als PNG). Gelesen werden die Pixel ohne Farbumrechnung.
    public static func matches(pngAt url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.bitsPerComponent == 8, image.bitsPerPixel == 24 || image.bitsPerPixel == 32,
              let data = image.dataProvider?.data else { return false }
        let length = CFDataGetLength(data)
        guard length >= image.bytesPerRow * image.height, let bytes = CFDataGetBytePtr(data) else { return false }
        // Liegt der Alphakanal im ersten Byte, beginnen die Farben ein Byte später.
        let first: [CGImageAlphaInfo] = [.first, .premultipliedFirst, .noneSkipFirst]
        let last: [CGImageAlphaInfo] = [.last, .premultipliedLast, .noneSkipLast]
        let little = image.bitmapInfo.contains(.byteOrder32Little)
        let alphaInFirstByte = image.bitsPerPixel == 32
            && ((first.contains(image.alphaInfo) && !little) || (last.contains(image.alphaInfo) && little))
        let offset = alphaInFirstByte ? 1 : 0
        return matches(bytes + offset, width: image.width, height: image.height, bytesPerRow: image.bytesPerRow,
                       bytesPerPixel: image.bitsPerPixel / 8)
    }
}
