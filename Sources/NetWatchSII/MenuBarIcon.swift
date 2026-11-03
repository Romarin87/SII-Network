import AppKit

enum MenuBarIcon {
    static let image = makeImage(from: Bundle.main.url(forResource: "MenuBarTemplate", withExtension: "png"))

    static func makeImage(from url: URL?) -> NSImage {
        let source = url.flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "network", accessibilityDescription: nil)!
        let artwork = templateArtwork(source)
        // Fix the native size as well as the drawing bounds, with clear padding.
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            let scale = min(18 / artwork.size.width, 18 / artwork.size.height)
            let size = NSSize(width: artwork.size.width * scale, height: artwork.size.height * scale)
            NSGraphicsContext.current?.imageInterpolation = .high
            artwork.draw(in: NSRect(
                x: (20 - size.width) / 2, y: (20 - size.height) / 2,
                width: size.width, height: size.height
            ))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "NetWatch SII 网络监测"
        return image
    }

    private static func templateArtwork(_ source: NSImage) -> NSImage {
        // Convert the black-on-white illustration to an alpha mask once.
        // Keeping this in the renderer preserves the source art and allows the
        // system to tint just the ink, including on a dark menu bar.
        let pixels = 144
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        var mask = [CGFloat](repeating: 0, count: pixels * pixels)
        for y in 0..<pixels {
            for x in 0..<pixels {
                let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                let ink = (1 - luminance) * color.alphaComponent
                mask[y * pixels + x] = min(1, max(0, (ink - 0.12) / 0.55))
            }
        }
        // Thicken the ink before reduction, so small strokes retain opaque cores.
        // Crop source whitespace: the drawing itself should occupy the target size.
        var minX = pixels, minY = pixels, maxX = 0, maxY = 0
        for y in 0..<pixels {
            for x in 0..<pixels {
                var alpha: CGFloat = 0
                for dy in -2...2 {
                    for dx in -2...2 where dx * dx + dy * dy <= 4 {
                        let sx = x + dx, sy = y + dy
                        if sx >= 0 && sx < pixels && sy >= 0 && sy < pixels {
                            alpha = max(alpha, mask[sy * pixels + sx])
                        }
                    }
                }
                bitmap.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: alpha), atX: x, y: y)
                if alpha > 0 {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        guard minX <= maxX, minY <= maxY,
              let cropped = bitmap.cgImage?.cropping(to: CGRect(
                x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1
              )) else { return source }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }
}
