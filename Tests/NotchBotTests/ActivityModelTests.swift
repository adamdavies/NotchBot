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
    initialCompletionCount: Int? = nil
) throws -> ModelFixture {
    let suiteName = "ActivityModelTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
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
    let notifications = NotificationRecorder()
    let model = ActivityModel(
        defaults: defaults,
        calendar: calendar,
        nowProvider: { clock.now },
        sleep: sleep,
        notifications: notifications.dependencies,
        enableBackgroundMaintenance: false
    )
    return ModelFixture(
        model: model,
        clock: clock,
        notifications: notifications,
        defaults: defaults,
        calendar: calendar,
        suiteName: suiteName
    )
}

@MainActor
private struct ModelFixture {
    let model: ActivityModel
    let clock: TestDateProvider
    let notifications: NotificationRecorder
    let defaults: UserDefaults
    let calendar: Calendar
    let suiteName: String

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
    #expect(fixture.model.dailyCostAlertLevel == .exceeded)
    #expect(fixture.model.dailyCostMenuText == "Today: ~$20.00 · Alert at $10.00")
}

@Test @MainActor func disablingCostTrackingClearsAlertStateAndKeepsTheThreshold() async throws {
    let fixture = try makeModelFixture()
    defer { fixture.cleanup() }
    fixture.model.setDailyCostThreshold(10)
    fixture.model.receive(costEvent(session: "session", cost: 12, at: fixture.clock.now))
    #expect(fixture.notifications.sent.count == 1)

    NotificationCenter.default.post(name: .notchBotCostTrackingDisabled, object: nil)
    await drainScheduledTasks()

    #expect(fixture.model.dailyCostTotal == 0)
    #expect(fixture.model.dailyCostAlertLevel == .normal)
    #expect(fixture.model.dailyCostAlertThreshold == 10)

    fixture.model.receive(costEvent(
        session: "later", cost: 15, at: fixture.clock.now.addingTimeInterval(1)
    ))
    #expect(fixture.notifications.sent.count == 2)
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
