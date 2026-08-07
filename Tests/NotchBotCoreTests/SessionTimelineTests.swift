import Foundation
import NotchBotCore
import Testing

private let base = Date(timeIntervalSince1970: 1_780_000_000)

private func row(
    _ sessionID: String,
    source: AgentSource = .claude,
    parent: String? = nil,
    group: String? = nil,
    title: String? = nil,
    start: TimeInterval,
    end: TimeInterval,
    cost: Double? = nil
) -> CompletedSession {
    let startedAt = base.addingTimeInterval(start)
    return CompletedSession(
        cycleID: CompletedSession.cycleID(source: source, sessionID: sessionID, startedAt: startedAt),
        source: source,
        sessionID: sessionID,
        parentSessionID: parent,
        groupID: group ?? parent ?? sessionID,
        title: title,
        startedAt: startedAt,
        endedAt: base.addingTimeInterval(end),
        costUSD: cost
    )
}

@Test func rowNormalizesTitleAndRefusesANegativeDuration() {
    let session = row("a", title: "  Refactor   auth  ", start: 600, end: 300)

    #expect(session.title == "Refactor auth")
    // A completion reported before its start collapses to zero rather than going negative.
    #expect(session.endedAt == session.startedAt)
    #expect(session.duration == 0)
}

@Test func rowDistinguishesAbsentCostFromAnObservedZero() {
    #expect(row("a", start: 0, end: 60, cost: nil).costUSD == nil)
    #expect(row("b", start: 0, end: 60, cost: 0).costUSD == 0)
    // Values that cannot be a cost are absent, not zero.
    #expect(row("c", start: 0, end: 60, cost: -1).costUSD == nil)
    #expect(row("d", start: 0, end: 60, cost: .nan).costUSD == nil)
    #expect(row("e", start: 0, end: 60, cost: .infinity).costUSD == nil)
}

@Test func cycleIDIsStableForTheSameCycleAndDistinctAcrossSourcesAndRuns() {
    let startedAt = base
    let claude = CompletedSession.cycleID(source: .claude, sessionID: "s", startedAt: startedAt)

    #expect(claude == CompletedSession.cycleID(source: .claude, sessionID: "s", startedAt: startedAt))
    #expect(claude != CompletedSession.cycleID(source: .opencode, sessionID: "s", startedAt: startedAt))
    #expect(claude != CompletedSession.cycleID(
        source: .claude,
        sessionID: "s",
        startedAt: startedAt.addingTimeInterval(1)
    ))
}

@Test func groupsAreOrderedNewestFirstWithSubagentsBeneathTheirParent() {
    let document = SessionTimelineDocument(day: "d", sessions: [
        row("child", parent: "parent", start: 200, end: 400),
        row("later", start: 900, end: 1_000),
        row("parent", start: 100, end: 500),
    ])

    let groups = document.orderedGroups
    #expect(groups.map(\.parent.sessionID) == ["later", "parent"])
    #expect(groups[0].subagents.isEmpty)
    #expect(groups[1].subagents.map(\.sessionID) == ["child"])
    #expect(groups[1].rowCount == 2)
}

@Test func aGroupIsOrderedByItsMostRecentMemberNotItsParent() {
    // The parent finished first; the group still sorts by the subagent that outlived it.
    let document = SessionTimelineDocument(day: "d", sessions: [
        row("solo", start: 0, end: 700),
        row("parent", start: 0, end: 100),
        row("child", parent: "parent", start: 50, end: 900),
    ])

    #expect(document.orderedGroups.map(\.parent.sessionID) == ["parent", "solo"])
}

@Test func aSubagentWhoseParentRowIsMissingStillAppears() {
    let document = SessionTimelineDocument(day: "d", sessions: [
        row("orphan", parent: "gone", group: "gone", start: 0, end: 100),
    ])

    let groups = document.orderedGroups
    #expect(groups.count == 1)
    #expect(groups[0].parent.sessionID == "orphan")
    #expect(groups[0].subagents.isEmpty)
}

@Test func upsertReplacesTheSameCycleAndReportsWhetherAnythingChanged() {
    var document = SessionTimelineDocument(day: "d", sessions: [row("a", start: 0, end: 100)])
    let updated = row("a", title: "named", start: 0, end: 200, cost: 1.5)

    let replaced = document.upsert(updated)
    #expect(replaced)
    #expect(document.sessions.count == 1)
    #expect(document.sessions[0].title == "named")
    #expect(document.sessions[0].costUSD == 1.5)

    // The identical row again is not a change, so a caller can skip a pointless write.
    let unchanged = document.upsert(updated)
    #expect(!unchanged)
    #expect(document.sessions.count == 1)
}

@Test func aSecondCycleOfTheSameSessionIsASeparateRow() {
    var document = SessionTimelineDocument(day: "d", sessions: [row("a", start: 0, end: 100, cost: 1)])
    document.upsert(row("a", start: 500, end: 600, cost: 2))

    #expect(document.sessions.count == 2)
    #expect(document.totalCostUSD == 3)
}

@Test func totalCostCountsOnlyObservedCosts() {
    let document = SessionTimelineDocument(day: "d", sessions: [
        row("a", start: 0, end: 100, cost: 1.25),
        row("b", start: 0, end: 100, cost: nil),
        row("c", start: 0, end: 100, cost: 0),
    ])

    #expect(document.totalCostUSD == 1.25)
    #expect(document.hasObservedCost)
}

@Test func removeCostsStripsEveryFigureButKeepsTheRows() {
    var document = SessionTimelineDocument(day: "d", sessions: [
        row("a", start: 0, end: 100, cost: 1),
        row("b", start: 200, end: 300, cost: 0),
    ])

    let stripped = document.removeCosts()
    #expect(stripped)
    #expect(document.sessions.count == 2)
    #expect(document.sessions.allSatisfy { $0.costUSD == nil })
    #expect(!document.hasObservedCost)
    // Nothing left to strip.
    let again = document.removeCosts()
    #expect(!again)
}

@Test func theEntryBoundTrimsWholeGroupsFromTheOldestEnd() {
    let sessions = (0..<(SessionTimelineDocument.maximumEntries + 40)).map {
        row("s\($0)", start: TimeInterval($0) * 10, end: TimeInterval($0) * 10 + 5)
    }
    let document = SessionTimelineDocument(day: "d", sessions: sessions)

    #expect(document.sessions.count == SessionTimelineDocument.maximumEntries)
    // The oldest went first, so the newest survive.
    #expect(document.sessions.last?.sessionID == "s\(sessions.count - 1)")
    #expect(!document.sessions.contains { $0.sessionID == "s0" })
}

@Test func trimmingNeverSeparatesASubagentFromItsParent() {
    var sessions = (0..<SessionTimelineDocument.maximumEntries).map {
        row("filler\($0)", start: TimeInterval($0) * 10, end: TimeInterval($0) * 10 + 5)
    }
    // A group whose members straddle the point a row-by-row trim would have cut.
    sessions.append(row("parent", start: 100_000, end: 100_100))
    sessions.append(row("child", parent: "parent", start: 100_010, end: 100_090))

    let document = SessionTimelineDocument(day: "d", sessions: sessions)
    let survivingGroups = Set(document.sessions.map(\.groupID))

    for groupID in survivingGroups {
        let members = document.sessions.filter { $0.groupID == groupID }
        // Either the whole group survived or none of it did — a subagent is never left alone.
        #expect(members.contains { $0.sessionID == groupID })
    }
    #expect(document.sessions.contains { $0.sessionID == "child" })
}

@Test func theEncodedSizeBoundHoldsEvenWithMaximumLengthTitles() {
    let longTitle = String(repeating: "t", count: AgentPresentationText.maximumCharacters)
    let sessions = (0..<SessionTimelineDocument.maximumEntries).map {
        row("session-identifier-\($0)", title: longTitle, start: TimeInterval($0), end: TimeInterval($0) + 1)
    }
    let document = SessionTimelineDocument(day: "d", sessions: sessions)

    let encoded = try? document.encoded()
    #expect(encoded != nil)
    #expect((encoded?.count ?? .max) <= SessionTimelineDocument.maximumEncodedBytes)
    // The bound bit before the entry cap did, so rows were dropped.
    #expect(document.sessions.count < SessionTimelineDocument.maximumEntries)
    #expect(!document.sessions.isEmpty)
}

@Test func encodingRoundTripsExactlyAtTheResolutionCycleIDsUse() throws {
    let document = SessionTimelineDocument(day: "d", sessions: [
        row("a", title: "Build", start: 0.125, end: 61.5, cost: 2.5),
        row("b", source: .opencode, start: 10, end: 20, cost: nil),
    ])

    let decoded = try SessionTimelineDocument.decoder()
        .decode(SessionTimelineDocument.self, from: document.encoded())

    #expect(decoded == document)
    #expect(decoded.version == SessionTimelineDocument.currentVersion)
    // A reloaded row's own cycle ID still matches one derived from its timestamps.
    for session in decoded.sessions {
        #expect(session.cycleID == CompletedSession.cycleID(
            source: session.source,
            sessionID: session.sessionID,
            startedAt: session.startedAt
        ))
    }
}

@Test func aDocumentForANewDayStartsEmpty() {
    let document = SessionTimelineDocument(day: "2026-08-08")

    #expect(document.sessions.isEmpty)
    #expect(document.orderedGroups.isEmpty)
    #expect(document.totalCostUSD == 0)
    #expect(!document.hasObservedCost)
}
