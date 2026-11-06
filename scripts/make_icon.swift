// Genera scripts/assets/Astrolabio.icns (fondo azul noche con una estrella y un anillo).
import AppKit
let out = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Astrolabio.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(red: 0.10, green: 0.22, blue: 0.48, alpha: 1), NSColor(red: 0.02, green: 0.05, blue: 0.14, alpha: 1)])!
        .draw(in: path, angle: -90)
    // Anillo (astrolabio) y estrellas de fondo.
    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: s * 0.13, dy: s * 0.13))
    ring.lineWidth = s * 0.025
    NSColor(red: 0.55, green: 0.78, blue: 1, alpha: 0.55).setStroke(); ring.stroke()
    var g = SystemRandomNumberGenerator()
    for _ in 0..<40 {
        let r = CGFloat.random(in: s * 0.003...s * 0.009, using: &g)
        let p = NSPoint(x: .random(in: rect.minX + r...rect.maxX - r, using: &g), y: .random(in: rect.minY + r...rect.maxY - r, using: &g))
        NSColor(white: 1, alpha: .random(in: 0.3...0.8, using: &g)).setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)).fill()
    }
    // Estrella central de cuatro puntas.
    let c = NSPoint(x: s / 2, y: s / 2), R = s * 0.27, r = s * 0.06
    let star = NSBezierPath()
    for i in 0..<8 {
        let a = CGFloat(i) * .pi / 4 + .pi / 2
        let rad = i % 2 == 0 ? R : r
        let p = NSPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad)
        if i == 0 { star.move(to: p) } else { star.line(to: p) }
    }
    star.close()
    NSGradient(colors: [.white, NSColor(red: 0.75, green: 0.88, blue: 1, alpha: 1)])!.draw(in: star, relativeCenterPosition: .zero)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Icono: \(out)" : "iconutil falló")
