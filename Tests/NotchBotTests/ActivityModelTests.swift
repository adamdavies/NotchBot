import Foundation
import NotchBotCore
import Testing
@testable import NotchBot

@MainActor
private final class TestDateProvider {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

@MainActor
private final class NotificationRecorder {
    var sent: [(identifier: String, title: String, body: String)] = []
    var resolved: [String] = []

    var dependencies: ActivityModelNotificationDependencies {
        ActivityModelNotificationDependencies(
            send: { [weak self] identifier, title, body in
                self?.sent.append((identifier, title, body))
            },
            resolve: { [weak self] identifier in
                self?.resolved.append(identifier)
            }
        )
    }
}

private actor ControlledSleeper {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep(_ nanoseconds: UInt64) async throws {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    var pendingCount: Int { continuations.count }

    func resumeFirst() -> Bool {
        guard !continuations.isEmpty else { return false }
        continuations.removeFirst().resume()
        return true
    }
}

@Test @MainActor func receivePublishesReducerStateAndSessionDetails() throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }

    fixture.model.receive(AgentEvent(
        source: .claude,
        kind: .working,
        sessionID: "session",
        timestamp: fixture.clock.now,
        workingDirectory: "/tmp/project",
        activityDescription: "Build app"
    ))

    #expect(fixture.model.robotState == .working)
    #expect(fixture.model.primarySession?.sessionID == "session")
    #expect(fixture.model.primarySession?.workingDirectory == "/tmp/project")
    #expect(fixture.model.primarySession?.activityDescription == "Build app")
    #expect(fixture.model.activeAgentCount == 1)
    #expect(fixture.model.waitingAgentCount == 0)
    #expect(fixture.model.activeSessions.count == 1)
}

@Test @MainActor func receiveRejectsInvalidAndOutOfOrderEventsWithoutPublication() throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }
    let latest = fixture.clock.now

    fixture.model.receive(AgentEvent(
        source: .claude, kind: .working, sessionID: "session", timestamp: latest, reason: "latest"
    ))
    fixture.model.receive(AgentEvent(
        source: .claude,
        kind: .attention,
        sessionID: "session",
        timestamp: latest.addingTimeInterval(-1),
        reason: "stale"
    ))
    fixture.model.receive(AgentEvent(
        source: .claude, kind: .attention, sessionID: "", timestamp: latest, reason: "invalid"
    ))

    #expect(fixture.model.robotState == .working)
    #expect(fixture.model.primarySession?.reason == "latest")
    #expect(fixture.model.activeSessions.count == 1)
    #expect(fixture.notifications.sent.isEmpty)
}

@Test @MainActor func receiveSendsAndResolvesRequestNotificationsOnce() throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }
    let request = AgentRequestUpdate(id: "request", kind: .question, state: .opened)

    fixture.model.receive(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "session",
        timestamp: fixture.clock.now,
        reason: "Choose an option",
        request: request
    ))
    fixture.model.receive(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "session",
        timestamp: fixture.clock.now,
        reason: "Choose an option",
        request: request
    ))

    let notification = try #require(fixture.notifications.sent.first)
    #expect(fixture.notifications.sent.count == 1)
    #expect(notification.title == "OpenCode")
    #expect(notification.body == "Choose an option")
    #expect(fixture.model.attentionSequence == 1)

    fixture.model.receive(AgentEvent(
        source: .opencode,
        kind: .requestResolved,
        sessionID: "session",
        timestamp: fixture.clock.now.addingTimeInterval(1),
        request: AgentRequestUpdate(id: "request", kind: .question, state: .resolved)
    ))

    #expect(fixture.notifications.resolved == [notification.identifier])
    #expect(fixture.model.primarySession?.pendingRequests.isEmpty == true)
    #expect(fixture.model.robotState == .working)
}

@Test @MainActor func receiveTracksProgressionAndCostAcrossDayRollover() throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }

    fixture.model.receive(AgentEvent(
        source: .claude,
        kind: .working,
        sessionID: "session",
        timestamp: fixture.clock.now
    ))
    fixture.model.receive(AgentEvent(
        source: .claude,
        kind: .attention,
        sessionID: "session",
        timestamp: fixture.clock.now.addingTimeInterval(1),
        reason: "Claude Code finished working"
    ))
    fixture.model.receive(AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "session",
        timestamp: fixture.clock.now.addingTimeInterval(2),
        costUSD: 1.25
    ))

    #expect(fixture.model.dailyCompletionCount == 1)
    #expect(fixture.model.dailyCostTotal == 1.25)

    fixture.clock.now = fixture.clock.now.addingTimeInterval(24 * 60 * 60)
    fixture.model.receive(AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "session",
        timestamp: fixture.clock.now,
        costUSD: 1.50
    ))

    #expect(fixture.model.dailyCompletionCount == 0)
    #expect(fixture.model.dailyCostTotal == 0.25)
    #expect(fixture.defaults.integer(forKey: DailyCoolnessPreference.countKey) == 0)
    #expect(fixture.defaults.double(forKey: DailyCostPreference.totalKey) == 0.25)
}

@Test @MainActor func persistedCapProgressResetsToBaseAcrossDayRollover() throws {
    let fixture = try makeModelFixture(initialCompletionCount: 150)
    defer { fixture.cleanup() }

    #expect(fixture.model.dailyCompletionCount == 150)
    #expect(fixture.model.coolnessTier == .cap)

    fixture.clock.now = fixture.clock.now.addingTimeInterval(24 * 60 * 60)
    fixture.model.receive(AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "session",
        timestamp: fixture.clock.now
    ))

    #expect(fixture.model.dailyCompletionCount == 0)
    #expect(fixture.model.coolnessTier == .base)
    #expect(fixture.defaults.integer(forKey: DailyCoolnessPreference.countKey) == 0)
}

@Test @MainActor func canceledExpiryCannotOverrideReplacementAttention() async throws {
    let sleeper = ControlledSleeper()
    let fixture = try makeModelFixture(sleep: { try await sleeper.sleep($0) })
    defer { fixture.cleanup() }
    let start = fixture.clock.now

    fixture.model.receive(AgentEvent(
        source: .claude,
        kind: .attention,
        sessionID: "session",
        timestamp: start,
        reason: "first",
        expiresAfter: 1
    ))
    #expect(await waitForPendingSleeps(1, in: sleeper))
    fixture.model.receive(AgentEvent(
        source: .claude, kind: .working, sessionID: "session", timestamp: start.addingTimeInterval(1)
    ))
    fixture.model.receive(AgentEvent(
        source: .claude,
        kind: .attention,
        sessionID: "session",
        timestamp: start.addingTimeInterval(2),
        reason: "second",
        expiresAfter: 1
    ))
    #expect(await waitForPendingSleeps(2, in: sleeper))

    #expect(await sleeper.resumeFirst())
    await drainScheduledTasks()
    #expect(fixture.model.robotState == .attention)
    #expect(fixture.model.primarySession?.reason == "second")

    #expect(await sleeper.resumeFirst())
    #expect(await waitUntil { fixture.model.robotState == .idle })
    #expect(fixture.model.robotState == .idle)
    #expect(fixture.model.primarySession?.reason == nil)
}

@Test @MainActor func clearAndShutdownCancelPendingExpiryWork() async throws {
    let sleeper = ControlledSleeper()
    let fixture = try makeModelFixture(sleep: { try await sleeper.sleep($0) })
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
    let start = fixture.clock.now

    fixture.model.receive(AgentEvent(
        source: .claude,
        kind: .attention,
        sessionID: "cleared",
        timestamp: start,
        reason: "waiting",
        expiresAfter: 1
    ))
    #expect(await waitForPendingSleeps(1, in: sleeper))
    fixture.clock.now = start.addingTimeInterval(1)
    fixture.model.clear(try #require(fixture.model.primarySession))
    #expect(await sleeper.resumeFirst())
    await drainScheduledTasks()
    #expect(fixture.model.activeSessions.isEmpty)
    #expect(fixture.model.robotState == .idle)

    fixture.model.receive(AgentEvent(
        source: .claude,
        kind: .attention,
        sessionID: "shutdown",
        timestamp: start.addingTimeInterval(2),
        reason: "waiting",
        expiresAfter: 1
    ))
    #expect(await waitForPendingSleeps(1, in: sleeper))
    fixture.model.shutdown()
    #expect(await sleeper.resumeFirst())
    await drainScheduledTasks()
    #expect(fixture.model.robotState == .attention)
    #expect(fixture.model.primarySession?.sessionID == "shutdown")
}

@MainActor
private func makeModelFixture(
    sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
    initialCompletionCount: Int? = nil,
    timelineStore: RecordingTimelineStore? = nil,
    initialSessionCosts: [String: Double]? = nil
) throws -> ModelFixture {
    let suiteName = "ActivityModelTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(true, forKey: DailyCostPreference.trackingEnabledKey)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let date = try #require(calendar.date(from: DateComponents(
        year: 2026, month: 7, day: 1, hour: 12
    )))
    let clock = TestDateProvider(date)
    if let initialCompletionCount {
        DailyCoolnessPreference.save(
            completionCount: initialCompletionCount,
            to: defaults,
            now: date,
            calendar: calendar
        )
    }
    if let initialSessionCosts {
        DailyCostPreference.save(
            totalCost: initialSessionCosts.values.reduce(0, +),
            sessionCosts: initialSessionCosts,
            alertFired: false,
            to: defaults,
            now: date,
            calendar: calendar
        )
    }
    let notifications = NotificationRecorder()
    let timelineStore = timelineStore ?? RecordingTimelineStore()
    let model = ActivityModel(
        defaults: defaults,
        calendar: calendar,
        nowProvider: { clock.now },
        sleep: sleep,
        notifications: notifications.dependencies,
        timelineStore: timelineStore,
        enableBackgroundMaintenance: false
    )
    return ModelFixture(
        model: model,
        clock: clock,
        notifications: notifications,
        defaults: defaults,
        calendar: calendar,
        suiteName: suiteName,
        timelineStore: timelineStore
    )
}

/// An in-memory stand-in for `SessionTimelineStore`. Every model fixture gets one, so no test can
/// reach the real `~/Library/Application Support/NotchBot/session-timeline.json`.
@MainActor
private final class RecordingTimelineStore: SessionTimelineStoring {
    var stored: SessionTimelineDocument?
    var saveCount = 0
    var removeCount = 0
    var saveError: (any Error)?
    var loadError: (any Error)?

    init(stored: SessionTimelineDocument? = nil) {
        self.stored = stored
    }

    func load(day: String) throws -> SessionTimelineDocument? {
        if let loadError { throw loadError }
        guard let stored, stored.day == day else { return nil }
        return stored
    }

    func save(_ document: SessionTimelineDocument) throws {
        saveCount += 1
        if let saveError { throw saveError }
        stored = document
    }

    func removeAll() throws {
        removeCount += 1
        stored = nil
    }
}

private struct TimelineStoreFailure: Error, LocalizedError {
    var errorDescription: String? { "disk is full" }
}

@MainActor
private struct ModelFixture {
    let model: ActivityModel
    let clock: TestDateProvider
    let notifications: NotificationRecorder
    let defaults: UserDefaults
    let calendar: Calendar
    let suiteName: String
    let timelineStore: RecordingTimelineStore

    func cleanup() {
        model.shutdown()
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private func waitForPendingSleeps(_ count: Int, in sleeper: ControlledSleeper) async -> Bool {
    for _ in 0..<1_000 {
        if await sleeper.pendingCount == count { return true }
        try? await Task.sleep(nanoseconds: 100_000)
    }
    return false
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        await Task.yield()
    }
    return false
}

private func drainScheduledTasks() async {
    for _ in 0..<10 { await Task.yield() }
}

@Test @MainActor func costAlertNotifiesOnceOnTheEventThatCrossesTheThreshold() throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }
    fixture.model.setDailyCostThreshold(10)

    fixture.model.receive(costEvent(session: "session", cost: 9.50, at: fixture.clock.now))
    #expect(fixture.notifications.sent.isEmpty)
    #expect(fixture.model.dailyCostAlertLevel == .warning)

    fixture.model.receive(costEvent(
        session: "session", cost: 10.02, at: fixture.clock.now.addingTimeInterval(1)
    ))
    #expect(fixture.notifications.sent.count == 1)
    #expect(fixture.notifications.sent.first?.title == "NotchBot")
    #expect(fixture.notifications.sent.first?.body == "Today's agent spend has passed $10.00")
    #expect(fixture.model.dailyCostAlertLevel == .exceeded)

    fixture.model.receive(costEvent(
        session: "session", cost: 10.40, at: fixture.clock.now.addingTimeInterval(2)
    ))
    fixture.model.receive(costEvent(
        session: "other", cost: 5.00, at: fixture.clock.now.addingTimeInterval(3)
    ))

    #expect(fixture.notifications.sent.count == 1)
    #expect(fixture.defaults.bool(forKey: DailyCostPreference.alertFiredKey))
}

@Test @MainActor func costAlertStaysSilentWhenNoThresholdIsConfigured() throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }

    fixture.model.receive(costEvent(session: "session", cost: 250, at: fixture.clock.now))

    #expect(fixture.notifications.sent.isEmpty)
    #expect(fixture.model.dailyCostAlertLevel == .normal)
    #expect(fixture.model.dailyCostThresholdDisplayText == nil)
    #expect(fixture.model.dailyCostMenuText == "Today: ~$250.00 · No cost alert set")
}

@Test @MainActor func costAlertRearmsAfterTheDailyRollover() throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }
    fixture.model.setDailyCostThreshold(10)

    fixture.model.receive(costEvent(session: "session", cost: 12, at: fixture.clock.now))
    #expect(fixture.notifications.sent.count == 1)

    fixture.clock.now = fixture.clock.now.addingTimeInterval(24 * 60 * 60)
    fixture.model.receive(costEvent(session: "session", cost: 13, at: fixture.clock.now))
    #expect(fixture.model.dailyCostTotal == 1)
    #expect(fixture.notifications.sent.count == 1)
    #expect(!fixture.defaults.bool(forKey: DailyCostPreference.alertFiredKey))

    fixture.model.receive(costEvent(
        session: "session", cost: 25, at: fixture.clock.now.addingTimeInterval(1)
    ))

    #expect(fixture.notifications.sent.count == 2)
    #expect(fixture.model.dailyCostAlertThreshold == 10)
}

@Test @MainActor func loweringTheThresholdBelowTheCurrentTotalDoesNotNotifyRetroactively() throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }
    fixture.model.setDailyCostThreshold(100)

    fixture.model.receive(costEvent(session: "session", cost: 12, at: fixture.clock.now))
    #expect(fixture.notifications.sent.isEmpty)

    fixture.model.setDailyCostThreshold(10)
    fixture.model.receive(costEvent(
        session: "session", cost: 20, at: fixture.clock.now.addingTimeInterval(1)
    ))

    #expect(fixture.notifications.sent.isEmpty)
    #expect(fixture.model.dailyCostAlertLevel == .warning)
    #expect(fixture.model.dailyCostMenuText == "Today: ~$20.00 · Alert at $10.00")
}

@Test @MainActor func disablingCostTrackingClearsAlertStateAndIgnoresLaterCostEvents() async throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }
    fixture.model.setDailyCostThreshold(10)
    fixture.model.receive(costEvent(session: "session", cost: 12, at: fixture.clock.now))
    #expect(fixture.notifications.sent.count == 1)

    fixture.defaults.set(false, forKey: DailyCostPreference.trackingEnabledKey)
    DailyCostPreference.clear(from: fixture.defaults)
    NotificationCenter.default.post(
        name: .notchBotCostTrackingDisabled,
        object: fixture.defaults
    )
    await drainScheduledTasks()

    #expect(fixture.model.dailyCostTotal == 0)
    #expect(fixture.model.dailyCostAlertLevel == .normal)
    #expect(fixture.model.dailyCostAlertThreshold == 0)
    #expect(DailyCostPreference.loadThreshold(from: fixture.defaults) == 0)

    fixture.model.receive(costEvent(
        session: "later", cost: 15, at: fixture.clock.now.addingTimeInterval(1)
    ))
    #expect(fixture.model.dailyCostTotal == 0)
    #expect(fixture.notifications.sent.count == 1)

    fixture.defaults.set(true, forKey: DailyCostPreference.trackingEnabledKey)
    NotificationCenter.default.post(
        name: .notchBotCostTrackingEnabled,
        object: fixture.defaults
    )
    fixture.model.receive(costEvent(
        session: "session", cost: 13, at: fixture.clock.now.addingTimeInterval(2)
    ))
    #expect(fixture.model.dailyCostTotal == 1)
    #expect(fixture.notifications.sent.count == 1)
}

@Test @MainActor func costThresholdSurvivesAModelRestart() throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }
    fixture.model.setDailyCostThreshold(10)
    fixture.model.receive(costEvent(session: "session", cost: 12, at: fixture.clock.now))
    fixture.model.shutdown()

    let restarted = ActivityModel(
        defaults: fixture.defaults,
        calendar: fixture.calendar,
        nowProvider: { [clock = fixture.clock] in clock.now },
        notifications: fixture.notifications.dependencies,
        enableBackgroundMaintenance: false
    )
    defer { restarted.shutdown() }

    #expect(restarted.dailyCostAlertThreshold == 10)
    #expect(restarted.dailyCostTotal == 12)
    restarted.receive(costEvent(
        session: "session", cost: 20, at: fixture.clock.now.addingTimeInterval(1)
    ))

    #expect(fixture.notifications.sent.count == 1)
}

@Test @MainActor func contextUsageReachesActiveSessionsAndIsNeverPersisted() throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }

    fixture.model.receive(AgentEvent(
        source: .claude, kind: .working, sessionID: "session", timestamp: fixture.clock.now
    ))
    fixture.model.receive(contextEvent(
        session: "session", percentage: 82, at: fixture.clock.now.addingTimeInterval(1)
    ))
    #expect(fixture.model.activeSessions.first?.contextUsedPercentage == 82)

    // Usage is process memory only: nothing about it may reach the defaults suite.
    let persisted = fixture.defaults.dictionaryRepresentation()
    #expect(!persisted.keys.contains { $0.lowercased().contains("context") })

    fixture.model.shutdown()
    let restarted = ActivityModel(
        defaults: fixture.defaults,
        calendar: fixture.calendar,
        nowProvider: { [clock = fixture.clock] in clock.now },
        notifications: fixture.notifications.dependencies,
        timelineStore: fixture.timelineStore
    )
    defer { restarted.shutdown() }
    #expect(restarted.activeSessions.isEmpty)
}

@Test @MainActor func disablingTrackingTakesContextMetersOffScreenImmediately() async throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }

    fixture.model.receive(AgentEvent(
        source: .opencode, kind: .working, sessionID: "session", timestamp: fixture.clock.now
    ))
    fixture.model.receive(contextEvent(
        session: "session", percentage: 91, at: fixture.clock.now.addingTimeInterval(1),
        source: .opencode
    ))
    #expect(fixture.model.activeSessions.first?.contextUsedPercentage == 91)

    fixture.defaults.set(false, forKey: DailyCostPreference.trackingEnabledKey)
    NotificationCenter.default.post(
        name: .notchBotCostTrackingDisabled,
        object: fixture.defaults
    )
    await drainScheduledTasks()

    // The row survives; only the percentage goes.
    #expect(fixture.model.activeSessions.count == 1)
    #expect(fixture.model.activeSessions.first?.contextUsedPercentage == nil)

    // A provider session that has not restarted can still run the previously loaded integration.
    // Its late metadata must not restore context presentation after the user opted out.
    fixture.model.receive(contextEvent(
        session: "session", percentage: 95, at: fixture.clock.now.addingTimeInterval(2),
        source: .opencode
    ))
    #expect(fixture.model.activeSessions.first?.contextUsedPercentage == nil)
}

private func contextEvent(
    session: String,
    percentage: Double?,
    at timestamp: Date,
    source: AgentSource = .claude
) -> AgentEvent {
    AgentEvent(
        source: source,
        kind: .metadata,
        sessionID: session,
        timestamp: timestamp,
        contextWindow: ContextWindowUsageUpdate(usedPercentage: percentage)
    )
}

@MainActor
private func costEvent(session: String, cost: Double, at timestamp: Date) -> AgentEvent {
    AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: session,
        timestamp: timestamp,
        costUSD: cost
    )
}

// MARK: - Session timeline

@MainActor
private func completionEvent(
    _ sessionID: String,
    source: AgentSource = .claude,
    at timestamp: Date
) -> AgentEvent {
    AgentEvent(
        source: source,
        kind: .attention,
        sessionID: sessionID,
        timestamp: timestamp,
        reason: source == .claude ? "Claude Code finished working" : "OpenCode finished working"
    )
}

@Test @MainActor func aCompletedSessionIsPublishedAndPersisted() throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }
    let start = fixture.clock.now

    fixture.model.receive(AgentEvent(
        source: .claude, kind: .working, sessionID: "s", timestamp: start, sessionTitle: "Refactor auth"
    ))
    fixture.model.receive(completionEvent("s", at: start.addingTimeInterval(300)))

    #expect(fixture.model.completedSessionsToday.count == 1)
    #expect(fixture.model.todayCompletedRowCount == 1)
    #expect(fixture.model.hasTodayHistory)
    let row = try #require(fixture.model.completedSessionsToday.first?.parent)
    #expect(row.title == "Refactor auth")
    #expect(row.duration == 300)
    #expect(fixture.timelineStore.stored?.sessions.count == 1)
    #expect(fixture.model.timelineStorageError == nil)
}

@Test @MainActor func aStoredTimelineIsLoadedForTheCurrentDayOnly() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 12)))
    let day = DailyCoolnessPreference.dayIdentifier(for: today, calendar: calendar)
    let row = CompletedSession(
        cycleID: "claude:s:1",
        source: .claude,
        sessionID: "s",
        groupID: "s",
        title: "Earlier work",
        startedAt: today.addingTimeInterval(-3_600),
        endedAt: today.addingTimeInterval(-3_000),
        costUSD: 0.5
    )

    let sameDay = try makeModelFixture(
        timelineStore: RecordingTimelineStore(stored: SessionTimelineDocument(day: day, sessions: [row]))
    )
    defer { sameDay.cleanup() }
    #expect(sameDay.model.completedSessionsToday.count == 1)
    #expect(sameDay.model.completedSessionsToday.first?.parent.title == "Earlier work")

    let otherDay = try makeModelFixture(
        timelineStore: RecordingTimelineStore(
            stored: SessionTimelineDocument(day: "1-2026-6-30", sessions: [row])
        )
    )
    defer { otherDay.cleanup() }
    #expect(otherDay.model.completedSessionsToday.isEmpty)
}

@Test @MainActor func theTimelineClearsAtTheSameRolloverAsTheDailyTotals() throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }
    let start = fixture.clock.now

    fixture.model.receive(AgentEvent(source: .claude, kind: .working, sessionID: "s", timestamp: start))
    fixture.model.receive(costEvent(session: "s", cost: 2, at: start.addingTimeInterval(1)))
    fixture.model.receive(completionEvent("s", at: start.addingTimeInterval(2)))
    #expect(fixture.model.completedSessionsToday.count == 1)
    #expect(fixture.model.dailyCompletionCount == 1)
    #expect(fixture.model.dailyCostTotal == 2)

    // The next day's first event trips the shared rollover.
    fixture.clock.now = start.addingTimeInterval(24 * 60 * 60)
    fixture.model.receive(AgentEvent(
        source: .claude, kind: .working, sessionID: "next", timestamp: fixture.clock.now
    ))

    #expect(fixture.model.completedSessionsToday.isEmpty)
    #expect(fixture.model.dailyCompletionCount == 0)
    #expect(fixture.model.dailyCostTotal == 0)
    // The stale document is removed from disk, not just from memory.
    #expect(fixture.timelineStore.stored == nil)
    #expect(fixture.timelineStore.removeCount >= 1)
}

@Test @MainActor func aSessionCrossingMidnightLandsInTheDayItCompleted() throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }
    let start = fixture.clock.now

    fixture.model.receive(AgentEvent(source: .claude, kind: .working, sessionID: "s", timestamp: start))
    fixture.clock.now = start.addingTimeInterval(24 * 60 * 60)
    fixture.model.receive(completionEvent("s", at: fixture.clock.now))

    // The rollover ran first, then the completion was recorded into the new day.
    #expect(fixture.model.completedSessionsToday.count == 1)
    #expect(fixture.timelineStore.stored?.day
        == DailyCoolnessPreference.dayIdentifier(for: fixture.clock.now, calendar: fixture.calendar))
}

@Test @MainActor func aStorageFailureIsReportedWithoutDisturbingTheQueue() throws {
    let store = RecordingTimelineStore()
    store.saveError = TimelineStoreFailure()
    let fixture = try makeModelFixture(timelineStore: store)
    defer { fixture.cleanup() }
    let start = fixture.clock.now

    fixture.model.receive(AgentEvent(source: .claude, kind: .working, sessionID: "s", timestamp: start))
    fixture.model.receive(completionEvent("s", at: start.addingTimeInterval(60)))

    #expect(fixture.model.timelineStorageError == "disk is full")
    // The row is still on screen and the live queue is untouched.
    #expect(fixture.model.completedSessionsToday.count == 1)
    #expect(fixture.model.activeSessions.count == 1)
    #expect(fixture.model.robotState == .attention)
}

@Test @MainActor func aLoadFailureLeavesAnEmptyTimelineAndReportsIt() throws {
    let store = RecordingTimelineStore()
    store.loadError = TimelineStoreFailure()
    let fixture = try makeModelFixture(timelineStore: store)
    defer { fixture.cleanup() }

    #expect(fixture.model.completedSessionsToday.isEmpty)
    #expect(fixture.model.timelineStorageError == "disk is full")
}

@Test @MainActor func manuallyClearingARowRecordsNothingButKeepsEarlierCompletions() throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }
    let start = fixture.clock.now

    fixture.model.receive(AgentEvent(source: .claude, kind: .working, sessionID: "done", timestamp: start))
    fixture.model.receive(completionEvent("done", at: start.addingTimeInterval(60)))
    fixture.model.receive(AgentEvent(
        source: .opencode, kind: .working, sessionID: "busy", timestamp: start.addingTimeInterval(70)
    ))
    #expect(fixture.model.completedSessionsToday.count == 1)

    // Dismissing the still-working row adds nothing.
    let busy = try #require(fixture.model.activeSessions.first { $0.sessionID == "busy" })
    fixture.model.clear(busy)
    #expect(fixture.model.completedSessionsToday.count == 1)
    #expect(!fixture.model.activeSessions.contains { $0.sessionID == "busy" })

    // Dismissing the completed row leaves its already-archived cycle in Today.
    let done = try #require(fixture.model.activeSessions.first { $0.sessionID == "done" })
    fixture.model.clear(done)
    #expect(fixture.model.completedSessionsToday.count == 1)
    #expect(fixture.model.activeSessions.isEmpty)
}

@Test @MainActor func clearAllRecordsNothing() throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }
    let start = fixture.clock.now

    fixture.model.receive(AgentEvent(source: .claude, kind: .working, sessionID: "a", timestamp: start))
    fixture.model.receive(AgentEvent(source: .opencode, kind: .working, sessionID: "b", timestamp: start))
    fixture.model.clearAllSessions()

    #expect(fixture.model.activeSessions.isEmpty)
    #expect(fixture.model.completedSessionsToday.isEmpty)
    #expect(fixture.timelineStore.stored == nil)
}

@Test @MainActor func staleCleanupRecordsNothing() throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }
    let start = fixture.clock.now

    fixture.model.receive(AgentEvent(source: .claude, kind: .working, sessionID: "s", timestamp: start))
    fixture.clock.now = start.addingTimeInterval(60 * 60)
    fixture.model.performMaintenance()

    #expect(fixture.model.activeSessions.isEmpty)
    #expect(fixture.model.completedSessionsToday.isEmpty)
}

@Test @MainActor func aProviderSessionEndRecordsAnUncompletedCycle() throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }
    let start = fixture.clock.now

    fixture.model.receive(AgentEvent(
        source: .opencode, kind: .working, sessionID: "s", timestamp: start, sessionTitle: "Build"
    ))
    fixture.model.receive(AgentEvent(
        source: .opencode, kind: .cleared, sessionID: "s", timestamp: start.addingTimeInterval(120)
    ))

    #expect(fixture.model.completedSessionsToday.count == 1)
    #expect(fixture.model.completedSessionsToday.first?.parent.title == "Build")
    #expect(fixture.model.completedSessionsToday.first?.parent.duration == 120)
}

@Test @MainActor func subagentsGroupUnderTheirParentInToday() throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }
    let start = fixture.clock.now

    fixture.model.receive(AgentEvent(
        source: .claude, kind: .working, sessionID: "parent", timestamp: start, sessionTitle: "refactor"
    ))
    fixture.model.receive(AgentEvent(
        source: .claude,
        kind: .working,
        sessionID: "child",
        parentSessionID: "parent",
        timestamp: start.addingTimeInterval(10),
        sessionTitle: "migrate-tests"
    ))
    fixture.model.receive(AgentEvent(
        source: .claude, kind: .cleared, sessionID: "child", timestamp: start.addingTimeInterval(200)
    ))
    fixture.model.receive(completionEvent("parent", at: start.addingTimeInterval(300)))

    #expect(fixture.model.completedSessionsToday.count == 1)
    let group = try #require(fixture.model.completedSessionsToday.first)
    #expect(group.parent.title == "refactor")
    #expect(group.subagents.map(\.title) == ["migrate-tests"])
    #expect(group.rowCount == 2)
    #expect(fixture.model.todayCompletedRowCount == 2)
}

@Test @MainActor func costTrackingOptOutStripsCostsFromRowsAlreadyInToday() async throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }
    let start = fixture.clock.now

    fixture.model.receive(AgentEvent(source: .claude, kind: .working, sessionID: "s", timestamp: start))
    fixture.model.receive(costEvent(session: "s", cost: 1.5, at: start.addingTimeInterval(1)))
    fixture.model.receive(completionEvent("s", at: start.addingTimeInterval(2)))
    #expect(fixture.model.completedSessionsToday.first?.parent.costUSD == 1.5)

    fixture.defaults.set(false, forKey: DailyCostPreference.trackingEnabledKey)
    NotificationCenter.default.post(name: .notchBotCostTrackingDisabled, object: fixture.defaults)
    await drainScheduledTasks()

    // The row survives; the figure does not, and it reads as untracked rather than free.
    #expect(fixture.model.completedSessionsToday.count == 1)
    #expect(fixture.model.completedSessionsToday.first?.parent.costUSD == nil)
    #expect(fixture.timelineStore.stored?.hasObservedCost == false)
}

@Test @MainActor func aCycleCompletedAfterOptingOutCarriesNoCost() async throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }
    let start = fixture.clock.now

    fixture.model.receive(AgentEvent(source: .claude, kind: .working, sessionID: "s", timestamp: start))
    fixture.model.receive(costEvent(session: "s", cost: 4, at: start.addingTimeInterval(1)))

    fixture.defaults.set(false, forKey: DailyCostPreference.trackingEnabledKey)
    NotificationCenter.default.post(name: .notchBotCostTrackingDisabled, object: fixture.defaults)
    await drainScheduledTasks()

    fixture.model.receive(completionEvent("s", at: start.addingTimeInterval(10)))

    #expect(fixture.model.completedSessionsToday.count == 1)
    #expect(fixture.model.completedSessionsToday.first?.parent.costUSD == nil)
}

@Test @MainActor func removingIntegrationsClearsTodayWithoutRewritingTheFile() async throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }
    let start = fixture.clock.now

    fixture.model.receive(AgentEvent(source: .claude, kind: .working, sessionID: "s", timestamp: start))
    fixture.model.receive(completionEvent("s", at: start.addingTimeInterval(60)))
    let savesBefore = fixture.timelineStore.saveCount
    #expect(fixture.model.completedSessionsToday.count == 1)

    NotificationCenter.default.post(name: .notchBotIntegrationsRemoved, object: fixture.defaults)
    await drainScheduledTasks()

    #expect(fixture.model.completedSessionsToday.isEmpty)
    #expect(fixture.model.timelineStorageError == nil)
    // The installer already deleted the file; recreating an empty one would undo that.
    #expect(fixture.timelineStore.saveCount == savesBefore)
    #expect(fixture.timelineStore.removeCount == 0)
}

@Test @MainActor func theTodayPillFallsBackToARunCountWhenNothingWasTracked() throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }
    let start = fixture.clock.now

    #expect(!fixture.model.hasTodayHistory)

    fixture.model.receive(AgentEvent(source: .claude, kind: .working, sessionID: "a", timestamp: start))
    fixture.model.receive(completionEvent("a", at: start.addingTimeInterval(60)))

    #expect(fixture.model.dailyCostTotal == 0)
    #expect(fixture.model.hasTodayHistory)
    #expect(fixture.model.todayPillText == "1 run today")

    fixture.model.receive(AgentEvent(
        source: .opencode, kind: .working, sessionID: "b", timestamp: start.addingTimeInterval(70)
    ))
    fixture.model.receive(completionEvent("b", source: .opencode, at: start.addingTimeInterval(130)))
    #expect(fixture.model.todayPillText == "2 runs today")

    fixture.model.receive(costEvent(session: "a", cost: 3.25, at: start.addingTimeInterval(140)))
    #expect(fixture.model.todayPillText == "~$3.25 today")
}

@Test @MainActor func aSessionResumedAfterARestartRecordsOnlyItsNewSpend() throws {
    // The persisted per-session baseline is what survives a restart; the daily total also reloads.
    let fixture = try makeModelFixture(initialSessionCosts: ["claude:resumed": 25.80])
    defer { fixture.cleanup() }
    let start = fixture.clock.now
    #expect(fixture.model.dailyCostTotal == 25.80)

    fixture.model.receive(AgentEvent(
        source: .claude, kind: .working, sessionID: "resumed", timestamp: start, sessionTitle: "Long run"
    ))
    fixture.model.receive(costEvent(session: "resumed", cost: 25.95, at: start.addingTimeInterval(5)))
    fixture.model.receive(completionEvent("resumed", at: start.addingTimeInterval(12)))

    let row = try #require(fixture.model.completedSessionsToday.first?.parent)
    #expect(row.duration == 12)
    // The 12-second cycle is charged 15 cents, not the whole $25.95 running total.
    #expect(abs((row.costUSD ?? -1) - 0.15) < 0.000_001)
    // The daily total still tracks the provider's cumulative figure.
    #expect(abs(fixture.model.dailyCostTotal - 25.95) < 0.000_001)
}

@Test @MainActor func aSessionFirstSeenAfterARestartWithNoNewSpendRecordsZeroNotItsTotal() throws {
    let fixture = try makeModelFixture(initialSessionCosts: ["claude:resumed": 25.80])
    defer { fixture.cleanup() }
    let start = fixture.clock.now

    fixture.model.receive(AgentEvent(
        source: .claude, kind: .working, sessionID: "resumed", timestamp: start
    ))
    // The provider repeats the same running total: nothing accrued while NotchBot watched.
    fixture.model.receive(costEvent(session: "resumed", cost: 25.80, at: start.addingTimeInterval(2)))
    fixture.model.receive(completionEvent("resumed", at: start.addingTimeInterval(8)))

    #expect(fixture.model.completedSessionsToday.first?.parent.costUSD == 0)
}
