import Foundation
import Testing
@testable import NotchBotCore

@Test func characterPreferenceDefaultsToRetroAndRoundTrips() throws {
    let suiteName = "NotchCharacterTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(NotchCharacterPreference.load(from: defaults) == .retro)

    NotchCharacterPreference.save(.blob, to: defaults)
    #expect(NotchCharacterPreference.load(from: defaults) == .blob)

    NotchCharacterPreference.save(.orb, to: defaults)
    #expect(NotchCharacterPreference.load(from: defaults) == .orb)

    NotchCharacterPreference.save(.cat, to: defaults)
    #expect(NotchCharacterPreference.load(from: defaults) == .cat)
}

@Test func invalidCharacterPreferenceFallsBackToRetro() throws {
    let suiteName = "NotchCharacterTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set("file:///tmp/untrusted-character", forKey: NotchCharacterPreference.defaultsKey)
    #expect(NotchCharacterPreference.load(from: defaults) == .retro)
    #expect(NotchCharacter.allCases.map(\.displayName) == ["Retro Bot", "Blob Bot", "Orb Bot", "Cat Bot"])
}
