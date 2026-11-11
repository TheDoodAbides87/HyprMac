// Turns square, full-bleed icon artwork into a macOS app icon on Apple's grid:
// the rounded tile is cut out (transparent corners), scaled to 824 of 1024 px,
// centered, and given the standard soft drop shadow.
// Usage: swift Tools/make-icon.swift <artwork.png> <output.png>
// The output is the 1024 px master that build.sh packs into AppIcon.icns.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]),
      let art = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("Usage: swift Tools/make-icon.swift <artwork.png> <output.png>\n".data(using: .utf8)!)
    exit(2)
}

let size = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)  // Apple's macOS icon grid
// The artwork's own corner radius is about 22% of its width, the same as macOS
// icons; cutting just inside its edge drops the dark fringe around the tile.
let radius = tile.width * 0.225
let cut = tile.insetBy(dx: 2, dy: 2)

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
let shape = CGPath(roundedRect: cut, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Shadow: drawn from the tile's shape, below it.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(shape)
ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

// The artwork, clipped to the tile.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
ctx.draw(art, in: tile)
ctx.restoreGState()

guard let image = ctx.makeImage(),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))
