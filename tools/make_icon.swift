// swift tools/make_icon.swift  → Resources/AppIcon.icns
import AppKit

let purple = NSColor(red: 0.298, green: 0.251, blue: 0.824, alpha: 1)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // подложка (squircle 824 в холсте 1024)
    let base = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSColor.white.setFill(); base.fill()
    ctx.restoreGState()
    NSGradient(colors: [NSColor(red: 0.93, green: 0.93, blue: 1, alpha: 1), NSColor(red: 0.80, green: 0.80, blue: 0.97, alpha: 1)])!
        .draw(in: base, angle: -90)

    // лист документа
    let sheet = NSBezierPath(roundedRect: NSRect(x: 270, y: 200, width: 484, height: 624), xRadius: 28, yRadius: 28)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    NSColor.white.setFill(); sheet.fill()
    ctx.restoreGState()
    NSColor(white: 0.80, alpha: 1).setFill()
    for (i, w) in [330, 380, 300, 360].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: 330, y: 730 - CGFloat(i) * 52, width: CGFloat(w), height: 22), xRadius: 11, yRadius: 11).fill()
    }

    // штамп
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 340)
    ctx.rotate(by: -0.08)
    let st = NSBezierPath(roundedRect: NSRect(x: -230, y: -110, width: 460, height: 220), xRadius: 40, yRadius: 40)
    NSColor.white.withAlphaComponent(0.92).setFill(); st.fill()
    purple.setStroke(); st.lineWidth = 14; st.stroke()
    purple.setFill()
    NSBezierPath(roundedRect: NSRect(x: -170, y: 40, width: 340, height: 20), xRadius: 10, yRadius: 10).fill()
    for (i, w) in [300, 250, 280].enumerated() {
        purple.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: NSRect(x: -170, y: 0 - CGFloat(i) * 38, width: CGFloat(w), height: 14), xRadius: 7, yRadius: 7).fill()
    }
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = "Resources/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base).png"))
    try render(base * 2).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base)@2x.png"))
}
