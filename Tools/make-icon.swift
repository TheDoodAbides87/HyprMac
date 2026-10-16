// Renders the HyprMac app icon: an apple silhouette cut into dwindle tiles.
// Usage: swift Tools/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

func hex(_ s: String) -> CGColor { NSColor(hex: s).cgColor }
extension NSColor {
    convenience init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Work in a y-down space so the shapes read like SVG.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// macOS icon grid: 824 pt squircle centred in 1024.
let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let grad = CGGradient(colorsSpace: cs, colors: [hex("#24283B"), hex("#16161E")] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
ctx.restoreGState()

// Apple artwork is drawn in a 1000-unit box, then scaled into the squircle.
let (sx, sy, ox, oy): (CGFloat, CGFloat, CGFloat, CGFloat) = (0.64, 0.72, 192, 128)
ctx.translateBy(x: ox, y: oy)
ctx.scaleBy(x: sx, y: sy)

let body = CGMutablePath()
body.move(to: CGPoint(x: 500, y: 330))
body.addCurve(to: CGPoint(x: 250, y: 330), control1: CGPoint(x: 440, y: 290), control2: CGPoint(x: 330, y: 270))
body.addCurve(to: CGPoint(x: 170, y: 630), control1: CGPoint(x: 160, y: 400), control2: CGPoint(x: 140, y: 520))
body.addCurve(to: CGPoint(x: 370, y: 890), control1: CGPoint(x: 200, y: 750), control2: CGPoint(x: 280, y: 880))
body.addCurve(to: CGPoint(x: 500, y: 868), control1: CGPoint(x: 420, y: 895), control2: CGPoint(x: 450, y: 868))
body.addCurve(to: CGPoint(x: 630, y: 890), control1: CGPoint(x: 550, y: 868), control2: CGPoint(x: 580, y: 895))
body.addCurve(to: CGPoint(x: 830, y: 630), control1: CGPoint(x: 720, y: 880), control2: CGPoint(x: 800, y: 750))
body.addCurve(to: CGPoint(x: 750, y: 330), control1: CGPoint(x: 860, y: 520), control2: CGPoint(x: 840, y: 400))
body.addCurve(to: CGPoint(x: 500, y: 330), control1: CGPoint(x: 670, y: 270), control2: CGPoint(x: 560, y: 290))
body.closeSubpath()

let leaf = CGMutablePath()
leaf.move(to: CGPoint(x: 505, y: 295))
leaf.addCurve(to: CGPoint(x: 630, y: 150), control1: CGPoint(x: 495, y: 225), control2: CGPoint(x: 550, y: 160))
leaf.addCurve(to: CGPoint(x: 505, y: 295), control1: CGPoint(x: 640, y: 230), control2: CGPoint(x: 585, y: 285))
leaf.closeSubpath()

// Dwindle spiral: left half, then the right side keeps splitting along its longer edge.
let g: CGFloat = 9  // half the gap between tiles
let tiles: [(CGRect, String)] = [
    (CGRect(x: 120, y: 260, width: 380, height: 660), "#7AA2F7"),  // 1: left
    (CGRect(x: 500, y: 260, width: 380, height: 320), "#BB9AF7"),  // 2: right top
    (CGRect(x: 500, y: 580, width: 190, height: 340), "#7DCFFF"),  // 3: bottom-left of right
    (CGRect(x: 690, y: 580, width: 190, height: 170), "#E0AF68"),  // 4
    (CGRect(x: 690, y: 750, width: 190, height: 170), "#F7768E"),  // 5
]

ctx.saveGState()
ctx.addPath(body)
ctx.clip()
for (r, c) in tiles {
    ctx.setFillColor(hex(c))
    ctx.addPath(CGPath(roundedRect: r.insetBy(dx: g, dy: g), cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.fillPath()
}
// The bite shows the background gradient through it.
ctx.addEllipse(in: CGRect(x: 770, y: 370, width: 260, height: 260))
ctx.clip()
ctx.drawLinearGradient(grad, start: CGPoint(x: 500, y: (100 - oy) / sy), end: CGPoint(x: 500, y: (924 - oy) / sy), options: [])
ctx.restoreGState()

ctx.setFillColor(hex("#9ECE6A"))
ctx.addPath(leaf)
ctx.fillPath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
