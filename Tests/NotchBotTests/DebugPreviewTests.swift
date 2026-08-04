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
    model.setPreviewCoolnessTier(.cap)
    #expect(model.displayedRobotState == .working)
    #expect(model.displayedCoolnessTier == .cap)
    #expect(model.isPreviewing)

    model.setPreviewState(nil)
    #expect(model.displayedRobotState == model.robotState)
    #expect(model.displayedCoolnessTier == .cap)
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
    #expect(crownModel.queueCoolnessProgress == 0)
    #expect(crownModel.queueCoolnessProgressText == "0%")
    #expect(crownModel.coolnessStatusText == "100 completed runs · Crown · 50 to Cap")

    DailyCoolnessPreference.save(completionCount: 125, to: defaults, now: now, calendar: calendar)
    let midCrownModel = ActivityModel(defaults: defaults, calendar: calendar, now: now)
    defer { midCrownModel.shutdown() }
    #expect(midCrownModel.coolnessTier == .crown)
    #expect(midCrownModel.queueCoolnessProgress == 0.5)
    #expect(midCrownModel.queueCoolnessProgressText == "50%")
    #expect(midCrownModel.coolnessStatusText == "125 completed runs · Crown · 25 to Cap")

    DailyCoolnessPreference.save(completionCount: 149, to: defaults, now: now, calendar: calendar)
    let nearCapModel = ActivityModel(defaults: defaults, calendar: calendar, now: now)
    defer { nearCapModel.shutdown() }
    #expect(nearCapModel.coolnessTier == .crown)
    #expect(nearCapModel.queueCoolnessProgress == 0.98)
    #expect(nearCapModel.queueCoolnessProgressText == "98%")
    #expect(nearCapModel.coolnessStatusText == "149 completed runs · Crown · 1 to Cap")

    DailyCoolnessPreference.save(completionCount: 150, to: defaults, now: now, calendar: calendar)
    let capModel = ActivityModel(defaults: defaults, calendar: calendar, now: now)
    defer { capModel.shutdown() }
    #expect(capModel.dailyCompletionCount == 150)
    #expect(capModel.coolnessTier == .cap)
    #expect(capModel.queueCoolnessProgress == 1)
    #expect(capModel.queueCoolnessProgressText == "Max level")
    #expect(capModel.coolnessStatusText == "150 completed runs · Cap")
}
