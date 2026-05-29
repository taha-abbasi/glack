import AppKit
import Foundation

// Generate macOS AppIcon PNGs from branding/glack-logo.png at the EXACT
// pixel dimensions actool expects. NSImage.lockFocus() doubles every size
// on retina displays (the lesson behind the first attempt at this script:
// every PNG came out 2× too large and actool silently dropped them all).
// CGContext gives pixel-precise output.

let srcPath = "/Users/tahaabbasi/Developer/glack/branding/glack-logo.png"
let outDir = "/Users/tahaabbasi/Developer/glack/Glack/Assets.xcassets/AppIcon.appiconset"

guard let srcData = NSData(contentsOf: URL(fileURLWithPath: srcPath)),
      let imgSrc = CGImageSourceCreateWithData(srcData, nil),
      let srcImage = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil) else {
    FileHandle.standardError.write("Couldn't load source\n".data(using: .utf8)!)
    exit(1)
}
print("source: \(srcImage.width)×\(srcImage.height)")

// CGImage.cropping(to:) uses pixel coords with origin at top-left
// (matching PNG layout). The bubble symbol sits in the upper half of
// the 1254×1254 poster, roughly x:275..975, y:60..760.
let bubbleCrop = CGRect(x: 275, y: 60, width: 700, height: 700)
guard let cropped = srcImage.cropping(to: bubbleCrop) else {
    FileHandle.standardError.write("crop failed\n".data(using: .utf8)!)
    exit(2)
}

let sizes: [(name: String, dim: Int)] = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024),
]

let colorSpace = CGColorSpaceCreateDeviceRGB()
for (name, dim) in sizes {
    guard let ctx = CGContext(
        data: nil,
        width: dim, height: dim,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { continue }

    ctx.interpolationQuality = .high
    let dimF = CGFloat(dim)
    let radius = dimF * 0.22

    // Soft off-white squircle background.
    let bg = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: dimF, height: dimF),
        cornerWidth: radius, cornerHeight: radius, transform: nil
    )
    ctx.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1.0))
    ctx.addPath(bg)
    ctx.fillPath()

    // Clip subsequent draws to the rounded shape.
    ctx.addPath(bg)
    ctx.clip()

    // Draw bubble inset 12% on each side. CGContext draws CGImages with
    // implicit y-flip so the source ends up right-side up in the PNG.
    let inset = dimF * 0.12
    let drawRect = CGRect(x: inset, y: inset, width: dimF - 2 * inset, height: dimF - 2 * inset)
    ctx.draw(cropped, in: drawRect)

    guard let outImg = ctx.makeImage() else { continue }
    let outURL = URL(fileURLWithPath: "\(outDir)/\(name)")
    guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil) else { continue }
    CGImageDestinationAddImage(dest, outImg, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(name) (\(dim)×\(dim))")
}
