#!/usr/bin/env swift

import AppKit
import Foundation

let masterSize = 1024
let scriptURL = URL(fileURLWithPath: #filePath)
let rootURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let packagingURL = rootURL.appendingPathComponent("Packaging", isDirectory: true)
let iconsetURL = packagingURL.appendingPathComponent("NotchBot.iconset", isDirectory: true)
let outputURL = packagingURL.appendingPathComponent("NotchBot.icns")
let previewURL = packagingURL.appendingPathComponent("NotchBot.png")
let fileManager = FileManager.default

try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

guard let master = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: masterSize,
    pixelsHigh: masterSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: master)?.cgContext else {
    fatalError("Unable to create app icon bitmap")
}

let canvas = CGRect(x: 0, y: 0, width: masterSize, height: masterSize)
context.clear(canvas)

let tile = CGRect(x: 84, y: 84, width: 856, height: 856)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 190, cornerHeight: 190, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -22), blur: 38, color: NSColor.black.withAlphaComponent(0.42).cgColor)
context.addPath(tilePath)
context.setFillColor(NSColor(calibratedWhite: 0.025, alpha: 1).cgColor)
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(tilePath)
context.clip()
let backgroundColors = [
    NSColor(calibratedRed: 0.07, green: 0.075, blue: 0.085, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.012, green: 0.014, blue: 0.018, alpha: 1).cgColor,
] as CFArray
let backgroundGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: backgroundColors,
    locations: [0, 1]
)!
context.drawLinearGradient(
    backgroundGradient,
    start: CGPoint(x: 512, y: tile.maxY),
    end: CGPoint(x: 512, y: tile.minY),
    options: []
)

let glowColors = [
    NSColor(calibratedRed: 1, green: 0.72, blue: 0.08, alpha: 0.5).cgColor,
    NSColor(calibratedRed: 1, green: 0.5, blue: 0.02, alpha: 0.13).cgColor,
    NSColor.clear.cgColor,
] as CFArray
let glowGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: glowColors,
    locations: [0, 0.42, 1]
)!
context.drawRadialGradient(
    glowGradient,
    startCenter: CGPoint(x: 512, y: 455),
    startRadius: 22,
    endCenter: CGPoint(x: 512, y: 455),
    endRadius: 390,
    options: []
)

context.setStrokeColor(NSColor.white.withAlphaComponent(0.1).cgColor)
context.setLineWidth(7)
context.addPath(CGPath(roundedRect: tile.insetBy(dx: 4, dy: 4), cornerWidth: 186, cornerHeight: 186, transform: nil))
context.strokePath()
context.restoreGState()

let gridSize = 32
let pixelSize = 17
let robotOrigin = CGPoint(
    x: (CGFloat(masterSize) - CGFloat(gridSize * pixelSize)) / 2,
    y: 222
)

func pixelRect(_ x: Int, _ y: Int, _ width: Int, _ height: Int, color: NSColor) {
    context.setFillColor(color.cgColor)
    context.fill(CGRect(
        x: robotOrigin.x + CGFloat(x * pixelSize),
        y: robotOrigin.y + CGFloat((gridSize - y - height) * pixelSize),
        width: CGFloat(width * pixelSize),
        height: CGFloat(height * pixelSize)
    ))
}

let white = NSColor(calibratedWhite: 1, alpha: 1)
let light = NSColor(calibratedWhite: 0.82, alpha: 1)
let mid = NSColor(calibratedWhite: 0.46, alpha: 1)
let dark = NSColor(calibratedRed: 0.045, green: 0.05, blue: 0.06, alpha: 1)

context.saveGState()
context.setShadow(
    offset: CGSize(width: 0, height: -4),
    blur: 24,
    color: NSColor(calibratedRed: 1, green: 0.66, blue: 0.04, alpha: 0.42).cgColor
)

pixelRect(15, 0, 3, 2, color: white)
pixelRect(16, 2, 1, 4, color: light)
pixelRect(7, 5, 18, 2, color: white)
pixelRect(5, 7, 22, 11, color: white)
pixelRect(7, 18, 18, 2, color: white)
pixelRect(7, 7, 18, 10, color: light)
pixelRect(8, 8, 16, 7, color: white)
pixelRect(2, 9, 3, 6, color: mid)
pixelRect(27, 9, 3, 6, color: mid)
pixelRect(11, 10, 3, 3, color: dark)
pixelRect(19, 10, 3, 3, color: dark)
pixelRect(11, 10, 1, 1, color: mid)
pixelRect(19, 10, 1, 1, color: mid)

pixelRect(10, 20, 12, 8, color: light)
pixelRect(11, 21, 10, 6, color: white)
pixelRect(13, 23, 6, 3, color: dark)
pixelRect(15, 23, 2, 1, color: mid)
pixelRect(6, 21, 4, 3, color: white)
pixelRect(4, 24, 3, 4, color: light)
pixelRect(22, 21, 4, 3, color: white)
pixelRect(25, 24, 3, 4, color: light)
pixelRect(10, 28, 5, 3, color: white)
pixelRect(8, 30, 7, 2, color: light)
pixelRect(18, 28, 5, 3, color: white)
pixelRect(18, 30, 7, 2, color: light)
context.restoreGState()

let masterImage = NSImage(size: NSSize(width: masterSize, height: masterSize))
master.size = masterImage.size
masterImage.addRepresentation(master)

guard let previewPNG = master.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode app icon preview")
}
try previewPNG.write(to: previewURL, options: .atomic)

let outputs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, size) in outputs {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: representation) else {
        fatalError("Unable to create \(name)")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    masterImage.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: NSRect(x: 0, y: 0, width: masterSize, height: masterSize),
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let png = representation.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode \(name)")
    }
    try png.write(to: iconsetURL.appendingPathComponent(name), options: .atomic)
}

if fileManager.fileExists(atPath: outputURL.path) {
    try fileManager.removeItem(at: outputURL)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", outputURL.path, iconsetURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(iconutil.terminationStatus)")
}

print("Generated \(outputURL.path)")
