import Foundation
import Testing
@testable import NotchBotCore

@Test func coolnessTiersUseDailyRunThresholds() {
    #expect(CoolnessTier(completionCount: 0) == .base)
    #expect(CoolnessTier(completionCount: 24) == .base)
    #expect(CoolnessTier(completionCount: 25) == .glow)
    #expect(CoolnessTier(completionCount: 49) == .glow)
    #expect(CoolnessTier(completionCount: 50) == .shades)
    #expect(CoolnessTier(completionCount: 99) == .shades)
    #expect(CoolnessTier(completionCount: 100) == .crown)
}

@Test func dailyCoolnessCountsEachTopLevelWorkCycleOnce() {
    var tracker = DailyCoolnessTracker()
    let completion = AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "session",
        reason: "OpenCode finished working"
    )

    let firstCompletion = tracker.apply(completion, isTopLevel: true)
    let duplicateCompletion = tracker.apply(completion, isTopLevel: true)
    #expect(firstCompletion)
    #expect(!duplicateCompletion)
    #expect(tracker.completionCount == 1)

    let working = tracker.apply(
        AgentEvent(source: .opencode, kind: .working, sessionID: "session"),
        isTopLevel: true
    )
    let secondCompletion = tracker.apply(completion, isTopLevel: true)
    #expect(!working)
    #expect(secondCompletion)
    #expect(tracker.completionCount == 2)
}

@Test func dailyCoolnessIgnoresChildrenAndNonCompletionAttention() {
    var tracker = DailyCoolnessTracker()

    let permission = tracker.apply(
        AgentEvent(
            source: .opencode,
            kind: .attention,
            sessionID: "permission",
            reason: "OpenCode needs permission"
        ),
        isTopLevel: true
    )
    let clearedChild = tracker.apply(
        AgentEvent(
            source: .claude,
            kind: .cleared,
            sessionID: "child",
            parentSessionID: "parent"
        ),
        isTopLevel: false
    )
    let completedChild = tracker.apply(
        AgentEvent(
            source: .opencode,
            kind: .attention,
            sessionID: "child",
            parentSessionID: "parent",
            reason: "OpenCode finished working"
        ),
        isTopLevel: false
    )
    #expect(!permission)
    #expect(!clearedChild)
    #expect(!completedChild)
    #expect(tracker.completionCount == 0)
}

@Test func dailyCoolnessKeepsProvidersIndependent() {
    var tracker = DailyCoolnessTracker()
    let openCode = AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "shared",
        reason: "OpenCode finished working"
    )
    let claude = AgentEvent(
        source: .claude,
        kind: .attention,
        sessionID: "shared",
        reason: "Claude Code finished working"
    )

    let openCodeCompletion = tracker.apply(openCode, isTopLevel: true)
    let claudeCompletion = tracker.apply(claude, isTopLevel: true)
    #expect(openCodeCompletion)
    #expect(claudeCompletion)
    #expect(tracker.completionCount == 2)
}

@Test func dailyCoolnessPreferencePersistsOnlyCurrentLocalDay() throws {
    let suiteName = "DailyCoolnessTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let now = try #require(calendar.date(from: DateComponents(
        year: 2026,
        month: 3,
        day: 8,
        hour: 23,
        minute: 30
    )))

    DailyCoolnessPreference.save(completionCount: 72, to: defaults, now: now, calendar: calendar)
    #expect(DailyCoolnessPreference.load(from: defaults, now: now, calendar: calendar) == 72)

    let nextDay = try #require(calendar.date(byAdding: .hour, value: 2, to: now))
    #expect(DailyCoolnessPreference.load(from: defaults, now: nextDay, calendar: calendar) == 0)
    let persistedKeys = try #require(defaults.persistentDomain(forName: suiteName)).keys
    #expect(Set(persistedKeys) == [
        DailyCoolnessPreference.dayKey,
        DailyCoolnessPreference.countKey,
    ])
}

@Test func invalidDailyCoolnessPreferenceFailsClosed() throws {
    let suiteName = "DailyCoolnessTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let now = Date()
    let calendar = Calendar(identifier: .gregorian)

    let tomorrow = try #require(calendar.date(byAdding: .day, value: 1, to: now))
    defaults.set(
        DailyCoolnessPreference.dayIdentifier(for: tomorrow, calendar: calendar),
        forKey: DailyCoolnessPreference.dayKey
    )
    defaults.set(101, forKey: DailyCoolnessPreference.countKey)
    #expect(DailyCoolnessPreference.load(from: defaults, now: now, calendar: calendar) == 0)

    defaults.set(
        DailyCoolnessPreference.dayIdentifier(for: now, calendar: calendar),
        forKey: DailyCoolnessPreference.dayKey
    )
    defaults.set(-1, forKey: DailyCoolnessPreference.countKey)
    #expect(DailyCoolnessPreference.load(from: defaults, now: now, calendar: calendar) == 0)
}

@Test func rememberedHierarchyPreventsParentlessChildCompletionFromCounting() {
    var reducer = ActivityReducer()
    var tracker = DailyCoolnessTracker()
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .metadata,
        sessionID: "child",
        parentSessionID: "parent",
        taskLabel: "Child"
    ))
    let completion = AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "child",
        reason: "OpenCode finished working"
    )
    reducer.apply(completion)
    let isTopLevel = reducer.activity(source: .opencode, sessionID: "child")?.isSubagent == false

    let counted = tracker.apply(completion, isTopLevel: isTopLevel)
    #expect(!counted)
    #expect(tracker.completionCount == 0)
}

@Test func dailyCoolnessDeduplicationBoundFailsClosed() {
    var tracker = DailyCoolnessTracker()
    for index in 0..<DailyCoolnessTracker.maximumTrackedSessions {
        let counted = tracker.apply(
            AgentEvent(
                source: .opencode,
                kind: .attention,
                sessionID: "session-\(index)",
                reason: "OpenCode finished working"
            ),
            isTopLevel: true
        )
        #expect(counted)
    }

    let overflow = tracker.apply(
        AgentEvent(
            source: .opencode,
            kind: .attention,
            sessionID: "overflow",
            reason: "OpenCode finished working"
        ),
        isTopLevel: true
    )
    #expect(!overflow)
    #expect(tracker.completionCount == DailyCoolnessTracker.maximumTrackedSessions)
}
