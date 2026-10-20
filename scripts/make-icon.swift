// Draws the app icon into App/Resources/Assets.xcassets/AppIcon.appiconset: a white line
// drawing of mountains on a red gradient.
// Usage: swift scripts/make-icon.swift [output folder]
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "App/Resources/Assets.xcassets/AppIcon.appiconset")

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: the shape fills ~80% of the canvas.
    let inset = size * 0.1
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = size * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
    shadow.set()
    NSGradient(colors: [
        NSColor(red: 1.00, green: 0.45, blue: 0.38, alpha: 1),
        NSColor(red: 0.90, green: 0.17, blue: 0.23, alpha: 1),
        NSColor(red: 0.58, green: 0.05, blue: 0.16, alpha: 1),
    ])!.draw(in: shape, angle: -55)
    NSGraphicsContext.current?.restoreGraphicsState()

    // The drawing, in units of the shape's width from its bottom-left corner.
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }
    func line(_ points: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: point(points[0].0, points[0].1))
        for next in points.dropFirst() { path.line(to: point(next.0, next.1)) }
        return path
    }
    let ridge = line([(0.10, 0.27), (0.42, 0.73), (0.60, 0.48), (0.71, 0.61), (0.90, 0.27)])
    let snow = line([(0.33, 0.60), (0.376, 0.555), (0.422, 0.60), (0.468, 0.555), (0.514, 0.60)])
    let ground = line([(0.10, 0.27), (0.90, 0.27)])

    NSColor.white.setStroke()
    for path in [ridge, snow, ground] {
        path.lineWidth = rect.width * 0.045
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: points * scale).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(output.path)")
