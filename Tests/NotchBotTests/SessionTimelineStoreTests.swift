import Darwin
import Foundation
import NotchBotCore
import Testing
@testable import NotchBot

private let day = "1-2026-8-7"
private let storeBase = Date(timeIntervalSince1970: 1_780_000_000)

@MainActor
private struct StoreFixture {
    let store: SessionTimelineStore
    let support: URL
    let url: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: support.deletingLastPathComponent())
    }
}

private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return url
}

private func fileMode(of url: URL) throws -> Int {
    let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    return value?.intValue ?? 0
}

@MainActor
private func makeStoreFixture() throws -> StoreFixture {
    let root = try temporaryRoot()
    let support = root.appendingPathComponent("Application Support/NotchBot", isDirectory: true)
    let paths = IntegrationPaths(homeDirectory: root, applicationSupportDirectory: support)
    let store = SessionTimelineStore(
        store: ManagedFileStore(fileManager: .default, fileWriter: SecureAtomicFileWriter()),
        paths: paths
    )
    return StoreFixture(store: store, support: support, url: paths.sessionTimeline)
}

private func session(_ sessionID: String, offset: TimeInterval, cost: Double? = nil) -> CompletedSession {
    let startedAt = storeBase.addingTimeInterval(offset)
    return CompletedSession(
        cycleID: CompletedSession.cycleID(source: .claude, sessionID: sessionID, startedAt: startedAt),
        source: .claude,
        sessionID: sessionID,
        groupID: sessionID,
        title: "Task \(sessionID)",
        startedAt: startedAt,
        endedAt: startedAt.addingTimeInterval(120),
        costUSD: cost
    )
}

@Test @MainActor func anAbsentTimelineLoadsAsNothingWithoutCreatingAFile() throws {
    let fixture = try makeStoreFixture()
    defer { fixture.cleanup() }

    #expect(try fixture.store.load(day: day) == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
}

@Test @MainActor func aSavedTimelineSurvivesAReloadWithinTheSameDay() throws {
    let fixture = try makeStoreFixture()
    defer { fixture.cleanup() }
    let document = SessionTimelineDocument(day: day, sessions: [
        session("a", offset: 0, cost: 1.5),
        session("b", offset: 600),
    ])

    try fixture.store.save(document)
    let reloaded = try fixture.store.load(day: day)

    #expect(reloaded == document)
    #expect(reloaded?.sessions.count == 2)
    #expect(reloaded?.totalCostUSD == 1.5)
    // Absent cost stays absent across the round trip rather than becoming zero.
    #expect(reloaded?.sessions.first(where: { $0.sessionID == "b" })?.costUSD == nil)
}

@Test @MainActor func theStoreWritesOwnerOnlyPermissionsInsideAPrivateDirectory() throws {
    let fixture = try makeStoreFixture()
    defer { fixture.cleanup() }

    try fixture.store.save(SessionTimelineDocument(day: day, sessions: [session("a", offset: 0)]))

    #expect(try fileMode(of: fixture.url) == 0o600)
    var info = stat()
    #expect(lstat(fixture.support.path, &info) == 0)
    #expect(info.st_mode & 0o7777 == 0o700)
    #expect(info.st_mode & (S_IWGRP | S_IWOTH) == 0)
}

@Test @MainActor func savingLeavesNoTemporaryFileBehind() throws {
    let fixture = try makeStoreFixture()
    defer { fixture.cleanup() }

    try fixture.store.save(SessionTimelineDocument(day: day, sessions: [session("a", offset: 0)]))
    try fixture.store.save(SessionTimelineDocument(day: day, sessions: [session("b", offset: 60)]))

    let contents = try FileManager.default.contentsOfDirectory(atPath: fixture.support.path)
    #expect(contents == ["session-timeline.json"])
}

@Test @MainActor func aTimelineFromAnEarlierDayIsDiscardedRatherThanAdopted() throws {
    let fixture = try makeStoreFixture()
    defer { fixture.cleanup() }

    try fixture.store.save(SessionTimelineDocument(day: "1-2026-8-6", sessions: [session("a", offset: 0)]))

    #expect(try fixture.store.load(day: day) == nil)
    // Yesterday's labels do not linger on disk waiting for a matching day.
    #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
}

@Test @MainActor func malformedContentIsDiscardedInsteadOfFailingEveryLoad() throws {
    let fixture = try makeStoreFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(at: fixture.support, withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: fixture.url)

    #expect(try fixture.store.load(day: day) == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
}

@Test @MainActor func anUnsupportedVersionIsDiscarded() throws {
    let fixture = try makeStoreFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(at: fixture.support, withIntermediateDirectories: true)
    let future = #"{"version":999,"day":"\#(day)","sessions":[]}"#
    try Data(future.utf8).write(to: fixture.url)

    #expect(try fixture.store.load(day: day) == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
}

@Test @MainActor func anOversizedFileIsRejectedAndDiscarded() throws {
    let fixture = try makeStoreFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(at: fixture.support, withIntermediateDirectories: true)
    let oversized = Data(repeating: UInt8(ascii: "a"), count: SessionTimelineStore.maximumFileBytes + 1)
    try oversized.write(to: fixture.url)

    #expect(try fixture.store.load(day: day) == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
}

@Test @MainActor func aSymlinkedDestinationIsRefusedAndItsTargetIsLeftAlone() throws {
    let fixture = try makeStoreFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(at: fixture.support, withIntermediateDirectories: true)
    let target = fixture.support.appendingPathComponent("secret")
    try Data("private".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: target)

    #expect(throws: IntegrationError.self) { try fixture.store.load(day: day) }
    // Neither the link nor what it points at is touched.
    #expect(try Data(contentsOf: target) == Data("private".utf8))
    #expect(FileManager.default.fileExists(atPath: fixture.url.path))
    // Saving over it is refused too, so the target cannot be overwritten through the link.
    #expect(throws: (any Error).self) {
        try fixture.store.save(SessionTimelineDocument(day: day, sessions: [session("a", offset: 0)]))
    }
    #expect(try Data(contentsOf: target) == Data("private".utf8))
}

@Test @MainActor func aDirectoryAtTheDestinationIsRefusedNotRemoved() throws {
    let fixture = try makeStoreFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: true)

    #expect(throws: IntegrationError.self) { try fixture.store.load(day: day) }
    #expect(throws: (any Error).self) { try fixture.store.removeAll() }
    #expect(FileManager.default.fileExists(atPath: fixture.url.path))
}

@Test @MainActor func removeAllDeletesTheFileAndIsSafeToRepeat() throws {
    let fixture = try makeStoreFixture()
    defer { fixture.cleanup() }
    try fixture.store.save(SessionTimelineDocument(day: day, sessions: [session("a", offset: 0)]))

    try fixture.store.removeAll()
    #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
    // Removing what is already gone is not an error.
    try fixture.store.removeAll()
    #expect(try fixture.store.load(day: day) == nil)
}

@Test @MainActor func loadReappliesOrderingAndBoundsRatherThanTrustingTheFile() throws {
    let fixture = try makeStoreFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(at: fixture.support, withIntermediateDirectories: true)
    // Hand-written and deliberately out of order, as a tampered or older file could be.
    let rows = [session("late", offset: 5_000), session("early", offset: 0)]
    let encoder = SessionTimelineDocument.encoder()
    let payload = try encoder.encode(SessionTimelineDocument(day: day, sessions: rows))
    var object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
    let sessions = try #require(object["sessions"] as? [[String: Any]])
    object["sessions"] = Array(sessions.reversed())
    try JSONSerialization.data(withJSONObject: object).write(to: fixture.url)

    let loaded = try #require(try fixture.store.load(day: day))
    #expect(loaded.sessions.map(\.sessionID) == ["early", "late"])
    #expect(loaded.orderedGroups.map(\.parent.sessionID) == ["late", "early"])
}
