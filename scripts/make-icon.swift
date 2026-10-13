import AppKit

// Renders the app icon (blue squircle with a magnifying glass) into an .iconset folder.
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.0, alpha: 1),
               ending: NSColor(calibratedRed: 0.05, green: 0.25, blue: 0.75, alpha: 1))!.draw(in: shape, angle: -90)
    NSColor.white.setStroke()
    let r = rect.width * 0.22
    let c = NSPoint(x: rect.midX - rect.width * 0.06, y: rect.midY + rect.width * 0.06)
    let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ring.lineWidth = rect.width * 0.075
    ring.stroke()
    let handle = NSBezierPath()
    let a = r * 0.72
    handle.move(to: NSPoint(x: c.x + a, y: c.y - a))
    handle.line(to: NSPoint(x: c.x + r * 1.75, y: c.y - r * 1.75))
    handle.lineWidth = rect.width * 0.11
    handle.lineCapStyle = .round
    handle.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
