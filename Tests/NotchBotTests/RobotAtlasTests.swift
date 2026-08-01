import AppKit
import NotchBotCore
import Testing
@testable import NotchBot

@Test @MainActor func robotAtlasCachesEachLogicalFrame() throws {
    let atlas = RobotAtlas(image: try makeTestAtlasImage())
    let states: [(RobotState, Int)] = [(.idle, 4), (.working, 6), (.attention, 4)]
    var identities = Set<ObjectIdentifier>()

    for (state, frameCount) in states {
        for index in 0..<frameCount {
            let first = atlas.frame(state: state, index: index)
            let second = atlas.frame(state: state, index: index)
            #expect(first === second)
            identities.insert(ObjectIdentifier(first))
        }
    }

    #expect(identities.count == 14)
}

@Test @MainActor func robotAtlasWrapsFrameIndexesBeforeCaching() throws {
    let atlas = RobotAtlas(image: try makeTestAtlasImage())

    #expect(atlas.frame(state: .idle, index: 0) === atlas.frame(state: .idle, index: 4))
    #expect(atlas.frame(state: .working, index: 5) === atlas.frame(state: .working, index: -1))
    #expect(atlas.frame(state: .attention, index: 1) === atlas.frame(state: .attention, index: 9))
}

@Test @MainActor func robotAtlasCachesBlankFallbacks() {
    let atlas = RobotAtlas(image: nil)
    let first = atlas.frame(state: .working, index: 2)

    #expect(first === atlas.frame(state: .working, index: 2))
    #expect(first === atlas.frame(state: .working, index: 8))
    #expect(first.size == NSSize(width: 24, height: 24))
}

private func makeTestAtlasImage() throws -> CGImage {
    let context = try #require(CGContext(
        data: nil,
        width: 48 * 6,
        height: 48 * 3,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    return try #require(context.makeImage())
}
