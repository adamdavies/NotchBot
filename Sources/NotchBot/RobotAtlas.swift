import AppKit
import Foundation
import NotchBotCore

final class RobotAtlas {
    static let shared = RobotAtlas()

    private let image: CGImage?
    private let tileSize = 48

    lazy var menuBarIcon: NSImage = {
        let logicalSize = 18
        let scale = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: logicalSize * scale,
            pixelsHigh: logicalSize * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else {
            return NSImage(size: NSSize(width: 18, height: 18))
        }

        func pixelRect(_ x: Int, _ y: Int, _ width: Int, _ height: Int) {
            context.fill(CGRect(
                x: x * scale,
                y: (logicalSize - y - height) * scale,
                width: width * scale,
                height: height * scale
            ))
        }

        context.clear(CGRect(x: 0, y: 0, width: logicalSize * scale, height: logicalSize * scale))
        context.setFillColor(NSColor.black.cgColor)
        pixelRect(8, 0, 2, 1)
        pixelRect(8, 1, 1, 2)
        pixelRect(3, 3, 12, 2)
        pixelRect(2, 5, 2, 6)
        pixelRect(14, 5, 2, 6)
        pixelRect(3, 10, 12, 2)
        pixelRect(0, 6, 2, 4)
        pixelRect(16, 6, 2, 4)
        pixelRect(5, 6, 2, 2)
        pixelRect(11, 6, 2, 2)
        pixelRect(6, 12, 6, 4)
        pixelRect(4, 13, 2, 3)
        pixelRect(12, 13, 2, 3)
        pixelRect(4, 16, 4, 2)
        pixelRect(10, 16, 4, 2)

        bitmap.size = NSSize(width: 18, height: 18)
        let result = NSImage(size: bitmap.size)
        result.addRepresentation(bitmap)
        result.isTemplate = true
        return result
    }()

    private init() {
        let sourceResource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/RobotAtlas.png")
        let resourceURL = Bundle.main.url(forResource: "RobotAtlas", withExtension: "png")
            ?? (FileManager.default.fileExists(atPath: sourceResource.path) ? sourceResource : nil)
        guard
            let url = resourceURL,
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else {
            image = nil
            return
        }
        image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func frame(state: RobotState, index: Int) -> NSImage {
        guard let image else { return NSImage(size: NSSize(width: 24, height: 24)) }
        let row: Int
        let frameCount: Int
        switch state {
        case .idle:
            row = 0
            frameCount = 4
        case .working:
            row = 1
            frameCount = 6
        case .attention:
            row = 2
            frameCount = 4
        }
        let column = index % frameCount
        let rect = CGRect(
            x: column * tileSize,
            y: row * tileSize,
            width: tileSize,
            height: tileSize
        )
        guard let cropped = image.cropping(to: rect) else {
            return NSImage(size: NSSize(width: 24, height: 24))
        }
        let result = NSImage(cgImage: cropped, size: NSSize(width: 24, height: 24))
        result.isTemplate = false
        return result
    }
}
