import Foundation
import Testing
@testable import NotchBotCore

@Test func dailyCostTracksLatestCumulativeValuePerSession() {
    var tracker = DailyCostTracker()

    let first = tracker.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "s1", costUSD: 0.05
    ))
    #expect(first)
    #expect(tracker.totalCost == 0.05)

    let update = tracker.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "s1", costUSD: 0.12
    ))
    #expect(update)
    #expect(abs(tracker.totalCost - 0.12) < 0.001)
}

@Test func dailyCostRejectsSameOrLowerValue() {
    var tracker = DailyCostTracker()
    tracker.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "s1", costUSD: 0.10
    ))

    let same = tracker.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "s1", costUSD: 0.10
    ))
    let lower = tracker.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "s1", costUSD: 0.05
    ))
    #expect(!same)
    #expect(!lower)
    #expect(tracker.totalCost == 0.10)
}

@Test func dailyCostSumsAcrossSessions() {
    var tracker = DailyCostTracker()
    tracker.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "s1", costUSD: 1.00
    ))
    tracker.apply(AgentEvent(
        source: .opencode, kind: .metadata, sessionID: "s2", costUSD: 2.50
    ))
    #expect(abs(tracker.totalCost - 3.50) < 0.001)
}

@Test func dailyCostKeepsProvidersIndependent() {
    var tracker = DailyCostTracker()
    tracker.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "shared", costUSD: 1.00
    ))
    tracker.apply(AgentEvent(
        source: .opencode, kind: .metadata, sessionID: "shared", costUSD: 2.00
    ))
    #expect(abs(tracker.totalCost - 3.00) < 0.001)
}

@Test func dailyCostKeepsProviderGenerationsIndependent() {
    var tracker = DailyCostTracker()
    tracker.apply(AgentEvent(
        source: .opencode, kind: .metadata, sessionID: "s1",
        costUSD: 1.00, costGeneration: "first"
    ))
    tracker.apply(AgentEvent(
        source: .opencode, kind: .metadata, sessionID: "s1",
        costUSD: 0.25, costGeneration: "second"
    ))

    #expect(tracker.totalCost == 1.25)
}

@Test func dailyCostIgnoresEventsWithoutCost() {
    var tracker = DailyCostTracker()
    let noCost = tracker.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "s1"
    ))
    #expect(!noCost)
    #expect(tracker.totalCost == 0)
}

@Test func dailyCostRejectsInvalidValues() {
    var tracker = DailyCostTracker()
    let negative = tracker.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "s1", costUSD: -1.0
    ))
    let infinite = tracker.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "s2", costUSD: .infinity
    ))
    let nan = tracker.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "s3", costUSD: .nan
    ))
    #expect(!negative)
    #expect(!infinite)
    #expect(!nan)
    #expect(tracker.totalCost == 0)
}

@Test func dailyCostResetClearsAllState() {
    var tracker = DailyCostTracker()
    tracker.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "s1", costUSD: 5.00
    ))
    tracker.apply(AgentEvent(
        source: .opencode, kind: .metadata, sessionID: "s2", costUSD: 3.00
    ))
    tracker.reset()
    #expect(tracker.totalCost == 0)

    let afterReset = tracker.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "s1", costUSD: 0.01
    ))
    #expect(afterReset)
    #expect(tracker.totalCost == 0.01)
}

@Test func dailyCostNewDayRetainsCumulativeBaselines() {
    var tracker = DailyCostTracker()
    tracker.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "s1", costUSD: 5.00
    ))

    tracker.beginNewDay()
    #expect(tracker.totalCost == 0)
    #expect(tracker.sessionCosts["claude:s1"] == 5.00)

    tracker.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "s1", costUSD: 5.25
    ))
    #expect(tracker.totalCost == 0.25)
}

@Test func dailyCostDropsBaselinesNotSeenDuringPreviousDay() {
    var tracker = DailyCostTracker(sessionCosts: ["claude:old": 1.00])

    tracker.beginNewDay()
    #expect(tracker.sessionCosts["claude:old"] == 1.00)
    tracker.beginNewDay()
    #expect(tracker.sessionCosts.isEmpty)
}

@Test func dailyCostOverflowFailsClosed() {
    var tracker = DailyCostTracker()
    for index in 0..<DailyCostTracker.maximumTrackedSessions {
        let applied = tracker.apply(AgentEvent(
            source: .claude, kind: .metadata, sessionID: "s-\(index)", costUSD: 0.01
        ))
        #expect(applied)
    }

    let overflow = tracker.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "overflow", costUSD: 0.01
    ))
    #expect(!overflow)
}

@Test func dailyCostPreferencePersistsOnlyCurrentDay() throws {
    let suiteName = "DailyCostTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let now = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 3, day: 8, hour: 23, minute: 30
    )))

    let sessions: [String: Double] = ["claude:s1": 1.50, "opencode:s2": 2.30]
    DailyCostPreference.save(
        totalCost: 3.80, sessionCosts: sessions, alertFired: false,
        to: defaults, now: now, calendar: calendar
    )
    let loaded = DailyCostPreference.load(from: defaults, now: now, calendar: calendar)
    #expect(abs(loaded.totalCost - 3.80) < 0.001)
    #expect(loaded.sessionCosts.count == 2)
    #expect(loaded.sessionCosts["claude:s1"] == 1.50)

    let nextDay = try #require(calendar.date(byAdding: .hour, value: 2, to: now))
    let rolled = DailyCostPreference.load(from: defaults, now: nextDay, calendar: calendar)
    #expect(rolled.totalCost == 0)
    #expect(rolled.sessionCosts == sessions)
}

@Test func dailyCostPreferenceRejectsInvalidData() throws {
    let suiteName = "DailyCostTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let now = Date()
    let calendar = Calendar(identifier: .gregorian)

    defaults.set(
        DailyCoolnessPreference.dayIdentifier(for: now, calendar: calendar),
        forKey: DailyCostPreference.dayKey
    )
    defaults.set(-5.0, forKey: DailyCostPreference.totalKey)
    let loaded = DailyCostPreference.load(from: defaults, now: now, calendar: calendar)
    #expect(loaded.totalCost == 0)
}

@Test func dailyCostPreferenceCanBeCleared() throws {
    let suiteName = "DailyCostClearTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let now = Date()
    let calendar = Calendar(identifier: .gregorian)
    DailyCostPreference.save(
        totalCost: 1.25,
        sessionCosts: ["claude:s1": 1.25],
        alertFired: true,
        to: defaults,
        now: now,
        calendar: calendar
    )
    DailyCostPreference.saveThreshold(10, to: defaults)

    DailyCostPreference.clear(from: defaults)

    #expect(defaults.object(forKey: DailyCostPreference.dayKey) == nil)
    #expect(defaults.object(forKey: DailyCostPreference.totalKey) == nil)
    #expect(defaults.object(forKey: DailyCostPreference.sessionsKey) == nil)
    #expect(defaults.object(forKey: DailyCostPreference.alertFiredKey) == nil)
    // The configured threshold survives a cost-tracking disable/re-enable round trip.
    #expect(DailyCostPreference.loadThreshold(from: defaults) == 10)
}

@Test func dailyCostInitializesFromPersistedSessionCosts() {
    let sessions: [String: Double] = ["claude:s1": 1.00, "opencode:s2": 2.00]
    var tracker = DailyCostTracker(totalCost: 3.00, sessionCosts: sessions)

    let duplicate = tracker.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "s1", costUSD: 0.50
    ))
    #expect(!duplicate)

    let update = tracker.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "s1", costUSD: 1.50
    ))
    #expect(update)
    #expect(abs(tracker.totalCost - 3.50) < 0.001)
}

@Test func dailyCostAlertFiresOnceWhenTheThresholdIsCrossed() {
    var alert = DailyCostAlert(threshold: 10)

    let below = alert.evaluate(total: 9.99)
    let crossing = alert.evaluate(total: 10.02)
    let after = alert.evaluate(total: 10.40)
    let later = alert.evaluate(total: 11.00)

    #expect(!below)
    #expect(crossing)
    #expect(!after)
    #expect(!later)
    #expect(alert.hasFired)
}

@Test func dailyCostAlertStaysSilentWhenDisabled() {
    var alert = DailyCostAlert(threshold: 0)

    let fired = alert.evaluate(total: 500)

    #expect(!fired)
    #expect(!alert.hasFired)
}

@Test func dailyCostAlertDoesNotFireRetroactivelyWhenLowered() {
    var alert = DailyCostAlert(threshold: 100)
    let beforeLowering = alert.evaluate(total: 12)

    alert.setThreshold(10, currentTotal: 12)
    let atSameTotal = alert.evaluate(total: 12)
    let afterMoreSpend = alert.evaluate(total: 20)

    #expect(!beforeLowering)
    #expect(alert.hasFired)
    #expect(!atSameTotal)
    #expect(!afterMoreSpend)
}

@Test func dailyCostAlertRearmsWhenRaisedAboveTheCurrentTotal() {
    var alert = DailyCostAlert(threshold: 10)
    let firstCrossing = alert.evaluate(total: 12)

    alert.setThreshold(25, currentTotal: 12)
    let belowNewThreshold = alert.evaluate(total: 20)
    let atNewThreshold = alert.evaluate(total: 25)

    #expect(firstCrossing)
    #expect(!belowNewThreshold)
    #expect(atNewThreshold)
}

@Test func dailyCostAlertResetsWithTheDay() {
    var alert = DailyCostAlert(threshold: 10)
    let yesterday = alert.evaluate(total: 15)

    alert.beginNewDay()
    let today = alert.evaluate(total: 10)

    #expect(yesterday)
    #expect(alert.threshold == 10)
    #expect(today)
}

@Test func dailyCostAlertSanitizesThresholds() {
    #expect(DailyCostAlert.sanitize(-5) == 0)
    #expect(DailyCostAlert.sanitize(.nan) == 0)
    #expect(DailyCostAlert.sanitize(.infinity) == 0)
    #expect(DailyCostAlert.sanitize(1_000_000) == DailyCostAlert.maximumThreshold)
    #expect(DailyCostAlert.sanitize(10.005) == 10.01)
    #expect(DailyCostAlert(threshold: -1).isEnabled == false)
    #expect(DailyCostAlert(threshold: 0, hasFired: true).hasFired == false)
}

@Test func dailyCostAlertLevelEscalatesAtEightyPercentAndAtTheThreshold() {
    let alert = DailyCostAlert(threshold: 10)

    #expect(alert.level(total: 0) == .normal)
    #expect(alert.level(total: 7.99) == .normal)
    #expect(alert.level(total: 8) == .warning)
    #expect(alert.level(total: 9.99) == .warning)
    #expect(alert.level(total: 10) == .exceeded)
    #expect(alert.level(total: 40) == .exceeded)
    #expect(DailyCostAlert(threshold: 0).level(total: 40) == .normal)
}

@Test func dailyCostAlertParsesPlainCurrencyAmounts() {
    let locale = Locale(identifier: "en_US")

    #expect(DailyCostAlert.parseThreshold("10", locale: locale) == 10)
    #expect(DailyCostAlert.parseThreshold("10.50", locale: locale) == 10.50)
    #expect(DailyCostAlert.parseThreshold("$10.50", locale: locale) == 10.50)
    #expect(DailyCostAlert.parseThreshold(" 1,250.00 ", locale: locale) == 1_250)
    #expect(DailyCostAlert.parseThreshold("", locale: locale) == 0)
    #expect(DailyCostAlert.parseThreshold("   ", locale: locale) == 0)
    #expect(DailyCostAlert.parseThreshold("free", locale: locale) == 0)
    #expect(DailyCostAlert.parseThreshold("-5", locale: locale) == 5)
}

@Test func dailyCostPreferenceScopesTheFiredFlagToTheDayAndNotTheThreshold() throws {
    let suiteName = "DailyCostAlertPreferenceTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 12)))

    DailyCostPreference.saveThreshold(12.345, to: defaults)
    DailyCostPreference.save(
        totalCost: 15,
        sessionCosts: ["claude:s1": 15],
        alertFired: true,
        to: defaults,
        now: now,
        calendar: calendar
    )

    let sameDay = DailyCostPreference.load(from: defaults, now: now, calendar: calendar)
    #expect(sameDay.alertFired)
    #expect(sameDay.totalCost == 15)

    let nextDay = DailyCostPreference.load(
        from: defaults,
        now: now.addingTimeInterval(24 * 60 * 60),
        calendar: calendar
    )
    #expect(!nextDay.alertFired)
    #expect(nextDay.totalCost == 0)
    #expect(DailyCostPreference.loadThreshold(from: defaults) == 12.35)
}
