#!/usr/bin/env swift
// Generates AppIcon.iconset/*.png → then call: iconutil -c icns AppIcon.iconset
import AppKit
import Foundation

func makeIcon(_ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(size)
    let r = s * 0.225

    // Rounded rect clip
    let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s), xRadius: r, yRadius: r)
    path.setClip()

    // Gradient: warm orange-red (top) → deep red (bottom)
    let gradient = NSGradient(
        colors: [
            NSColor(calibratedRed: 1.00, green: 0.40, blue: 0.06, alpha: 1),
            NSColor(calibratedRed: 0.76, green: 0.06, blue: 0.02, alpha: 1)
        ],
        atLocations: [0.0, 1.0],
        colorSpace: .deviceRGB
    )!
    gradient.draw(in: NSRect(x: 0, y: 0, width: s, height: s), angle: 120)

    // Raised hand emoji (holds the whip)
    let emoji = "🤚"
    let fontSize = s * 0.58
    let font = NSFont.systemFont(ofSize: fontSize)
    let str = NSAttributedString(string: emoji, attributes: [.font: font])
    let sz = str.size()
    str.draw(at: NSPoint(x: (s - sz.width) / 2, y: (s - sz.height) / 2 + s * 0.02))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// Create iconset in current working directory
let dir = FileManager.default.currentDirectoryPath + "/AppIcon.iconset"

try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16",      16),
    ("icon_16x16@2x",   32),
    ("icon_32x32",      32),
    ("icon_32x32@2x",   64),
    ("icon_128x128",   128),
    ("icon_128x128@2x",256),
    ("icon_256x256",   256),
    ("icon_256x256@2x",512),
    ("icon_512x512",   512),
    ("icon_512x512@2x",1024),
]

for (name, size) in sizes {
    let rep = makeIcon(size)
    let data = rep.representation(using: .png, properties: [:])!
    let path = "\(dir)/\(name).png"
    try! data.write(to: URL(fileURLWithPath: path))
    print("  ✓ \(name).png  (\(size)px)")
}
print("Done → \(dir)")
