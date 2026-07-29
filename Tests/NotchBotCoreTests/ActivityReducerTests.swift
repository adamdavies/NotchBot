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

@Test func completionAttentionIsIdentifiedIndependentlyOfExpiry() {
    let openCode = AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "one",
        reason: "OpenCode finished working",
        expiresAfter: 2.5
    )
    let claude = AgentEvent(
        source: .claude,
        kind: .attention,
        sessionID: "two",
        reason: "Claude Code finished working"
    )
    let permission = AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "three",
        reason: "OpenCode needs permission",
        expiresAfter: 2.5
    )

    #expect(openCode.isCompletionAttention)
    #expect(claude.isCompletionAttention)
    #expect(!permission.isCompletionAttention)
}

@Test func submittedPermissionLosesActionsButRetainsAttention() {
    var reducer = ActivityReducer()
    let token = String(repeating: "b", count: 32)
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "permission-session",
        reason: "OpenCode needs permission",
        permission: AgentPermissionRequest(
            responseToken: token,
            summary: "bash: npm test",
            canAlwaysAllow: true
        )
    ))

    #expect(reducer.primarySession?.permission?.responseToken == token)
    reducer.markPermissionSubmitted(
        source: .opencode,
        sessionID: "permission-session",
        responseToken: token
    )
    #expect(reducer.primarySession?.state == .attention)
    #expect(reducer.primarySession?.permission == nil)
    #expect(reducer.primarySession?.isAwaitingPermissionResolution == true)

    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .working,
        sessionID: "permission-session",
        timestamp: Date().addingTimeInterval(1)
    ))
    #expect(reducer.primarySession?.isAwaitingPermissionResolution == false)
}

@Test func actionablePermissionSurvivesFallbackAttentionAndNotifiesWhenNew() {
    let start = Date(timeIntervalSince1970: 100)
    let token = String(repeating: "c", count: 32)
    var reducer = ActivityReducer()

    let fallback = reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "permission-session",
        timestamp: start,
        reason: "OpenCode needs permission"
    ))
    let actionable = reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "permission-session",
        timestamp: start.addingTimeInterval(1),
        reason: "OpenCode needs permission",
        permission: AgentPermissionRequest(
            responseToken: token,
            summary: "Run tests",
            canAlwaysAllow: true
        )
    ))
    let duplicateFallback = reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "permission-session",
        timestamp: start.addingTimeInterval(2),
        reason: "OpenCode needs permission"
    ))

    #expect(fallback.shouldNotify)
    #expect(actionable.shouldNotify)
    #expect(!duplicateFallback.shouldNotify)
    #expect(reducer.primarySession?.permission?.responseToken == token)
    #expect(reducer.primarySession?.isAwaitingPermissionResolution == true)
}

@Test func pendingRequestKeepsAttentionAcrossLaterWorkingEvents() {
    let start = Date(timeIntervalSince1970: 100)
    let token = String(repeating: "d", count: 32)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .opencode, kind: .working, sessionID: "session", timestamp: start))
    let opened = reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "session",
        timestamp: start.addingTimeInterval(1),
        reason: "OpenCode needs permission",
        permission: AgentPermissionRequest(
            responseToken: token,
            summary: "Bash",
            canAlwaysAllow: true
        ),
        request: AgentRequestUpdate(id: "per-one", kind: .permission, state: .opened)
    ))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .working,
        sessionID: "session",
        timestamp: start.addingTimeInterval(2)
    ))

    #expect(opened.shouldNotify)
    #expect(reducer.primarySession?.state == .attention)
    #expect(reducer.primarySession?.pendingRequestCount == 1)
    #expect(reducer.primarySession?.permission?.responseToken == token)

    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .requestResolved,
        sessionID: "session",
        timestamp: start.addingTimeInterval(3),
        request: AgentRequestUpdate(id: "per-one", kind: .permission, state: .resolved)
    ))

    #expect(reducer.primarySession?.state == .working)
    #expect(reducer.primarySession?.pendingRequestCount == 0)
    #expect(reducer.primarySession?.permission == nil)
}

@Test func delayedRequestEventIsIndependentFromNewerWorkingTimestamp() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .working,
        sessionID: "session",
        timestamp: start.addingTimeInterval(2)
    ))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "session",
        timestamp: start.addingTimeInterval(1),
        reason: "OpenCode needs permission",
        permission: AgentPermissionRequest(
            responseToken: String(repeating: "9", count: 32),
            summary: "Bash",
            canAlwaysAllow: true
        ),
        request: AgentRequestUpdate(id: "per-delayed", kind: .permission, state: .opened)
    ))

    #expect(reducer.primarySession?.state == .attention)
    #expect(reducer.primarySession?.pendingRequestCount == 1)
    #expect(reducer.primarySession?.updatedAt == start.addingTimeInterval(2))
}

@Test func concurrentRequestsResolveAndPresentIndependently() {
    let start = Date(timeIntervalSince1970: 100)
    let firstToken = String(repeating: "e", count: 32)
    let secondToken = String(repeating: "f", count: 32)
    var reducer = ActivityReducer()
    let first = AgentPermissionRequest(responseToken: firstToken, summary: "Swift test", canAlwaysAllow: true)
    let second = AgentPermissionRequest(responseToken: secondToken, summary: "Git diff", canAlwaysAllow: true)

    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "session",
        timestamp: start,
        reason: "OpenCode needs permission",
        permission: first,
        request: AgentRequestUpdate(id: "per-one", kind: .permission, state: .opened)
    ))
    let secondChange = reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "session",
        timestamp: start.addingTimeInterval(1),
        reason: "OpenCode needs permission",
        permission: second,
        request: AgentRequestUpdate(id: "per-two", kind: .permission, state: .opened)
    ))

    #expect(secondChange.shouldNotify)
    #expect(reducer.primarySession?.pendingRequestCount == 2)
    #expect(reducer.primarySession?.permission?.responseToken == firstToken)

    reducer.markPermissionSubmitted(source: .opencode, sessionID: "session", responseToken: firstToken)
    #expect(reducer.primarySession?.permission?.responseToken == secondToken)
    #expect(reducer.primarySession?.pendingRequestCount == 2)

    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .requestResolved,
        sessionID: "session",
        timestamp: start.addingTimeInterval(2),
        request: AgentRequestUpdate(id: "per-one", kind: .permission, state: .resolved)
    ))
    #expect(reducer.primarySession?.state == .attention)
    #expect(reducer.primarySession?.pendingRequestCount == 1)
    #expect(reducer.primarySession?.permission?.responseToken == secondToken)
}

@Test func duplicateLogicalRequestDoesNotNotifyTwice() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    let request = AgentRequestUpdate(id: "per-one", kind: .permission, state: .opened)
    let permission = AgentPermissionRequest(
        responseToken: String(repeating: "a", count: 32),
        summary: "Bash",
        canAlwaysAllow: true
    )
    let first = reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "session",
        timestamp: start,
        reason: "OpenCode needs permission",
        permission: permission,
        request: request
    ))
    let duplicate = reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "session",
        timestamp: start.addingTimeInterval(1),
        reason: "OpenCode needs permission",
        permission: permission,
        request: request
    ))

    #expect(first.shouldNotify)
    #expect(!duplicate.shouldNotify)
    #expect(reducer.primarySession?.pendingRequestCount == 1)
}

@Test func resolvedRequestCannotBeReopenedByDelayedHelper() {
    let start = Date(timeIntervalSince1970: 100)
    let resolved = AgentRequestUpdate(id: "per-one", kind: .permission, state: .resolved)
    let opened = AgentRequestUpdate(id: "per-one", kind: .permission, state: .opened)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .requestResolved,
        sessionID: "session",
        timestamp: start,
        request: resolved
    ))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "session",
        timestamp: start.addingTimeInterval(1),
        reason: "OpenCode needs permission",
        permission: AgentPermissionRequest(
            responseToken: String(repeating: "8", count: 32),
            summary: "Bash",
            canAlwaysAllow: true
        ),
        request: opened
    ))

    #expect(reducer.sessionCount == 0)
    #expect(reducer.state == .idle)
}

@Test func olderResolutionStillClosesNewerDeliveredOpenEvent() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "session",
        timestamp: start.addingTimeInterval(2),
        reason: "OpenCode needs permission",
        request: AgentRequestUpdate(id: "per-one", kind: .permission, state: .opened)
    ))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .requestResolved,
        sessionID: "session",
        timestamp: start.addingTimeInterval(1),
        request: AgentRequestUpdate(id: "per-one", kind: .permission, state: .resolved)
    ))

    #expect(reducer.primarySession?.pendingRequestCount == 0)
    #expect(reducer.primarySession?.state == .working)
}

@Test func requestResolutionDoesNotMakePreClearChildLookNewer() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .opencode, kind: .working, sessionID: "parent", timestamp: start))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "child",
        timestamp: start.addingTimeInterval(1),
        reason: "OpenCode needs permission",
        request: AgentRequestUpdate(id: "per-one", kind: .permission, state: .opened)
    ))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .cleared,
        sessionID: "parent",
        timestamp: start.addingTimeInterval(2)
    ))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .requestResolved,
        sessionID: "child",
        timestamp: start.addingTimeInterval(3),
        request: AgentRequestUpdate(id: "per-one", kind: .permission, state: .resolved)
    ))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .metadata,
        sessionID: "child",
        parentSessionID: "parent",
        timestamp: start.addingTimeInterval(4)
    ))

    #expect(reducer.sessionCount == 0)
}

@Test func requestKindParticipatesInNotificationIdentity() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    let question = reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "session",
        timestamp: start,
        reason: "OpenCode has a question",
        request: AgentRequestUpdate(id: "shared", kind: .question, state: .opened)
    ))
    let permission = reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "session",
        timestamp: start.addingTimeInterval(1),
        reason: "OpenCode needs permission",
        permission: AgentPermissionRequest(
            responseToken: String(repeating: "7", count: 32),
            summary: "Bash",
            canAlwaysAllow: true
        ),
        request: AgentRequestUpdate(id: "shared", kind: .permission, state: .opened)
    ))

    #expect(question.shouldNotify)
    #expect(permission.shouldNotify)
    #expect(reducer.primarySession?.reason == "OpenCode needs permission")
    #expect(reducer.primarySession?.pendingRequestCount == 2)
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

@Test func hierarchyKeepsParentBeforeAttentionChildWhileChildDrivesAttention() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .working,
        sessionID: "parent",
        timestamp: start,
        taskLabel: "Main task"
    ))
    let childAttention = reducer.apply(AgentEvent(
        source: .claude,
        kind: .attention,
        sessionID: "child",
        parentSessionID: "parent",
        timestamp: start.addingTimeInterval(1),
        reason: "Needs permission",
        taskLabel: "Explore"
    ))

    #expect(reducer.activities.map(\.sessionID) == ["parent", "child"])
    #expect(reducer.activities[1].isSubagent)
    #expect(reducer.primarySession?.sessionID == "child")
    #expect(childAttention.state == .attention)
    #expect(childAttention.shouldNotify)
    #expect(reducer.activeCount == 2)
}

@Test func clearingSubagentRemovesOnlyItsSubtreeWithoutAttention() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .opencode, kind: .working, sessionID: "parent", timestamp: start))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .working,
        sessionID: "child",
        parentSessionID: "parent",
        timestamp: start.addingTimeInterval(1)
    ))

    let change = reducer.apply(AgentEvent(
        source: .opencode,
        kind: .cleared,
        sessionID: "child",
        parentSessionID: "parent",
        timestamp: start.addingTimeInterval(2)
    ))

    #expect(reducer.activities.map(\.sessionID) == ["parent"])
    #expect(change.state == .working)
    #expect(!change.shouldNotify)
    #expect(reducer.attentionCount == 0)
}

@Test func clearingParentRemovesAllDescendantsAndRejectsOlderChildEvents() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .opencode, kind: .working, sessionID: "parent", timestamp: start))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .working,
        sessionID: "child",
        parentSessionID: "parent",
        timestamp: start.addingTimeInterval(1)
    ))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .working,
        sessionID: "grandchild",
        parentSessionID: "child",
        timestamp: start.addingTimeInterval(2)
    ))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .cleared,
        sessionID: "parent",
        timestamp: start.addingTimeInterval(4)
    ))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .working,
        sessionID: "child",
        parentSessionID: "parent",
        timestamp: start.addingTimeInterval(3)
    ))

    #expect(reducer.sessionCount == 0)
    #expect(reducer.state == .idle)
}

@Test func orphanSubagentRejoinsParentAndCyclesAreDropped() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .working,
        sessionID: "child",
        parentSessionID: "parent",
        timestamp: start
    ))
    #expect(reducer.activities.map(\.sessionID) == ["child"])

    reducer.apply(AgentEvent(
        source: .claude,
        kind: .working,
        sessionID: "parent",
        parentSessionID: "child",
        timestamp: start.addingTimeInterval(1)
    ))

    #expect(reducer.activities.map(\.sessionID) == ["parent", "child"])
    #expect(reducer.activities[0].parentSessionID == nil)
    #expect(reducer.activities[1].parentSessionID == "parent")
}

@Test func parentClearRejectsDelayedPreviouslyUnseenSubagent() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "parent", timestamp: start))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .cleared,
        sessionID: "parent",
        timestamp: start.addingTimeInterval(10)
    ))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .working,
        sessionID: "late-child",
        parentSessionID: "parent",
        timestamp: start.addingTimeInterval(5)
    ))

    #expect(reducer.sessionCount == 0)
}

@Test func freshSubagentKeepsStaleParentGroupAlive() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .opencode, kind: .working, sessionID: "parent", timestamp: start))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .working,
        sessionID: "child",
        parentSessionID: "parent",
        timestamp: start.addingTimeInterval(100)
    ))

    reducer.removeSessions(olderThan: start.addingTimeInterval(50))

    #expect(reducer.activities.map(\.sessionID) == ["parent", "child"])
}

@Test func delayedMetadataCannotReparentNewerLifecycleState() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .working,
        sessionID: "child",
        timestamp: start.addingTimeInterval(10)
    ))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .metadata,
        sessionID: "child",
        parentSessionID: "old-parent",
        timestamp: start.addingTimeInterval(5),
        taskLabel: "Updated label"
    ))

    #expect(reducer.primarySession?.parentSessionID == nil)
    #expect(reducer.primarySession?.taskLabel == "Updated label")
}

@Test func delayedParentMetadataRemovesChildThatPredatesParentClear() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .opencode, kind: .working, sessionID: "parent", timestamp: start))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "child",
        timestamp: start.addingTimeInterval(1),
        reason: "OpenCode needs permission"
    ))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .cleared,
        sessionID: "parent",
        timestamp: start.addingTimeInterval(2)
    ))

    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .metadata,
        sessionID: "child",
        parentSessionID: "parent",
        timestamp: start.addingTimeInterval(3)
    ))

    #expect(reducer.sessionCount == 0)
    #expect(reducer.state == .idle)
}

@Test func parentClearRemovesPendingChildMetadata() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "child",
        parentSessionID: "parent",
        timestamp: start,
        taskLabel: "Explore"
    ))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .cleared,
        sessionID: "parent",
        timestamp: start.addingTimeInterval(1)
    ))

    #expect(reducer.pendingMetadataCount == 0)
}

@Test func rejectedIntermediateSubagentClearsPreviouslyArrivedDescendants() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .opencode, kind: .working, sessionID: "root", timestamp: start))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .cleared,
        sessionID: "root",
        timestamp: start.addingTimeInterval(10)
    ))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .working,
        sessionID: "grandchild",
        parentSessionID: "child",
        timestamp: start.addingTimeInterval(4)
    ))
    #expect(reducer.sessionCount == 1)

    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .working,
        sessionID: "child",
        parentSessionID: "root",
        timestamp: start.addingTimeInterval(5)
    ))

    #expect(reducer.sessionCount == 0)
}
