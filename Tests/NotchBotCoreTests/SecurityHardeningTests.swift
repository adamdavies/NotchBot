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

@Test func eventValidationRejectsDecodedOversizedActivityDescriptions() throws {
    let valid = AgentEvent(source: .claude, kind: .metadata, sessionID: "session", activityDescription: "Task")
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as! [String: Any]
    json["activityDescription"] = String(repeating: "x", count: 101)
    let decoded = try JSONDecoder().decode(AgentEvent.self, from: JSONSerialization.data(withJSONObject: json))

    #expect(throws: AgentEventValidationError.stringTooLong("activityDescription")) {
        try AgentEventValidator.validate(decoded)
    }
}

@Test func eventValidationRejectsInvalidParentRelationships() {
    let selfParent = AgentEvent(
        source: .claude,
        kind: .working,
        sessionID: "same",
        parentSessionID: "same"
    )
    #expect(throws: AgentEventValidationError.invalidParentSessionID) {
        try AgentEventValidator.validate(selfParent)
    }

    let controlCharacter = AgentEvent(
        source: .opencode,
        kind: .working,
        sessionID: "child",
        parentSessionID: "bad\nparent"
    )
    #expect(throws: AgentEventValidationError.invalidParentSessionID) {
        try AgentEventValidator.validate(controlCharacter)
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

@Test func permissionResponseUsesAnIndependentAuthenticatedEnvelope() throws {
    let key = SymmetricKey(size: .bits256)
    let response = AgentPermissionResponse(
        responseToken: String(repeating: "a", count: 32),
        decision: .allowOnce
    )
    let plaintext = try JSONEncoder().encode(response)
    let envelope = try SecurePermissionResponseEnvelope.seal(plaintext, using: key)

    #expect(try SecurePermissionResponseEnvelope.open(envelope, using: key) == plaintext)
    #expect(throws: EventSecurityError.invalidEnvelope) {
        try SecureEventEnvelope.open(envelope, using: key)
    }
    #expect(throws: EventSecurityError.invalidEnvelope) {
        try SecurePermissionResponseEnvelope.open(envelope, using: SymmetricKey(size: .bits256))
    }
}

@Test func permissionResponseSocketDeliversOneAuthenticatedDecision() async throws {
    let server = PermissionResponseServer()
    try server.start()
    defer { server.stop() }
    let response = AgentPermissionResponse(responseToken: server.responseToken, decision: .decline)
    let sender = Task.detached {
        try await Task.sleep(nanoseconds: 20_000_000)
        try UnixDatagramClient.send(response)
    }

    #expect(try server.receive(timeout: 1) == .decline)
    try await sender.value
}

@Test func permissionMetadataIsStrictlyValidated() throws {
    let request = AgentPermissionRequest(
        responseToken: String(repeating: "0", count: 32),
        summary: "Bash: git status",
        context: "git status --short",
        canAlwaysAllow: true
    )
    try AgentEventValidator.validate(AgentEvent(
        source: .claude,
        kind: .attention,
        sessionID: "session",
        permission: request
    ))

    let normalized = AgentPermissionRequest(
        responseToken: String(repeating: "1", count: 32),
        summary: "Edit",
        context: "  /tmp/a\n",
        canAlwaysAllow: false
    )
    #expect(normalized.context == "/tmp/a")

    #expect(throws: AgentEventValidationError.invalidPermission) {
        try AgentEventValidator.validate(AgentEvent(
            source: .claude,
            kind: .working,
            sessionID: "session",
            permission: request
        ))
    }
    #expect(throws: AgentEventValidationError.invalidPermission) {
        try AgentEventValidator.validate(AgentEvent(
            source: .opencode,
            kind: .attention,
            sessionID: "session",
            permission: AgentPermissionRequest(
                responseToken: "../not-a-token",
                summary: "Edit",
                canAlwaysAllow: false
            )
        ))
    }
}

@Test func requestLifecycleMetadataIsStrictlyValidated() throws {
    let opened = AgentRequestUpdate(id: "per-request", kind: .permission, state: .opened)
    try AgentEventValidator.validate(AgentEvent(
        source: .opencode,
        kind: .attention,
        sessionID: "session",
        request: opened
    ))
    try AgentEventValidator.validate(AgentEvent(
        source: .opencode,
        kind: .requestResolved,
        sessionID: "session",
        request: AgentRequestUpdate(id: "per-request", kind: .permission, state: .resolved)
    ))

    #expect(throws: AgentEventValidationError.invalidRequest) {
        try AgentEventValidator.validate(AgentEvent(
            source: .opencode,
            kind: .working,
            sessionID: "session",
            request: opened
        ))
    }
    #expect(throws: AgentEventValidationError.invalidRequest) {
        try AgentEventValidator.validate(AgentEvent(
            source: .claude,
            kind: .attention,
            sessionID: "session",
            request: opened
        ))
    }
}

@Test func contextWindowUsageIsStrictlyValidated() throws {
    for source in [AgentSource.claude, .opencode] {
        for percentage in [0.0, 49.9, 50, 74.9, 100] {
            try AgentEventValidator.validate(AgentEvent(
                source: source,
                kind: .metadata,
                sessionID: "session",
                contextWindow: ContextWindowUsageUpdate(usedPercentage: percentage)
            ))
        }
        // An explicit retraction is always well-formed.
        try AgentEventValidator.validate(AgentEvent(
            source: source,
            kind: .metadata,
            sessionID: "session",
            contextWindow: .unavailable
        ))
    }

    for percentage in [-0.1, 100.1, .infinity, .nan, -.infinity] as [Double] {
        #expect(throws: AgentEventValidationError.invalidContextWindow) {
            try AgentEventValidator.validate(AgentEvent(
                source: .claude,
                kind: .metadata,
                sessionID: "session",
                contextWindow: ContextWindowUsageUpdate(usedPercentage: percentage)
            ))
        }
    }
}

@Test func contextWindowUsageIsRejectedOnPreviewAndLifecycleEvents() {
    for kind in [AgentEventKind.working, .attention, .cleared] {
        #expect(throws: AgentEventValidationError.invalidContextWindow) {
            try AgentEventValidator.validate(AgentEvent(
                source: .opencode,
                kind: kind,
                sessionID: "session",
                contextWindow: ContextWindowUsageUpdate(usedPercentage: 50)
            ))
        }
    }
    #expect(throws: AgentEventValidationError.invalidContextWindow) {
        try AgentEventValidator.validate(
            AgentEvent(
                source: .preview,
                kind: .metadata,
                sessionID: "session",
                contextWindow: ContextWindowUsageUpdate(usedPercentage: 50)
            ),
            allowPreview: true
        )
    }
}

/// The three states have to survive a JSON round trip, because absent and present-with-nil mean
/// opposite things to the reducer and both encode to something that looks empty.
@Test func contextWindowUpdateRoundTripsItsThreeStates() throws {
    func roundTrip(_ event: AgentEvent) throws -> AgentEvent {
        try JSONDecoder().decode(AgentEvent.self, from: JSONEncoder().encode(event))
    }

    let absent = try roundTrip(AgentEvent(source: .claude, kind: .metadata, sessionID: "s"))
    #expect(absent.contextWindow == nil)

    let cleared = try roundTrip(AgentEvent(
        source: .claude, kind: .metadata, sessionID: "s", contextWindow: .unavailable
    ))
    #expect(cleared.contextWindow != nil)
    #expect(cleared.contextWindow?.usedPercentage == nil)

    let set = try roundTrip(AgentEvent(
        source: .claude,
        kind: .metadata,
        sessionID: "s",
        contextWindow: ContextWindowUsageUpdate(usedPercentage: 82)
    ))
    #expect(set.contextWindow?.usedPercentage == 82)
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

@Test func replayProtectionRingWrapsAndRetainsOnlyTheNewestIdentifiers() {
    var replay = ReplayProtection(capacity: 3)
    let first = replay.accept(Data([1]))
    let second = replay.accept(Data([2]))
    let third = replay.accept(Data([3]))
    let fourth = replay.accept(Data([4]))
    let wrappedFirst = replay.accept(Data([1]))
    let retainedThird = replay.accept(Data([3]))
    let retainedFourth = replay.accept(Data([4]))
    let wrappedSecond = replay.accept(Data([2]))
    let retainedFirst = replay.accept(Data([1]))

    #expect(first)
    #expect(second)
    #expect(third)
    #expect(fourth)
    #expect(wrappedFirst)
    #expect(!retainedThird)
    #expect(!retainedFourth)
    #expect(wrappedSecond)
    #expect(!retainedFirst)
}

@Test func eventKeyStoreUsesAnIsolatedApplicationSupportDirectory() throws {
    let directory = URL(fileURLWithPath: "/tmp/notchbot-key-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let created = try EventKeyStore.loadOrCreateKey(applicationSupportDirectory: directory)
    let loaded = try EventKeyStore.loadOrCreateKey(applicationSupportDirectory: directory)
    #expect(created.withUnsafeBytes { Data($0) } == loaded.withUnsafeBytes { Data($0) })

    var directoryInfo = stat()
    var keyInfo = stat()
    #expect(lstat(directory.path, &directoryInfo) == 0)
    #expect((directoryInfo.st_mode & 0o777) == 0o700)
    let keyPath = directory.appendingPathComponent("event.key").path
    #expect(lstat(keyPath, &keyInfo) == 0)
    #expect((keyInfo.st_mode & 0o777) == 0o600)
}

@Test func eventKeyStorePublishesOneCompleteKeyDuringConcurrentCreation() async throws {
    let directory = URL(fileURLWithPath: "/tmp/notchbot-key-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }

    let keys = try await withThrowingTaskGroup(of: Data.self) { group in
        for _ in 0..<16 {
            group.addTask {
                let key = try EventKeyStore.loadOrCreateKey(applicationSupportDirectory: directory)
                return key.withUnsafeBytes { Data($0) }
            }
        }
        var results: [Data] = []
        for try await key in group { results.append(key) }
        return results
    }

    #expect(keys.count == 16)
    #expect(Set(keys).count == 1)
    #expect(keys.allSatisfy { $0.count == 32 })
    let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(entries == ["event.key"])
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

@Test func legacyResponseSummaryIsIgnoredDuringDecoding() throws {
    let event = AgentEvent(source: .claude, kind: .working, sessionID: "one")
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
    object["summary"] = "private legacy response"
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(AgentEvent.self, from: legacyData)
    try AgentEventValidator.validate(decoded)
    let encodedObject = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
    )
    #expect(encodedObject["summary"] == nil)
}
