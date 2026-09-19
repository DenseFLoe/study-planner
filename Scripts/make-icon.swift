import AppKit
import Foundation
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = AffineTransform(scale: Double(pixels) / 1024)
        (transform as NSAffineTransform).concat()
        NSColor(calibratedRed: 0.13, green: 0.44, blue: 0.96, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 56, y: 56, width: 912, height: 912), xRadius: 210, yRadius: 210).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 205, y: 215, width: 614, height: 584), xRadius: 78, yRadius: 78).fill()
        NSColor(calibratedRed: 0.86, green: 0.92, blue: 1, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 205, y: 660, width: 614, height: 139), xRadius: 65, yRadius: 65).fill()
        NSRect(x: 205, y: 660, width: 614, height: 65).fill()
        for x in [330, 646] {
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: 742, width: 48, height: 100), xRadius: 24, yRadius: 24).fill()
        }
        for (i, width) in [330, 220, 290].enumerated() {
            let y = 542 - i * 115
            NSColor(calibratedRed: 0.16, green: 0.48, blue: 0.96, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 290, y: y, width: 48, height: 48), xRadius: 14, yRadius: 14).fill()
            NSColor(calibratedRed: 0.69, green: 0.79, blue: 0.94, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 380, y: y + 10, width: width, height: 28), xRadius: 14, yRadius: 14).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
    }
}
