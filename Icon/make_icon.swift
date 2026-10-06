import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: 1024, height: 1024)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824pt rounded square centred on a 1024 canvas
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let sh = NSShadow()
sh.shadowColor = NSColor.black.withAlphaComponent(0.28)
sh.shadowBlurRadius = 24
sh.shadowOffset = NSSize(width: 0, height: -10)
sh.set()
NSColor.white.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
shape.addClip()
let bg = NSGradient(colors: [NSColor(srgbRed: 1.0, green: 0.82, blue: 0.62, alpha: 1), NSColor(srgbRed: 1.0, green: 0.52, blue: 0.68, alpha: 1)])!
bg.draw(in: body, angle: -90)

// The expanded notch: flush with the top edge, rounded bottom corners
let L: CGFloat = 222, R: CGFloat = 802, B: CGFloat = 392, T: CGFloat = 1000, r: CGFloat = 130
let notch = NSBezierPath()
notch.move(to: NSPoint(x: L, y: T))
notch.line(to: NSPoint(x: L, y: B + r))
notch.appendArc(withCenter: NSPoint(x: L + r, y: B + r), radius: r, startAngle: 180, endAngle: 270)
notch.line(to: NSPoint(x: R - r, y: B))
notch.appendArc(withCenter: NSPoint(x: R - r, y: B + r), radius: r, startAngle: 270, endAngle: 360)
notch.line(to: NSPoint(x: R, y: T))
notch.close()
NSGraphicsContext.saveGraphicsState()
let ns = NSShadow()
ns.shadowColor = NSColor(srgbRed: 0.45, green: 0.1, blue: 0.2, alpha: 0.35)
ns.shadowBlurRadius = 30
ns.shadowOffset = NSSize(width: 0, height: -12)
ns.set()
NSColor(white: 0.04, alpha: 1).setFill()
notch.fill()
NSGraphicsContext.restoreGraphicsState()

// Cat in the panel
let font = NSFont(name: "Apple Color Emoji", size: 300)!
let cat = NSAttributedString(string: "🐱", attributes: [.font: font])
let cs = cat.size()
cat.draw(at: NSPoint(x: 512 - cs.width / 2, y: 650 - cs.height / 2 - 6))

// Carousel dots
for (i, a) in [0.5, 1.0, 0.5].enumerated() {
    let cx = 512 + CGFloat(i - 1) * 74
    NSColor.white.withAlphaComponent(a).setFill()
    NSBezierPath(ovalIn: NSRect(x: cx - 22, y: 248, width: 44, height: 44)).fill()
}
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("ICON", out)
