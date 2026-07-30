import Foundation
import NotchBotCore
import Testing
@testable import NotchBot

@Test @MainActor func stateAndCoolnessPreviewsAreIndependentUntilStopped() throws {
    let suiteName = "DebugPreviewTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = ActivityModel(defaults: defaults)

    model.setPreviewState(.working)
    model.setPreviewCoolnessTier(.crown)
    #expect(model.displayedRobotState == .working)
    #expect(model.displayedCoolnessTier == .crown)
    #expect(model.isPreviewing)

    model.setPreviewState(nil)
    #expect(model.displayedRobotState == model.robotState)
    #expect(model.displayedCoolnessTier == .crown)
    #expect(model.isPreviewing)

    model.cancelPreview()
    #expect(model.previewState == nil)
    #expect(model.previewCoolnessTier == nil)
    #expect(!model.isPreviewing)
}
