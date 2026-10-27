// Turns a screen recording into an animated GIF for the README, using only
// macOS's own frameworks (no ffmpeg needed).
// Usage: swift Tools/make-gif.swift <video> <output.gif> [width=960] [fps=12] [blur rects...]
// Blur rects are x0,y0,x1,y1 in the video's pixels (top-left origin) and are
// blurred in every frame before shrinking, which wipes out small text (usernames
// and the like) while window edges and layout stay clear at GIF size.
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: make-gif <video> <output.gif> [width] [fps] [x0,y0,x1,y1 ...]")
    exit(1)
}
let width = args.count > 3 ? Double(args[3]) ?? 960 : 960
let fps = args.count > 4 ? Double(args[4]) ?? 12 : 12
let blurRects: [CGRect] = args.dropFirst(5).map { spec in
    let v = spec.split(separator: ",").map { CGFloat(Double($0)!) }
    return CGRect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1])
}

let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let duration = CMTimeGetSeconds(asset.duration)
let generator = AVAssetImageGenerator(asset: asset)  // copyCGImage is deprecated but simple and synchronous
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero

let frameCount = Int(duration * fps)
let delay = 1.0 / fps
guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                                 UTType.gif.identifier as CFString, frameCount, nil) else {
    print("can't write \(args[2])")
    exit(1)
}
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                  kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
let ci = CIContext()

for i in 0..<frameCount {
    let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
    guard var frame = try? generator.copyCGImage(at: t, actualTime: nil) else { continue }
    if !blurRects.isEmpty {
        let src = CIImage(cgImage: frame)
        let h = src.extent.height
        var img = src
        for r in blurRects {
            let flipped = CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
            img = src.clampedToExtent()
                .applyingGaussianBlur(sigma: 6)
                .cropped(to: flipped)
                .composited(over: img)
        }
        frame = ci.createCGImage(img, from: src.extent)!
    }
    let scale = width / Double(frame.width)
    let w = Int(width), h = Int((Double(frame.height) * scale).rounded())
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
    CGImageDestinationAddImage(dest, ctx.makeImage()!, frameProps)
}
guard CGImageDestinationFinalize(dest) else {
    print("failed to write the GIF")
    exit(1)
}
print("wrote \(args[2]): \(frameCount) frames at \(Int(fps)) fps, \(Int(width)) px wide")
