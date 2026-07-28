import Foundation
import Testing
@testable import NotchBotCore

@Test func attentionOutranksWorkingAndNotifiesOnce() {
    var reducer = ActivityReducer()
    let start = Date(timeIntervalSince1970: 100)

    reducer.apply(AgentEvent(source: .opencode, kind: .working, sessionID: "work", timestamp: start))
    let firstAttention = reducer.apply(
        AgentEvent(source: .claude, kind: .attention, sessionID: "wait", timestamp: start.addingTimeInterval(1))
    )
    let duplicateAttention = reducer.apply(
        AgentEvent(source: .claude, kind: .attention, sessionID: "wait", timestamp: start.addingTimeInterval(2))
    )

    #expect(firstAttention.state == .attention)
    #expect(firstAttention.shouldNotify)
    #expect(!duplicateAttention.shouldNotify)
    #expect(reducer.primarySession?.sessionID == "wait")
}

@Test func workingAcknowledgesAttentionForTheSameSession() {
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .attention, sessionID: "one"))
    let change = reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "one"))

    #expect(change.state == .working)
    #expect(!change.shouldNotify)
}

@Test func acknowledgingAttentionMarksPreviouslyWorkingSessionIdle() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "one", timestamp: start))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .attention,
        sessionID: "one",
        timestamp: start.addingTimeInterval(1),
        reason: "Needs permission"
    ))

    let change = reducer.acknowledgeAttention(source: .claude, sessionID: "one")

    #expect(change.state == .idle)
    #expect(reducer.primarySession?.reason == nil)
    #expect(reducer.primarySession?.state == .idle)
    #expect(reducer.sessionCount == 1)
    #expect(reducer.activeCount == 0)
}

@Test func acknowledgingStandaloneAttentionReturnsToIdle() {
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .opencode, kind: .attention, sessionID: "one"))

    let change = reducer.acknowledgeAttention(source: .opencode, sessionID: "one")

    #expect(change.state == .idle)
    #expect(reducer.sessionCount == 1)
    #expect(reducer.primarySession?.state == .idle)
}

@Test func acknowledgingFinishedWorkReturnsToIdle() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "one", timestamp: start))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .attention,
        sessionID: "one",
        timestamp: start.addingTimeInterval(1),
        reason: "Claude Code finished working",
        expiresAfter: 2.5
    ))

    let change = reducer.acknowledgeAttention(source: .claude, sessionID: "one")

    #expect(change.state == .idle)
    #expect(reducer.sessionCount == 1)
    #expect(reducer.activeCount == 0)
}

@Test func clearingSessionReturnsToIdle() {
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .opencode, kind: .working, sessionID: "one"))
    reducer.apply(AgentEvent(source: .opencode, kind: .cleared, sessionID: "one"))

    #expect(reducer.state == .idle)
    #expect(reducer.sessionCount == 0)
}

@Test func activitiesOrderAttentionBeforeWorkingAndUseSourceQualifiedIDs() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .working,
        sessionID: "shared",
        timestamp: start,
        taskLabel: "Claude task"
    ))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "shared",
        timestamp: start.addingTimeInterval(1),
        taskLabel: "OpenCode task"
    ))

    #expect(reducer.activities.map(\.taskLabel) == ["OpenCode task", "Claude task"])
    #expect(Set(reducer.activities.map(\.id)).count == 2)
}

@Test func activitiesHaveDeterministicOrderWhenTimestampsMatch() {
    let timestamp = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .opencode, kind: .working, sessionID: "z", timestamp: timestamp))
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "a", timestamp: timestamp))

    #expect(reducer.activities.map(\.id) == ["claude:a", "opencode:z"])
}

@Test func metadataOrderingDoesNotSuppressLifecycleEvents() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "one",
        timestamp: start.addingTimeInterval(2),
        taskLabel: "Task"
    ))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .working,
        sessionID: "one",
        timestamp: start.addingTimeInterval(1)
    ))

    #expect(reducer.sessionCount == 1)
    #expect(reducer.primarySession?.taskLabel == "Task")
}

@Test func unchangedAttentionCanExpireWithoutClearingNewWork() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .opencode, kind: .attention, sessionID: "one", timestamp: start))
    reducer.apply(AgentEvent(source: .opencode, kind: .working, sessionID: "one", timestamp: start.addingTimeInterval(1)))
    let change = reducer.expireAttention(source: .opencode, sessionID: "one", unchangedSince: start)

    #expect(change.state == .working)
    #expect(reducer.sessionCount == 1)
    #expect(reducer.attentionCount == 0)
}

@Test func expiringCurrentAttentionKeepsAnIdleQueueEntry() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .opencode, kind: .attention, sessionID: "one", timestamp: start))

    let change = reducer.expireAttention(source: .opencode, sessionID: "one", unchangedSince: start)

    #expect(change.state == .idle)
    #expect(reducer.sessionCount == 1)
    #expect(reducer.activeCount == 0)
    #expect(reducer.primarySession?.state == .idle)
}

@Test func summaryExcerptNormalizesWhitespaceAndTruncates() {
    let normalized = AgentSummaryText.excerpt(from: "  Finished\n\n editing\tthree files.  ")
    let truncated = AgentSummaryText.excerpt(from: String(repeating: "x", count: 300))

    #expect(normalized == "Finished editing three files.")
    #expect(truncated?.count == 240)
    #expect(truncated?.hasSuffix("...") == true)
}

@Test func summaryStoreKeepsMostRecentSummaryAfterSessionClears() {
    let start = Date(timeIntervalSince1970: 100)
    var store = AgentSummaryStore()
    store.apply(AgentEvent(
        source: .claude,
        kind: .attention,
        sessionID: "one",
        timestamp: start,
        workingDirectory: "/tmp/older",
        summary: "Older result"
    ))
    store.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "two",
        timestamp: start.addingTimeInterval(1),
        workingDirectory: "/tmp/newer",
        summary: "Newer result"
    ))
    store.apply(AgentEvent(source: .opencode, kind: .cleared, sessionID: "two"))

    #expect(store.latest?.text == "Newer result")
    #expect(store.latest?.projectName == "newer")
    #expect(store.latest?.source == .opencode)
}

@Test func taskLabelsAreNormalizedAndBounded() {
    let event = AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "one",
        taskLabel: "  Review\n  " + String(repeating: "x", count: 200)
    )
    let byteHeavy = AgentTaskLabel.normalized(String(repeating: "e\u{301}", count: 100))

    #expect(event.taskLabel?.hasPrefix("Review ") == true)
    #expect(event.taskLabel?.count == AgentTaskLabel.maximumCharacters)
    #expect(byteHeavy?.utf8.count ?? 0 <= AgentTaskLabel.maximumBytes)
    #expect(AgentTaskLabel.normalized(" \n\t ") == nil)
    #expect(AgentTaskLabel.normalized("safe\u{202e}evil") == "safeevil")
}

@Test func metadataDoesNotActivateOrNotifyAndMergesIntoActivity() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    let metadata = reducer.apply(AgentEvent(
        source: .opencode,
        kind: .metadata,
        sessionID: "one",
        timestamp: start,
        taskLabel: "First title"
    ))

    #expect(metadata.state == .idle)
    #expect(!metadata.shouldNotify)
    #expect(reducer.sessionCount == 0)
    #expect(reducer.pendingMetadataCount == 1)

    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .working,
        sessionID: "one",
        timestamp: start.addingTimeInterval(1)
    ))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .metadata,
        sessionID: "one",
        timestamp: start.addingTimeInterval(2),
        taskLabel: "Latest title"
    ))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "one",
        timestamp: start.addingTimeInterval(3)
    ))

    #expect(reducer.primarySession?.taskLabel == "Latest title")
    #expect(reducer.pendingMetadataCount == 0)
}

@Test func latestExplicitClaudeMetadataBecomesTheVisibleTaskLabel() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "one",
        timestamp: start,
        taskLabel: "Named session"
    ))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "one",
        timestamp: start.addingTimeInterval(1),
        taskLabel: "Current task"
    ))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .working,
        sessionID: "one",
        timestamp: start.addingTimeInterval(2)
    ))

    #expect(reducer.primarySession?.taskLabel == "Current task")
}

@Test func pendingMetadataClearsExpiresAndIsCapped() {
    let start = Date(timeIntervalSince1970: 1_000)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .metadata, sessionID: "clear", timestamp: start, taskLabel: "Clear"))
    reducer.apply(AgentEvent(source: .claude, kind: .cleared, sessionID: "clear", timestamp: start.addingTimeInterval(1)))
    #expect(reducer.pendingMetadataCount == 0)

    for index in 0...ActivityReducer.maximumSessions {
        reducer.apply(AgentEvent(
            source: .claude,
            kind: .metadata,
            sessionID: "pending-\(index)",
            timestamp: start.addingTimeInterval(Double(index + 2)),
            taskLabel: "Task \(index)"
        ))
    }
    #expect(reducer.pendingMetadataCount == ActivityReducer.maximumSessions)

    reducer.removeSessions(olderThan: start.addingTimeInterval(Double(ActivityReducer.maximumSessions + 2)))
    #expect(reducer.pendingMetadataCount == 1)
}
