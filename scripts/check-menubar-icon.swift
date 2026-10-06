import AppKit

@main
struct MenuBarIconCheck {
    @MainActor static func main() throws {
        let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".build/menubar-proof"
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        for connected in [true, false] {
            let image = YorozuMenuBarIcon.image(connected: connected)
            precondition(image.isTemplate && image.size == NSSize(width: 18, height: 18))
            for scale in [1, 2] {
                let pixels = 18 * scale
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphics
                // Exercise the actual NSImage drawing handler, not a second implementation.
                graphics.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                image.draw(in: CGRect(x: 0, y: 0, width: 18, height: 18))
                graphics.flushGraphics()
                NSGraphicsContext.restoreGraphicsState()
                let alpha = (0..<pixels).flatMap { y in (0..<pixels).map { x in bitmap.colorAt(x: x, y: y)!.alphaComponent } }
                precondition(alpha.max()! > (connected ? 0.9 : 0.5) && alpha.min()! == 0)
                for n in 0..<pixels {
                    precondition(bitmap.colorAt(x: n, y: 0)!.alphaComponent == 0)
                    precondition(bitmap.colorAt(x: n, y: pixels-1)!.alphaComponent == 0)
                    precondition(bitmap.colorAt(x: 0, y: n)!.alphaComponent == 0)
                    precondition(bitmap.colorAt(x: pixels-1, y: n)!.alphaComponent == 0)
                }
                let state = connected ? "connected" : "offline"
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(output)/\(state)-\(scale)x-template.png"))
                for dark in [false, true] {
                    let preview = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    for y in 0..<pixels {
                        for x in 0..<pixels {
                            let a = bitmap.colorAt(x: x, y: y)!.alphaComponent
                            let white = dark ? a : 1-a
                            preview.setColor(NSColor(deviceRed: white, green: white, blue: white, alpha: 1), atX: x, y: y)
                        }
                    }
                    precondition(preview.colorAt(x: 0, y: 0)!.alphaComponent == 1)
                    precondition(preview.colorAt(x: 0, y: 0)!.redComponent == (dark ? 0 : 1))
                    let theme = dark ? "dark" : "light"
                    try preview.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(output)/\(state)-\(theme)-\(scale)x.png"))
                }
            }
        }
        let online = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: "\(output)/connected-2x-template.png")))!
        let offline = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: "\(output)/offline-2x-template.png")))!
        precondition(online.colorAt(x: 18, y: 18)!.alphaComponent > offline.colorAt(x: 18, y: 18)!.alphaComponent + 0.5)
        print("PASS: template size, actual NSImage render, 1x/2x alpha, unclipped margins, center state distinction; 12 PNGs")
    }
}
