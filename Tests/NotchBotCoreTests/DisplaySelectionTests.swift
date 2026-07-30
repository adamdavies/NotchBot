import Foundation
import Testing
@testable import NotchBotCore

@Test func displaySelectionDefaultsToAutomaticAndRoundTrips() throws {
    let suiteName = "DisplaySelectionTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let identifier = UUID().uuidString

    #expect(DisplaySelectionPreference.load(from: defaults) == .automatic)

    DisplaySelectionPreference.save(.all, to: defaults)
    #expect(DisplaySelectionPreference.load(from: defaults) == .all)

    DisplaySelectionPreference.save(.display(identifier), to: defaults)
    #expect(DisplaySelectionPreference.load(from: defaults) == .display(identifier))

    DisplaySelectionPreference.save(.automatic, to: defaults)
    #expect(DisplaySelectionPreference.load(from: defaults) == .automatic)
}

@Test func invalidDisplaySelectionFallsBackToAutomatic() throws {
    let suiteName = "DisplaySelectionTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set("file:///tmp/not-a-display", forKey: DisplaySelectionPreference.defaultsKey)
    #expect(DisplaySelectionPreference.load(from: defaults) == .automatic)
}
