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

@Test func clearingSessionReturnsToIdle() {
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .opencode, kind: .working, sessionID: "one"))
    reducer.apply(AgentEvent(source: .opencode, kind: .cleared, sessionID: "one"))

    #expect(reducer.state == .idle)
    #expect(reducer.sessionCount == 0)
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
