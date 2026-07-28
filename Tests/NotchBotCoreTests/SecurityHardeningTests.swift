import CryptoKit
import Foundation
import Testing
@testable import NotchBotCore

@Test func eventValidationEnforcesProtocolAndFieldLimits() throws {
    let valid = AgentEvent(source: .claude, kind: .working, sessionID: "session")
    try AgentEventValidator.validate(valid)

    var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as! [String: Any]
    legacyJSON["version"] = 1
    let legacy = try JSONDecoder().decode(
        AgentEvent.self,
        from: JSONSerialization.data(withJSONObject: legacyJSON)
    )
    #expect(throws: AgentEventValidationError.unsupportedVersion) {
        try AgentEventValidator.validate(legacy)
    }

    let preview = AgentEvent(source: .preview, kind: .working, sessionID: "session")
    #expect(throws: AgentEventValidationError.previewSourceNotAllowed) {
        try AgentEventValidator.validate(preview)
    }

    let oversized = AgentEvent(
        source: .claude,
        kind: .attention,
        sessionID: "session",
        reason: String(repeating: "x", count: 513)
    )
    #expect(throws: AgentEventValidationError.stringTooLong("reason")) {
        try AgentEventValidator.validate(oversized)
    }
}

@Test func eventValidationRejectsTimestampSkewAndInvalidExpiry() {
    let now = Date()
    let stale = AgentEvent(
        source: .opencode,
        kind: .working,
        sessionID: "session",
        timestamp: now.addingTimeInterval(-301)
    )
    #expect(throws: AgentEventValidationError.invalidTimestamp) {
        try AgentEventValidator.validate(stale, now: now)
    }

    for expiry in [TimeInterval.infinity, .nan, -1, 301] {
        let event = AgentEvent(
            source: .opencode,
            kind: .attention,
            sessionID: "session",
            timestamp: now,
            expiresAfter: expiry
        )
        #expect(throws: AgentEventValidationError.invalidExpiry) {
            try AgentEventValidator.validate(event, now: now)
        }
    }
}

@Test func encryptedEnvelopeRejectsTamperingAndWrongKey() throws {
    let event = AgentEvent(source: .claude, kind: .attention, sessionID: "secure")
    let plaintext = try JSONEncoder().encode(event)
    let key = SymmetricKey(size: .bits256)
    let envelope = try SecureEventEnvelope.seal(plaintext, using: key)

    #expect(try SecureEventEnvelope.open(envelope, using: key) == plaintext)
    #expect(throws: EventSecurityError.invalidEnvelope) {
        try SecureEventEnvelope.open(envelope, using: SymmetricKey(size: .bits256))
    }

    var tampered = envelope
    tampered[tampered.index(before: tampered.endIndex)] ^= 1
    #expect(throws: EventSecurityError.invalidEnvelope) {
        try SecureEventEnvelope.open(tampered, using: key)
    }
}

@Test func replayProtectionIsBoundedAndRejectsDuplicates() {
    var replay = ReplayProtection(capacity: 2)
    let first = replay.accept(Data([1]))
    let duplicate = replay.accept(Data([1]))
    let second = replay.accept(Data([2]))
    let third = replay.accept(Data([3]))
    let evicted = replay.accept(Data([1]))
    #expect(first)
    #expect(!duplicate)
    #expect(second)
    #expect(third)
    #expect(evicted)
}

@Test func reducerRejectsOutOfOrderEventsIncludingAfterClear() {
    let start = Date(timeIntervalSince1970: 1_000)
    var reducer = ActivityReducer()
    reducer.apply(AgentEvent(source: .claude, kind: .attention, sessionID: "one", timestamp: start))
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "one", timestamp: start.addingTimeInterval(-1)))
    #expect(reducer.state == .attention)

    reducer.apply(AgentEvent(source: .claude, kind: .cleared, sessionID: "one", timestamp: start.addingTimeInterval(1)))
    reducer.apply(AgentEvent(source: .claude, kind: .working, sessionID: "one", timestamp: start))
    #expect(reducer.state == .idle)
}

@Test func reducerCapsSessionsAndEvictsStaleState() {
    let start = Date(timeIntervalSince1970: 1_000)
    var reducer = ActivityReducer()
    for index in 0...ActivityReducer.maximumSessions {
        reducer.apply(AgentEvent(
            source: .opencode,
            kind: .working,
            sessionID: "session-\(index)",
            timestamp: start.addingTimeInterval(Double(index))
        ))
    }
    #expect(reducer.sessionCount == ActivityReducer.maximumSessions)

    reducer.removeSessions(olderThan: start.addingTimeInterval(Double(ActivityReducer.maximumSessions)))
    #expect(reducer.sessionCount == 1)
}

@Test func summaryRetentionExpiresOldSummaries() {
    let start = Date(timeIntervalSince1970: 1_000)
    var store = AgentSummaryStore()
    store.apply(AgentEvent(
        source: .claude,
        kind: .attention,
        sessionID: "one",
        timestamp: start,
        summary: "Finished"
    ))

    #expect(store.removeLatest(olderThan: start.addingTimeInterval(-1))?.text == "Finished")
    #expect(store.removeLatest(olderThan: start.addingTimeInterval(1)) == nil)
    #expect(store.latest == nil)
}
