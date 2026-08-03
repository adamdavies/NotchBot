import Foundation
import NotchBotCore
import Testing
@testable import NotchBot

@Test @MainActor func stateAndCoolnessPreviewsAreIndependentUntilStopped() throws {
    let suiteName = "DebugPreviewTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = ActivityModel(defaults: defaults)
    defer { model.shutdown() }

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

@Test @MainActor func queueCoolnessProgressDescribesTheCurrentTierInterval() throws {
    let suiteName = "QueueCoolnessProgressTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let now = Date()
    let calendar = Calendar.current

    DailyCoolnessPreference.save(completionCount: 35, to: defaults, now: now, calendar: calendar)
    let glowModel = ActivityModel(defaults: defaults, calendar: calendar, now: now)
    defer { glowModel.shutdown() }
    #expect(glowModel.coolnessTier == .glow)
    #expect(glowModel.queueCoolnessProgress == 0.4)
    #expect(glowModel.queueCoolnessProgressText == "40%")

    DailyCoolnessPreference.save(completionCount: 100, to: defaults, now: now, calendar: calendar)
    let crownModel = ActivityModel(defaults: defaults, calendar: calendar, now: now)
    defer { crownModel.shutdown() }
    #expect(crownModel.coolnessTier == .crown)
    #expect(crownModel.queueCoolnessProgress == 1)
    #expect(crownModel.queueCoolnessProgressText == "Max level")
}
