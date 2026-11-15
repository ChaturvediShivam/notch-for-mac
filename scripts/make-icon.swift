// Draws the app icon (black squircle, notch pill) into an .iconset. Used by make-app.sh.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = CGFloat(pt * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = px * 0.1, r = NSRect(x: inset, y: inset, width: px - inset * 2, height: px - inset * 2)
    NSColor(white: 0.08, alpha: 1).setFill()
    NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225).fill()
    let pw = r.width * 0.56, ph = r.width * 0.17
    let pill = NSRect(x: r.midX - pw / 2, y: r.maxY - ph - r.height * 0.16, width: pw, height: ph)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: pill, xRadius: ph / 2, yRadius: ph / 2).fill()
    NSColor(white: 1, alpha: 0.18).setStroke()
    let border = NSBezierPath(roundedRect: pill, xRadius: ph / 2, yRadius: ph / 2); border.lineWidth = max(1, px / 256); border.stroke()
    NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1).setFill()     // green "live" dot
    let d = ph * 0.36
    NSBezierPath(ovalIn: NSRect(x: pill.maxX - ph * 0.5 - d / 2, y: pill.midY - d / 2, width: d, height: d)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
}
