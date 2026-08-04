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
    sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
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
        suiteName: suiteName
    )
}

@MainActor
private struct ModelFixture {
    let model: ActivityModel
    let clock: TestDateProvider
    let notifications: NotificationRecorder
    let defaults: UserDefaults
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
