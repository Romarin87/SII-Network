import AppKit

@main
enum MenuBarIconRegression {
    static func main() throws {
        let artworkURL = URL(fileURLWithPath: CommandLine.arguments[1])
        precondition(NSImage(contentsOf: artworkURL) != nil, "Packaged artwork must load")
        let icon = MenuBarIcon.makeImage(from: artworkURL)
        precondition(icon.size == NSSize(width: 20, height: 20))
        precondition(icon.isTemplate)
        for scale in [1, 2] {
            let pixels = 20 * scale
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            bitmap.size = icon.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            icon.draw(in: NSRect(origin: .zero, size: icon.size))
            NSGraphicsContext.restoreGraphicsState()
            var visiblePixels = 0
            var opaquePixels = 0
            for y in 0..<pixels {
                for x in 0..<pixels {
                    let alpha = bitmap.colorAt(x: x, y: y)!.alphaComponent
                    if alpha > 0.1 { visiblePixels += 1 }
                    if alpha > 0.85 { opaquePixels += 1 }
                    if x == 0 || y == 0 || x == pixels - 1 || y == pixels - 1 {
                        precondition(alpha < 0.01, "Icon must have clear margins, not clipped edges")
                    }
                }
            }
            precondition(visiblePixels > 40 * scale * scale, "Icon must remain visible")
            precondition(opaquePixels > 15 * scale * scale, "Strokes must retain opaque cores at menu-bar size")
            precondition(visiblePixels < pixels * pixels / 2, "White background must not become a solid template")
            if CommandLine.arguments.count == 3 {
                let url = URL(fileURLWithPath: CommandLine.arguments[2])
                    .appendingPathComponent("menu-icon-\(scale)x.png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: url)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSColor.white.setFill()
                NSRect(origin: .zero, size: icon.size).fill()
                icon.draw(in: NSRect(origin: .zero, size: icon.size))
                NSGraphicsContext.restoreGraphicsState()
                let preview = url.deletingLastPathComponent()
                    .appendingPathComponent("menu-icon-preview-\(scale)x.png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: preview)
            }
        }
        print("PASS: 20-point template icon renders at 1x and 2x with opaque strokes and unclipped margins")
    }
}
