import AppKit
import Foundation

let outputPath = CommandLine.arguments.dropFirst().first ?? "Packaging/AppIcon.icns"
let outputURL = URL(fileURLWithPath: outputPath)
let iconsetURL = outputURL.deletingPathExtension().appendingPathExtension("iconset")

// Source PNG sits next to the output .icns (Packaging/AppIcon.png).
let sourcePNGURL = outputURL.deletingLastPathComponent().appendingPathComponent("AppIcon.png")

guard let sourceImage = NSImage(contentsOf: sourcePNGURL) else {
    FileHandle.standardError.write(Data("error: cannot load source icon at \(sourcePNGURL.path)\n".utf8))
    exit(1)
}

let fileManager = FileManager.default
try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func resizedPNG(_ image: NSImage, pixels: Int) -> Data {
    let size = NSSize(width: pixels, height: pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(origin: .zero, size: size),
               from: .zero,
               operation: .copy,
               fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in sizes {
    let data = resizedPNG(sourceImage, pixels: size.pixels)
    try data.write(to: iconsetURL.appendingPathComponent(size.name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", "-o", outputURL.path, iconsetURL.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    throw NSError(domain: "VoiceTyperIcon", code: Int(process.terminationStatus))
}

try? fileManager.removeItem(at: iconsetURL)
