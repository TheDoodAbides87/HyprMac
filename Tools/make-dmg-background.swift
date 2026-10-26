// Renders the background of the HyprMac installer window: the app on the left,
// the Applications folder on the right, and an arrow between them.
// Usage: swift Tools/make-dmg-background.swift <output.png> <scale>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.png"
let scale = CommandLine.arguments.count > 2 ? CGFloat(Double(CommandLine.arguments[2]) ?? 1) : 1
let size = NSSize(width: 660, height: 400)  // must match the window size in build.sh

func hex(_ s: String, _ alpha: CGFloat = 1) -> NSColor {
    var v: UInt64 = 0
    Scanner(string: String(s.dropFirst())).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Same dark gradient as the app icon.
NSGradient(starting: hex("#24283B"), ending: hex("#16161E"))!.draw(in: NSRect(origin: .zero, size: size), angle: -90)

// Arrow from the app slot (x 165) to the Applications slot (x 495), at icon height.
let y: CGFloat = 400 - 190
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 255, y: y))
arrow.line(to: NSPoint(x: 395, y: y))
arrow.lineWidth = 5
arrow.lineCapStyle = .round
hex("#7AA2F7").setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 380, y: y + 14))
head.line(to: NSPoint(x: 400, y: y))
head.line(to: NSPoint(x: 380, y: y - 14))
head.lineWidth = 5
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: color, .paragraphStyle: para]
    NSAttributedString(string: s, attributes: attrs).draw(in: NSRect(x: 0, y: y, width: 660, height: size * 1.5))
}
text("Drag HyprMac into Applications", size: 20, weight: .semibold, color: hex("#C0CAF5"), y: 400 - 345)
text("Then open it and allow Accessibility access when asked.", size: 13, weight: .regular,
     color: hex("#A9B1D6", 0.8), y: 400 - 372)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
