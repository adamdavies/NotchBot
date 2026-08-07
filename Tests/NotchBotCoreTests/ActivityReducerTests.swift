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

@Test func clearingOneSessionKeepsUnrelatedActivity() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "one", timestamp: start))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "two",
        timestamp: start.addingTimeInterval(1)
    ))

    let change = reducer.apply(AgentEvent(
        source: .opencode,
        kind: .cleared,
        sessionID: "two",
        timestamp: start.addingTimeInterval(2)
    ))

    #expect(change.state == .working)
    #expect(change.primarySession?.id == "claude:one")
    #expect(reducer.activities.map(\.id) == ["claude:one"])
    #expect(reducer.activeCount == 1)
    #expect(reducer.attentionCount == 0)
}

@Test func activitiesOrderAttentionBeforeWorkingAndUseSourceQualifiedIDs() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .working,
        sessionID: "shared",
        timestamp: start,
        activityDescription: "Claude task"
    ))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "shared",
        timestamp: start.addingTimeInterval(1),
        activityDescription: "OpenCode task"
    ))

    #expect(reducer.activities.map(\.activityDescription) == ["OpenCode task", "Claude task"])
    #expect(Set(reducer.activities.map(\.key)).count == 2)
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
        activityDescription: "Task"
    ))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .working,
        sessionID: "one",
        timestamp: start.addingTimeInterval(1)
    ))

    #expect(reducer.sessionCount == 1)
    #expect(reducer.primarySession?.activityDescription == "Task")
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

@Test func acknowledgingPendingQuestionRetainsRequestWithoutAttention() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "session",
        timestamp: start,
        reason: "OpenCode has a question",
        request: AgentRequestUpdate(id: "question-one", kind: .question, state: .opened)
    ))

    let acknowledged = reducer.acknowledgeAttention(source: .opencode, sessionID: "session")

    #expect(acknowledged.state == .idle)
    #expect(reducer.primarySession?.state == .idle)
    #expect(reducer.primarySession?.reason == "OpenCode has a question")
    #expect(reducer.primarySession?.pendingRequestCount == 1)
    #expect(reducer.primarySession?.isAwaitingPermissionResolution == true)

    let duplicate = reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "session",
        timestamp: start.addingTimeInterval(1),
        reason: "OpenCode has a question",
        request: AgentRequestUpdate(id: "question-one", kind: .question, state: .opened)
    ))

    #expect(duplicate.state == .idle)
    #expect(!duplicate.shouldNotify)
    #expect(reducer.primarySession?.pendingRequestCount == 1)
}

@Test func newRequestRestoresAttentionAfterCurrentRequestsAreAcknowledged() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "session",
        timestamp: start,
        reason: "First question",
        request: AgentRequestUpdate(id: "question-one", kind: .question, state: .opened)
    ))
    reducer.acknowledgeAttention(source: .opencode, sessionID: "session")

    let second = reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "session",
        timestamp: start.addingTimeInterval(1),
        reason: "Second question",
        request: AgentRequestUpdate(id: "question-two", kind: .question, state: .opened)
    ))

    #expect(second.state == .attention)
    #expect(second.shouldNotify)
    #expect(reducer.primarySession?.pendingRequestCount == 2)
}

@Test func acknowledgingLegacyPermissionRetainsItsActionsWithoutAttention() {
    let token = String(repeating: "1", count: 32)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .attention,
        sessionID: "session",
        reason: "Claude Code needs permission",
        permission: AgentPermissionRequest(
            responseToken: token,
            summary: "Bash",
            canAlwaysAllow: true
        )
    ))

    reducer.acknowledgeAttention(source: .claude, sessionID: "session")

    #expect(reducer.primarySession?.state == .idle)
    #expect(reducer.primarySession?.permission?.responseToken == token)
    #expect(reducer.primarySession?.isAwaitingPermissionResolution == true)
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

@Test func presentationTextIsNormalizedAndBounded() {
    let event = AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "one",
        activityDescription: "  Review\n  " + String(repeating: "x", count: 200)
    )
    let byteHeavy = AgentPresentationText.normalized(String(repeating: "e\u{301}", count: 100))

    #expect(event.activityDescription?.hasPrefix("Review ") == true)
    #expect(event.activityDescription?.count == AgentPresentationText.maximumCharacters)
    #expect(byteHeavy?.utf8.count ?? 0 <= AgentPresentationText.maximumBytes)
    #expect(AgentPresentationText.normalized(" \n\t ") == nil)
    #expect(AgentPresentationText.normalized("safe\u{202e}evil") == "safeevil")
}

@Test func metadataDoesNotActivateOrNotifyAndMergesIntoActivity() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    let metadata = reducer.apply(AgentEvent(
        source: .opencode,
        kind: .metadata,
        sessionID: "one",
        timestamp: start,
        sessionTitle: "First title"
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
        sessionTitle: "Latest title"
    ))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "one",
        timestamp: start.addingTimeInterval(3)
    ))

    #expect(reducer.primarySession?.sessionTitle == "Latest title")
    #expect(reducer.pendingMetadataCount == 0)
}

@Test func claudeSessionTitleAndCurrentActivityRemainSeparate() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "one",
        timestamp: start,
        sessionTitle: "Named session"
    ))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "one",
        timestamp: start.addingTimeInterval(1),
        activityDescription: "Current task"
    ))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .working,
        sessionID: "one",
        timestamp: start.addingTimeInterval(2)
    ))

    #expect(reducer.primarySession?.sessionTitle == "Named session")
    #expect(reducer.primarySession?.activityDescription == "Current task")
}

@Test func activityUpdatesAreNonEmptyRetainedAndOrderedForBothProviders() {
    for source in [AgentSource.claude, .opencode] {
        let start = Date(timeIntervalSince1970: 100)
        var reducer = ActivityReducer()
        reducer.apply(AgentEvent(
            source: source,
            kind: .working,
            sessionID: "one",
            timestamp: start,
            sessionTitle: "Stable session",
            activityDescription: "First activity"
        ))
        reducer.apply(AgentEvent(
            source: source,
            kind: .working,
            sessionID: "one",
            timestamp: start.addingTimeInterval(1)
        ))
        reducer.apply(AgentEvent(
            source: source,
            kind: .metadata,
            sessionID: "one",
            timestamp: start.addingTimeInterval(3),
            activityDescription: "Newest activity"
        ))
        reducer.apply(AgentEvent(
            source: source,
            kind: .working,
            sessionID: "one",
            timestamp: start.addingTimeInterval(2),
            activityDescription: "Delayed activity"
        ))
        reducer.apply(AgentEvent(
            source: source,
            kind: .metadata,
            sessionID: "one",
            timestamp: start.addingTimeInterval(4),
            activityDescription: "  \n "
        ))

        #expect(reducer.primarySession?.sessionTitle == "Stable session")
        #expect(reducer.primarySession?.activityDescription == "Newest activity")
    }
}

@Test func parentAndSubagentActivityUpdateIndependentlyForBothProviders() {
    for source in [AgentSource.claude, .opencode] {
        let start = Date(timeIntervalSince1970: 100)
        var reducer = ActivityReducer()
        reducer.apply(AgentEvent(
            source: source,
            kind: .working,
            sessionID: "parent",
            timestamp: start,
            activityDescription: "Parent first"
        ))
        reducer.apply(AgentEvent(
            source: source,
            kind: .working,
            sessionID: "child",
            parentSessionID: "parent",
            timestamp: start.addingTimeInterval(1),
            activityDescription: "Child first"
        ))
        reducer.apply(AgentEvent(
            source: source,
            kind: .metadata,
            sessionID: "child",
            parentSessionID: "parent",
            timestamp: start.addingTimeInterval(2),
            activityDescription: "Child latest"
        ))

        #expect(reducer.activities.map(\.sessionID) == ["parent", "child"])
        #expect(reducer.activities[0].activityDescription == "Parent first")
        #expect(reducer.activities[1].activityDescription == "Child latest")
    }
}

@Test func pendingMetadataClearsExpiresAndIsCapped() {
    let start = Date(timeIntervalSince1970: 1_000)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .metadata, sessionID: "clear", timestamp: start, sessionTitle: "Clear"))
    reducer.apply(AgentEvent(source: .claude, kind: .cleared, sessionID: "clear", timestamp: start.addingTimeInterval(1)))
    #expect(reducer.pendingMetadataCount == 0)

    for index in 0...ActivityReducer.maximumSessions {
        reducer.apply(AgentEvent(
            source: .claude,
            kind: .metadata,
            sessionID: "pending-\(index)",
            timestamp: start.addingTimeInterval(Double(index + 2)),
            sessionTitle: "Task \(index)"
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
        activityDescription: "Main task"
    ))
    let childAttention = reducer.apply(AgentEvent(
        source: .claude,
        kind: .attention,
        sessionID: "child",
        parentSessionID: "parent",
        timestamp: start.addingTimeInterval(1),
        reason: "Needs permission",
        activityDescription: "Explore"
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
        activityDescription: "Updated label"
    ))

    #expect(reducer.primarySession?.parentSessionID == nil)
    #expect(reducer.primarySession?.activityDescription == "Updated label")
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
        activityDescription: "Explore"
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

@Test func metadataCostUsesLatestSessionEstimate() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .claude, kind: .working, sessionID: "session", timestamp: start
    ))
    reducer.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "session",
        timestamp: start.addingTimeInterval(1), costUSD: 0.05
    ))

    #expect(reducer.primarySession?.costUSD == 0.05)

    reducer.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "session",
        timestamp: start.addingTimeInterval(2), costUSD: 0.12
    ))
    #expect(reducer.primarySession?.costUSD == 0.12)

    reducer.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "session",
        timestamp: start.addingTimeInterval(3), costUSD: 0.08
    ))
    #expect(reducer.primarySession?.costUSD == 0.08)
}

@Test func metadataContextUsageReplacesClearsAndPreserves() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .opencode, kind: .working, sessionID: "session", timestamp: start
    ))
    #expect(reducer.primarySession?.contextUsedPercentage == nil)

    reducer.apply(AgentEvent(
        source: .opencode, kind: .metadata, sessionID: "session",
        timestamp: start.addingTimeInterval(1),
        contextWindow: ContextWindowUsageUpdate(usedPercentage: 61)
    ))
    #expect(reducer.primarySession?.contextUsedPercentage == 61)

    // Metadata with no usage update must not disturb the stored figure.
    reducer.apply(AgentEvent(
        source: .opencode, kind: .metadata, sessionID: "session",
        timestamp: start.addingTimeInterval(2), costUSD: 0.4
    ))
    #expect(reducer.primarySession?.contextUsedPercentage == 61)

    // Compaction legitimately moves the number down.
    reducer.apply(AgentEvent(
        source: .opencode, kind: .metadata, sessionID: "session",
        timestamp: start.addingTimeInterval(3),
        contextWindow: ContextWindowUsageUpdate(usedPercentage: 12)
    ))
    #expect(reducer.primarySession?.contextUsedPercentage == 12)

    // An explicit retraction empties it.
    reducer.apply(AgentEvent(
        source: .opencode, kind: .metadata, sessionID: "session",
        timestamp: start.addingTimeInterval(4), contextWindow: .unavailable
    ))
    #expect(reducer.primarySession?.contextUsedPercentage == nil)
}

@Test func contextUsageArrivingBeforeLifecycleMergesIntoTheSession() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()

    reducer.apply(AgentEvent(
        source: .opencode, kind: .metadata, sessionID: "session", timestamp: start,
        contextWindow: ContextWindowUsageUpdate(usedPercentage: 77)
    ))
    #expect(reducer.sessionCount == 0)
    #expect(reducer.pendingMetadataCount == 1)

    reducer.apply(AgentEvent(
        source: .opencode, kind: .working, sessionID: "session",
        timestamp: start.addingTimeInterval(1)
    ))
    #expect(reducer.primarySession?.contextUsedPercentage == 77)
}

/// Usage is metadata: it must not make a session look freshly active, or a quiet session would
/// never age out while its provider kept reporting a percentage.
@Test func contextUsageDoesNotRefreshLifecycleTimestamps() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .claude, kind: .working, sessionID: "session", timestamp: start
    ))
    reducer.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "session",
        timestamp: start.addingTimeInterval(60),
        contextWindow: ContextWindowUsageUpdate(usedPercentage: 90)
    ))

    #expect(reducer.primarySession?.updatedAt == start)
    reducer.removeSessions(olderThan: start.addingTimeInterval(30))
    #expect(reducer.sessionCount == 0)
}

@Test func contextUsageIsTrackedPerSessionAcrossParentAndSubagent() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .opencode, kind: .working, sessionID: "root", timestamp: start
    ))
    reducer.apply(AgentEvent(
        source: .opencode, kind: .working, sessionID: "child", parentSessionID: "root",
        timestamp: start.addingTimeInterval(1)
    ))
    reducer.apply(AgentEvent(
        source: .opencode, kind: .metadata, sessionID: "root",
        timestamp: start.addingTimeInterval(2),
        contextWindow: ContextWindowUsageUpdate(usedPercentage: 30)
    ))
    reducer.apply(AgentEvent(
        source: .opencode, kind: .metadata, sessionID: "child",
        timestamp: start.addingTimeInterval(3),
        contextWindow: ContextWindowUsageUpdate(usedPercentage: 85)
    ))

    #expect(reducer.activity(source: .opencode, sessionID: "root")?.contextUsedPercentage == 30)
    #expect(reducer.activity(source: .opencode, sessionID: "child")?.contextUsedPercentage == 85)

    // Clearing one leaves the other alone.
    reducer.apply(AgentEvent(
        source: .opencode, kind: .metadata, sessionID: "child",
        timestamp: start.addingTimeInterval(4), contextWindow: .unavailable
    ))
    #expect(reducer.activity(source: .opencode, sessionID: "root")?.contextUsedPercentage == 30)
    #expect(reducer.activity(source: .opencode, sessionID: "child")?.contextUsedPercentage == nil)
}

@Test func clearingContextUsageEmptiesLiveAndPendingState() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .claude, kind: .working, sessionID: "live", timestamp: start
    ))
    reducer.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "live",
        timestamp: start.addingTimeInterval(1),
        contextWindow: ContextWindowUsageUpdate(usedPercentage: 95)
    ))
    reducer.apply(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "pending",
        timestamp: start.addingTimeInterval(2),
        contextWindow: ContextWindowUsageUpdate(usedPercentage: 55)
    ))

    reducer.clearContextWindowUsage()

    #expect(reducer.activity(source: .claude, sessionID: "live")?.contextUsedPercentage == nil)
    reducer.apply(AgentEvent(
        source: .claude, kind: .working, sessionID: "pending",
        timestamp: start.addingTimeInterval(3)
    ))
    #expect(reducer.activity(source: .claude, sessionID: "pending")?.contextUsedPercentage == nil)
}

@Test func clearingASessionDropsItsContextUsage() {
    let start = Date(timeIntervalSince1970: 100)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .opencode, kind: .working, sessionID: "session", timestamp: start
    ))
    reducer.apply(AgentEvent(
        source: .opencode, kind: .metadata, sessionID: "session",
        timestamp: start.addingTimeInterval(1),
        contextWindow: ContextWindowUsageUpdate(usedPercentage: 70)
    ))
    reducer.apply(AgentEvent(
        source: .opencode, kind: .cleared, sessionID: "session",
        timestamp: start.addingTimeInterval(2)
    ))
    #expect(reducer.sessionCount == 0)

    reducer.apply(AgentEvent(
        source: .opencode, kind: .working, sessionID: "session",
        timestamp: start.addingTimeInterval(3)
    ))
    #expect(reducer.primarySession?.contextUsedPercentage == nil)
}

@Test func resolvedRequestClearsStaleProviderReason() {
    var reducer = ActivityReducer()
    let start = Date(timeIntervalSince1970: 100)

    reducer.apply(AgentEvent(source: .opencode, kind: .working, sessionID: "s1", timestamp: start))
    reducer.apply(AgentEvent(
        source: .opencode, kind: .attention, sessionID: "s1",
        timestamp: start.addingTimeInterval(1),
        reason: "OpenCode needs permission",
        request: AgentRequestUpdate(id: "r1", kind: .permission, state: .opened)
    ))
    #expect(reducer.primarySession?.state == .attention)
    #expect(reducer.primarySession?.reason == "OpenCode needs permission")

    reducer.apply(AgentEvent(
        source: .opencode, kind: .requestResolved, sessionID: "s1",
        timestamp: start.addingTimeInterval(2),
        request: AgentRequestUpdate(id: "r1", kind: .permission, state: .resolved)
    ))
    #expect(reducer.primarySession?.state == .working)
    #expect(reducer.primarySession?.reason == nil)
    #expect(reducer.primarySession?.permission == nil)
}

@Test func sessionKeyIdentityIsSourceScopedAndTextuallyStable() {
    let claude = SessionKey(source: .claude, sessionID: "abc")
    let openCode = SessionKey(source: .opencode, sessionID: "abc")
    #expect(claude != openCode)
    #expect(claude == SessionKey(source: .claude, sessionID: "abc"))
    // DailyCoolness persists this string; changing it would orphan stored progress.
    #expect(claude.rawValue == "claude:abc")
    #expect(openCode.rawValue == "opencode:abc")
    #expect(claude < openCode)
    #expect(SessionKey(event: AgentEvent(source: .opencode, kind: .working, sessionID: "abc")) == openCode)
}

// MARK: - Session timeline cycles

private let cycleStart = Date(timeIntervalSince1970: 1_780_000_000)

private func completion(_ sessionID: String, source: AgentSource = .claude, at offset: TimeInterval) -> AgentEvent {
    AgentEvent(
        source: source,
        kind: .attention,
        sessionID: sessionID,
        timestamp: cycleStart.addingTimeInterval(offset),
        reason: source == .claude ? "Claude Code finished working" : "OpenCode finished working"
    )
}

@Test func aCycleStartsOnFirstProviderActivityAndIsMeasuredToItsCompletion() {
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "s", timestamp: cycleStart))
    let change = reducer.apply(completion("s", at: 600))

    let recorded = try? #require(change.completedSessions.first)
    #expect(change.completedSessions.count == 1)
    #expect(recorded?.sessionID == "s")
    #expect(recorded?.startedAt == cycleStart)
    #expect(recorded?.endedAt == cycleStart.addingTimeInterval(600))
    #expect(recorded?.duration == 600)
    #expect(recorded?.groupID == "s")
    #expect(recorded?.parentSessionID == nil)
    // No cost metadata was ever seen, so the row carries no cost rather than a zero.
    #expect(recorded?.costUSD == nil)
}

@Test func aCompletionWithoutObservedWorkRecordsAZeroDurationCycle() {
    var reducer = ActivityReducer()
    let change = reducer.apply(completion("s", at: 30))

    #expect(change.completedSessions.count == 1)
    #expect(change.completedSessions.first?.duration == 0)
    #expect(change.completedSessions.first?.startedAt == cycleStart.addingTimeInterval(30))
}

@Test func repeatedCompletionAttentionRecordsTheCycleOnlyOnce() {
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "s", timestamp: cycleStart))
    let first = reducer.apply(completion("s", at: 100))
    let second = reducer.apply(completion("s", at: 200))

    #expect(first.completedSessions.count == 1)
    #expect(second.completedSessions.isEmpty)
}

@Test func clearingAnAlreadyCompletedSessionDoesNotRecordItTwice() {
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "s", timestamp: cycleStart))
    reducer.apply(completion("s", at: 100))
    let cleared = reducer.apply(AgentEvent(
        source: .claude, kind: .cleared, sessionID: "s", timestamp: cycleStart.addingTimeInterval(200)
    ))

    #expect(cleared.completedSessions.isEmpty)
}

@Test func workingAfterACompletionStartsASecondCycleWithItsOwnRow() {
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "s", timestamp: cycleStart))
    let first = reducer.apply(completion("s", at: 100))
    reducer.apply(AgentEvent(
        source: .claude, kind: .working, sessionID: "s", timestamp: cycleStart.addingTimeInterval(500)
    ))
    let second = reducer.apply(completion("s", at: 800))

    #expect(first.completedSessions.first?.startedAt == cycleStart)
    #expect(second.completedSessions.count == 1)
    #expect(second.completedSessions.first?.startedAt == cycleStart.addingTimeInterval(500))
    #expect(second.completedSessions.first?.duration == 300)
    // Two runs of one session are two rows, not one overwritten row.
    #expect(first.completedSessions.first?.cycleID != second.completedSessions.first?.cycleID)
}

@Test func aPermissionRequestDoesNotResetTheCycleStart() {
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "s", timestamp: cycleStart))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "s",
        timestamp: cycleStart.addingTimeInterval(60),
        request: AgentRequestUpdate(id: "r1", kind: .permission, state: .opened)
    ))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .requestResolved,
        sessionID: "s",
        timestamp: cycleStart.addingTimeInterval(120),
        request: AgentRequestUpdate(id: "r1", kind: .permission, state: .resolved)
    ))
    let change = reducer.apply(completion("s", at: 300))

    #expect(change.completedSessions.first?.startedAt == cycleStart)
    #expect(change.completedSessions.first?.duration == 300)
}

@Test func metadataDoesNotResetTheCycleStart() {
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "s", timestamp: cycleStart))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "s",
        timestamp: cycleStart.addingTimeInterval(60),
        sessionTitle: "Refactor auth"
    ))
    let change = reducer.apply(completion("s", at: 300))

    #expect(change.completedSessions.first?.startedAt == cycleStart)
    #expect(change.completedSessions.first?.title == "Refactor auth")
}

@Test func clearingASubagentRecordsItUnderItsParentsGroup() {
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "parent", timestamp: cycleStart))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .working,
        sessionID: "child",
        parentSessionID: "parent",
        timestamp: cycleStart.addingTimeInterval(30)
    ))
    let change = reducer.apply(AgentEvent(
        source: .claude, kind: .cleared, sessionID: "child", timestamp: cycleStart.addingTimeInterval(200)
    ))

    #expect(change.completedSessions.count == 1)
    #expect(change.completedSessions.first?.sessionID == "child")
    #expect(change.completedSessions.first?.parentSessionID == "parent")
    // The group still points at the live parent, so the two rows join up in Today.
    #expect(change.completedSessions.first?.groupID == "parent")
}

@Test func clearingAParentRecordsTheWholeUnarchivedSubtree() {
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "parent", timestamp: cycleStart))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .working,
        sessionID: "child",
        parentSessionID: "parent",
        timestamp: cycleStart.addingTimeInterval(30)
    ))
    let change = reducer.apply(AgentEvent(
        source: .claude, kind: .cleared, sessionID: "parent", timestamp: cycleStart.addingTimeInterval(400)
    ))

    #expect(Set(change.completedSessions.map(\.sessionID)) == ["parent", "child"])
    #expect(change.completedSessions.allSatisfy { $0.groupID == "parent" })
}

@Test func manualDismissalRecordsNothing() {
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "s", timestamp: cycleStart))
    let change = reducer.dismiss(source: .claude, sessionID: "s", at: cycleStart.addingTimeInterval(100))

    #expect(change.completedSessions.isEmpty)
    #expect(reducer.sessionCount == 0)
    // Still guarded against a late provider event resurrecting the row.
    #expect(!reducer.canApply(AgentEvent(
        source: .claude, kind: .working, sessionID: "s", timestamp: cycleStart.addingTimeInterval(50)
    )))
}

@Test func dismissAllClearsEveryRowWithoutRecordingAny() {
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "a", timestamp: cycleStart))
    reducer.apply(AgentEvent(source: .opencode, kind: .working, sessionID: "b", timestamp: cycleStart))
    let change = reducer.dismissAll(at: cycleStart.addingTimeInterval(10))

    #expect(change.completedSessions.isEmpty)
    #expect(reducer.sessionCount == 0)
    #expect(change.state == .idle)
}

@Test func staleCleanupAndAttentionExpiryRecordNothing() {
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .attention,
        sessionID: "s",
        timestamp: cycleStart,
        reason: "waiting",
        expiresAfter: 30
    ))
    let expiry = reducer.expireAttention(source: .claude, sessionID: "s", unchangedSince: cycleStart)
    #expect(expiry.completedSessions.isEmpty)

    reducer.removeSessions(olderThan: cycleStart.addingTimeInterval(3_600))
    #expect(reducer.sessionCount == 0)
}

@Test func aDelayedEventForAClearedParentRecordsNothing() {
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "parent", timestamp: cycleStart))
    reducer.apply(AgentEvent(
        source: .claude, kind: .cleared, sessionID: "parent", timestamp: cycleStart.addingTimeInterval(100)
    ))

    let rejected = reducer.rejectDescendantOfClearedSession(AgentEvent(
        source: .claude,
        kind: .working,
        sessionID: "child",
        parentSessionID: "parent",
        timestamp: cycleStart.addingTimeInterval(50)
    ))

    #expect(rejected?.completedSessions.isEmpty == true)
}

@Test func aCycleRecordsTheCostItAccruedRatherThanTheSessionTotal() {
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "s", timestamp: cycleStart))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "s",
        timestamp: cycleStart.addingTimeInterval(10),
        costUSD: 1.25
    ))
    let first = reducer.apply(completion("s", at: 100))

    // Second run: the provider keeps reporting a cumulative figure.
    reducer.apply(AgentEvent(
        source: .claude, kind: .working, sessionID: "s", timestamp: cycleStart.addingTimeInterval(200)
    ))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "s",
        timestamp: cycleStart.addingTimeInterval(210),
        costUSD: 3.0
    ))
    let second = reducer.apply(completion("s", at: 300))

    #expect(first.completedSessions.first?.costUSD == 1.25)
    // The second cycle is charged only what it added.
    #expect(second.completedSessions.first?.costUSD == 1.75)
}

@Test func anObservedZeroCostIsRecordedAsZeroNotAsMissing() {
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "s", timestamp: cycleStart))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "s",
        timestamp: cycleStart.addingTimeInterval(10),
        costUSD: 0
    ))
    let change = reducer.apply(completion("s", at: 100))

    #expect(change.completedSessions.first?.costUSD == 0)
}

@Test func aCostGenerationChangeRebasesInsteadOfProducingANegativeDelta() {
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "s", timestamp: cycleStart))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "s",
        timestamp: cycleStart.addingTimeInterval(10),
        costUSD: 5.0,
        costGeneration: "gen-1"
    ))
    reducer.apply(completion("s", at: 100))
    reducer.apply(AgentEvent(
        source: .claude, kind: .working, sessionID: "s", timestamp: cycleStart.addingTimeInterval(200)
    ))
    // A new generation restarts the provider's running total well below the previous baseline.
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "s",
        timestamp: cycleStart.addingTimeInterval(210),
        costUSD: 0.75,
        costGeneration: "gen-2"
    ))
    let change = reducer.apply(completion("s", at: 300))

    #expect(change.completedSessions.first?.costUSD == 0.75)
}

@Test func clearingCostTrackingKeepsLaterRowsFreeOfStaleFigures() {
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "s", timestamp: cycleStart))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "s",
        timestamp: cycleStart.addingTimeInterval(10),
        costUSD: 2.0
    ))
    reducer.clearCostTracking()
    let change = reducer.apply(completion("s", at: 100))

    #expect(reducer.activity(source: .claude, sessionID: "s")?.costUSD == nil)
    #expect(change.completedSessions.first?.costUSD == nil)
}

@Test func aSubagentCycleCarriesItsOwnTitleAndTiming() {
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "parent", timestamp: cycleStart))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .working,
        sessionID: "child",
        parentSessionID: "parent",
        timestamp: cycleStart.addingTimeInterval(60),
        sessionTitle: "migrate-tests"
    ))
    let change = reducer.apply(AgentEvent(
        source: .claude, kind: .cleared, sessionID: "child", timestamp: cycleStart.addingTimeInterval(360)
    ))

    #expect(change.completedSessions.first?.title == "migrate-tests")
    #expect(change.completedSessions.first?.startedAt == cycleStart.addingTimeInterval(60))
    #expect(change.completedSessions.first?.duration == 300)
}

@Test func aSessionAlreadyRunningAtLaunchIsNotChargedForSpendItNeverWatched() {
    var reducer = ActivityReducer()
    // The session had already spent $25.80 before this launch, as the persisted daily-cost
    // baselines record.
    reducer.launchCostBaseline = { key in key.sessionID == "resumed" ? 25.80 : nil }

    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "resumed", timestamp: cycleStart))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "resumed",
        timestamp: cycleStart.addingTimeInterval(5),
        costUSD: 25.95
    ))
    let change = reducer.apply(completion("resumed", at: 12))

    // Only the 15 cents that accrued while NotchBot was watching.
    let cost = change.completedSessions.first?.costUSD ?? -1
    #expect(abs(cost - 0.15) < 0.000_001)
    #expect(change.completedSessions.first?.duration == 12)
}

@Test func aGenuinelyNewSessionHasNoLaunchBaselineAndKeepsItsFullCost() {
    var reducer = ActivityReducer()
    reducer.launchCostBaseline = { key in key.sessionID == "resumed" ? 25.80 : nil }

    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "fresh", timestamp: cycleStart))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "fresh",
        timestamp: cycleStart.addingTimeInterval(5),
        costUSD: 0.40
    ))
    let change = reducer.apply(completion("fresh", at: 60))

    #expect(change.completedSessions.first?.costUSD == 0.40)
}

@Test func seeingACostGenerationForTheFirstTimeKeepsTheLaunchBaseline() {
    var reducer = ActivityReducer()
    reducer.launchCostBaseline = { _ in 10.0 }

    reducer.apply(AgentEvent(source: .opencode, kind: .working, sessionID: "s", timestamp: cycleStart))
    // First sighting of a generation is not a provider restart, so the baseline must survive it.
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .metadata,
        sessionID: "s",
        timestamp: cycleStart.addingTimeInterval(5),
        costUSD: 12.50,
        costGeneration: "gen-1"
    ))
    let change = reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "s",
        timestamp: cycleStart.addingTimeInterval(30),
        reason: "OpenCode finished working"
    ))

    #expect(change.completedSessions.first?.costUSD == 2.50)
}

@Test func aLaunchBaselineAppliesOnlyToTheFirstObservedCycle() {
    var reducer = ActivityReducer()
    reducer.launchCostBaseline = { _ in 5.0 }

    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "s", timestamp: cycleStart))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "s",
        timestamp: cycleStart.addingTimeInterval(5),
        costUSD: 6.0
    ))
    let first = reducer.apply(completion("s", at: 60))

    reducer.apply(AgentEvent(
        source: .claude, kind: .working, sessionID: "s", timestamp: cycleStart.addingTimeInterval(120)
    ))
    reducer.apply(AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "s",
        timestamp: cycleStart.addingTimeInterval(125),
        costUSD: 6.75
    ))
    let second = reducer.apply(completion("s", at: 180))

    #expect(first.completedSessions.first?.costUSD == 1.0)
    // The second cycle rebases onto the running total, not back onto the launch baseline.
    #expect(second.completedSessions.first?.costUSD == 0.75)
}

@Test func aCostGenerationChangeStillRebasesAfterALaunchBaseline() {
    var reducer = ActivityReducer()
    reducer.launchCostBaseline = { _ in 10.0 }

    reducer.apply(AgentEvent(source: .opencode, kind: .working, sessionID: "s", timestamp: cycleStart))
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .metadata,
        sessionID: "s",
        timestamp: cycleStart.addingTimeInterval(5),
        costUSD: 11.0,
        costGeneration: "gen-1"
    ))
    // A genuine restart: the running total drops well below both the baseline and the old value.
    reducer.apply(AgentEvent(
        source: .opencode,
        kind: .metadata,
        sessionID: "s",
        timestamp: cycleStart.addingTimeInterval(10),
        costUSD: 0.60,
        costGeneration: "gen-2"
    ))
    let change = reducer.apply(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "s",
        timestamp: cycleStart.addingTimeInterval(30),
        reason: "OpenCode finished working"
    ))

    #expect(change.completedSessions.first?.costUSD == 0.60)
}
