#!/usr/bin/env swift

import AppKit
import Foundation

let logicalTile = 24
let scale = 2
let columns = 6
let rows = 3

enum Ink {
    case white
    case light
    case mid
    case dark

    var color: NSColor {
        switch self {
        case .white: NSColor(calibratedWhite: 1, alpha: 1)
        case .light: NSColor(calibratedWhite: 0.82, alpha: 1)
        case .mid: NSColor(calibratedWhite: 0.48, alpha: 1)
        case .dark: NSColor(calibratedWhite: 0.08, alpha: 1)
        }
    }
}

struct PixelCanvas {
    let context: CGContext
    let tileX: Int
    let tileY: Int
    let contentOffsetY: Int

    init(context: CGContext, tileX: Int, tileY: Int, contentOffsetY: Int = 0) {
        self.context = context
        self.tileX = tileX
        self.tileY = tileY
        self.contentOffsetY = contentOffsetY
    }

    func rect(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ ink: Ink) {
        context.setFillColor(ink.color.cgColor)
        let px = (tileX * logicalTile + x) * scale
        let py = ((rows - tileY) * logicalTile - y - contentOffsetY - height) * scale
        context.fill(CGRect(x: px, y: py, width: width * scale, height: height * scale))
    }

    func pixel(_ x: Int, _ y: Int, _ ink: Ink) {
        rect(x, y, 1, 1, ink)
    }

    func offset(y: Int) -> PixelCanvas {
        PixelCanvas(context: context, tileX: tileX, tileY: tileY, contentOffsetY: y)
    }
}

func frontHead(_ canvas: PixelCanvas, blink: Bool = false) {
    canvas.rect(11, 1, 2, 1, .white)
    canvas.rect(11, 2, 1, 3, .light)
    canvas.pixel(10, 4, .mid)
    canvas.rect(5, 5, 14, 1, .white)
    canvas.rect(4, 6, 16, 7, .white)
    canvas.rect(5, 13, 14, 2, .white)
    canvas.rect(5, 7, 14, 6, .light)
    canvas.rect(6, 8, 12, 4, .white)
    canvas.rect(2, 8, 2, 4, .mid)
    canvas.pixel(3, 7, .white)
    canvas.rect(20, 8, 2, 4, .mid)
    canvas.pixel(20, 7, .white)
    if blink {
        canvas.rect(8, 10, 2, 1, .dark)
        canvas.rect(14, 10, 2, 1, .dark)
    } else {
        canvas.rect(8, 9, 2, 2, .dark)
        canvas.rect(14, 9, 2, 2, .dark)
        canvas.pixel(8, 9, .mid)
        canvas.pixel(14, 9, .mid)
    }
}

func frontBody(_ canvas: PixelCanvas, sitting: Bool, wave: Int? = nil) {
    canvas.rect(8, 15, 8, 6, .light)
    canvas.rect(9, 16, 6, 4, .white)
    canvas.rect(10, 17, 4, 2, .dark)
    canvas.rect(11, 17, 2, 1, .mid)

    if let wave {
        canvas.rect(5, 16, 3, 2, .white)
        canvas.rect(4, 18, 2, 3, .light)
        switch wave {
        case 1:
            canvas.rect(17, 13, 2, 5, .white)
            canvas.rect(18, 10, 2, 4, .light)
            canvas.pixel(20, 10, .white)
        case 3:
            canvas.rect(16, 14, 3, 2, .white)
            canvas.rect(18, 11, 2, 4, .light)
            canvas.pixel(17, 10, .white)
        default:
            canvas.rect(16, 16, 3, 2, .white)
            canvas.rect(18, 17, 2, 3, .light)
        }
    } else {
        canvas.rect(5, 16, 3, 2, .white)
        canvas.rect(4, 18, 2, 3, .light)
        canvas.rect(16, 16, 3, 2, .white)
        canvas.rect(18, 18, 2, 3, .light)
    }

    if sitting {
        canvas.rect(7, 20, 4, 2, .white)
        canvas.rect(5, 21, 6, 2, .light)
        canvas.rect(13, 20, 4, 2, .white)
        canvas.rect(13, 21, 6, 2, .light)
    } else {
        canvas.rect(8, 20, 3, 3, .white)
        canvas.rect(7, 22, 4, 1, .mid)
        canvas.rect(13, 20, 3, 3, .white)
        canvas.rect(13, 22, 4, 1, .mid)
    }
}

func drawIdle(_ canvas: PixelCanvas, frame: Int) {
    // Sleeping pose is shifted left to leave a clear column for drifting Zs.
    canvas.rect(8, 2, 2, 1, .white)
    canvas.rect(8, 3, 1, 2, .light)
    canvas.rect(2, 5, 14, 1, .white)
    canvas.rect(1, 6, 16, 7, .white)
    canvas.rect(2, 13, 14, 2, .white)
    canvas.rect(2, 7, 14, 6, .light)
    canvas.rect(3, 8, 12, 4, .white)
    canvas.rect(0, 8, 1, 4, .mid)
    canvas.rect(17, 8, 1, 4, .mid)
    canvas.rect(5, 10, 3, 1, .dark)
    canvas.rect(11, 10, 3, 1, .dark)
    canvas.rect(5, 15, 8, 6, .light)
    canvas.rect(6, 16, 6, 4, .white)
    canvas.rect(7, 17, 4, 2, .dark)
    canvas.rect(8, 17, 2, 1, .mid)
    canvas.rect(2, 16, 3, 2, .white)
    canvas.rect(1, 18, 2, 3, .light)
    canvas.rect(13, 16, 3, 2, .white)
    canvas.rect(15, 18, 2, 3, .light)
    canvas.rect(4, 20, 4, 2, .white)
    canvas.rect(2, 21, 6, 2, .light)
    canvas.rect(10, 20, 4, 2, .white)
    canvas.rect(10, 21, 6, 2, .light)

    func z(_ x: Int, _ y: Int, width: Int) {
        canvas.rect(x, y, width, 1, .white)
        for step in 1..<(width - 1) {
            canvas.pixel(x + width - step - 1, y + step, .white)
        }
        canvas.rect(x, y + width - 1, width, 1, .white)
    }

    if frame != 3 { z(19, 11, width: 3) }
    if frame >= 1 { z(20, 6, width: 3) }
    if frame >= 2 { z(19, 1, width: 4) }
}

func drawWalking(_ canvas: PixelCanvas, frame: Int) {
    let bob = [0, 1, 1, 0, 1, 1][frame]
    let y = bob
    canvas.rect(9, 1 + y, 2, 1, .white)
    canvas.rect(9, 2 + y, 1, 2, .light)
    canvas.rect(5, 4 + y, 12, 1, .white)
    canvas.rect(4, 5 + y, 14, 8, .white)
    canvas.rect(5, 6 + y, 12, 6, .light)
    canvas.rect(3, 7 + y, 2, 4, .mid)
    canvas.pixel(3, 8 + y, .white)
    canvas.rect(14, 7 + y, 3, 4, .white)
    canvas.rect(15, 8 + y, 2, 2, .dark)
    canvas.rect(18, 8 + y, 2, 3, .white)
    canvas.pixel(20, 9 + y, .light)
    canvas.rect(8, 13 + y, 7, 6, .light)
    canvas.rect(11, 14 + y, 4, 3, .white)
    canvas.rect(12, 15 + y, 3, 2, .dark)

    let armForward = frame == 1 || frame == 2 || frame == 3
    if armForward {
        canvas.rect(14, 14 + y, 3, 2, .white)
        canvas.rect(16, 15 + y, 3, 2, .light)
        canvas.pixel(19, 16 + y, .white)
        canvas.rect(6, 15 + y, 2, 4, .mid)
    } else {
        canvas.rect(6, 14 + y, 2, 4, .white)
        canvas.rect(4, 17 + y, 3, 2, .light)
        canvas.rect(14, 15 + y, 2, 4, .mid)
    }

    let phase = frame % 3
    if phase == 0 {
        canvas.rect(8, 18 + y, 3, 2, .white)
        canvas.rect(5, 20 + y, 5, 2, .light)
        canvas.rect(13, 18 + y, 3, 3, .white)
        canvas.rect(15, 20 + y, 4, 2, .light)
    } else if phase == 1 {
        canvas.rect(8, 18 + y, 3, 3, .white)
        canvas.rect(7, 20 + y, 4, 2, .light)
        canvas.rect(13, 18 + y, 3, 2, .white)
        canvas.rect(12, 20 + y, 5, 2, .light)
    } else {
        canvas.rect(7, 18 + y, 4, 2, .white)
        canvas.rect(5, 20 + y, 4, 2, .light)
        canvas.rect(13, 18 + y, 4, 2, .white)
        canvas.rect(16, 20 + y, 4, 2, .light)
    }

    canvas.rect(0, 23, 7, 1, .mid)
    canvas.rect(17, 23, 7, 1, .mid)
}

func drawAttention(_ canvas: PixelCanvas, frame: Int) {
    frontHead(canvas)
    frontBody(canvas, sitting: false)
}

let pixelWidth = logicalTile * scale * columns
let pixelHeight = logicalTile * scale * rows
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelWidth,
    pixelsHigh: pixelHeight,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else {
    fatalError("Unable to create sprite bitmap")
}

context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
for frame in 0..<4 { drawIdle(PixelCanvas(context: context, tileX: frame, tileY: 0), frame: frame) }
for frame in 0..<6 { drawWalking(PixelCanvas(context: context, tileX: frame, tileY: 1), frame: frame) }
for frame in 0..<4 { drawAttention(PixelCanvas(context: context, tileX: frame, tileY: 2), frame: frame) }

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode sprite sheet")
}

let scriptURL = URL(fileURLWithPath: #filePath)
let outputURL = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/NotchBot/Resources/RobotAtlas.png")
try png.write(to: outputURL)
print("Generated \(outputURL.path) (\(pixelWidth)x\(pixelHeight))")
