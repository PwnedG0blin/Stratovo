import AppKit
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let icon = NSImage(contentsOfFile: CommandLine.arguments[2])
let size = NSSize(width: 1000, height: 620)
let image = NSImage(size: size)
image.lockFocus()
let rect = NSRect(origin: .zero, size: size)
NSGradient(starting: NSColor(calibratedRed: 0.035, green: 0.085, blue: 0.15, alpha: 1),
           ending: NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.24, alpha: 1))!.draw(in: rect, angle: -35)
func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ font: NSFont, _ color: NSColor) {
    (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
}
icon?.draw(in: NSRect(x: 76, y: 483, width: 70, height: 70))
text("Stratovo", 168, 510, .systemFont(ofSize: 38, weight: .semibold), .white)
text("Android · Windows · Ubuntu", 170, 482, .systemFont(ofSize: 17), .lightGray)
text("Drag Stratovo to Applications", 285, 410, .systemFont(ofSize: 23, weight: .medium), .white)
NSColor.white.withAlphaComponent(0.055).setFill()
NSBezierPath(roundedRect: NSRect(x: 135, y: 180, width: 190, height: 190), xRadius: 28, yRadius: 28).fill()
NSBezierPath(roundedRect: NSRect(x: 675, y: 180, width: 190, height: 190), xRadius: 28, yRadius: 28).fill()
let turquoise = NSColor(calibratedRed: 0.212, green: 0.871, blue: 0.820, alpha: 0.85)
turquoise.setStroke()
let arrow = NSBezierPath(); arrow.lineWidth = 3
arrow.move(to: NSPoint(x: 435, y: 279)); arrow.line(to: NSPoint(x: 565, y: 279))
arrow.move(to: NSPoint(x: 547, y: 296)); arrow.line(to: NSPoint(x: 565, y: 279)); arrow.line(to: NSPoint(x: 547, y: 262)); arrow.stroke()
text("Free & open source", 80, 48, .systemFont(ofSize: 14), .lightGray)
text("pwnedg0blin.pages.dev", 730, 48, .systemFont(ofSize: 14), .lightGray)
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
