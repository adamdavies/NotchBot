import CryptoKit
import Darwin
import Foundation
import NotchBotCore
import Testing
@testable import NotchBot

@Test func eventServerReceivesAuthenticatedDatagramsAndRestartsCleanly() throws {
    let paths = try IsolatedEventServerPaths()
    defer { paths.remove() }
    let server = EventServer(
        applicationSupportDirectory: paths.supportDirectory,
        socketPath: paths.socketPath
    )
    let event = AgentEvent(source: .opencode, kind: .working, sessionID: "lifecycle")
    let plaintext = try JSONEncoder().encode(event)
    let key = try EventKeyStore.loadOrCreateKey(
        applicationSupportDirectory: paths.supportDirectory
    )
    let envelope = try SecureEventEnvelope.seal(plaintext, using: key)
    let received = NSLock()
    var payloads: [Data] = []
    let firstDelivery = DispatchSemaphore(value: 0)

    try server.start { payload in
        received.lock()
        payloads.append(payload)
        received.unlock()
        firstDelivery.signal()
    }
    #expect(socketPermissions(at: paths.socketPath) == 0o600)
    let tamperedEnvelope = Data(envelope.dropLast()) + Data([try #require(envelope.last) ^ 1])
    try sendDatagram(tamperedEnvelope, to: paths.socketPath)
    try sendDatagram(envelope, to: paths.socketPath)
    try sendDatagram(envelope, to: paths.socketPath)
    #expect(firstDelivery.wait(timeout: .now() + 2) == .success)
    server.stop()

    received.lock()
    let firstRunPayloads = payloads
    received.unlock()
    #expect(firstRunPayloads == [plaintext])
    #expect(lstatExists(paths.socketPath) == false)

    let secondDelivery = DispatchSemaphore(value: 0)
    try server.start { payload in
        received.lock()
        payloads.append(payload)
        received.unlock()
        secondDelivery.signal()
    }
    try sendDatagram(envelope, to: paths.socketPath)
    #expect(secondDelivery.wait(timeout: .now() + 2) == .success)
    server.stop()

    received.lock()
    let allPayloads = payloads
    received.unlock()
    #expect(allPayloads == [plaintext, plaintext])
    #expect(lstatExists(paths.socketPath) == false)
}

@Test func eventServerRejectsDuplicateStartWithoutDisruptingActiveSocket() throws {
    let paths = try IsolatedEventServerPaths()
    defer { paths.remove() }
    let server = EventServer(
        applicationSupportDirectory: paths.supportDirectory,
        socketPath: paths.socketPath
    )
    try server.start { _ in }
    defer { server.stop() }

    #expect(throws: EventServerError.alreadyStarted) {
        try server.start { _ in }
    }
    let contender = EventServer(
        applicationSupportDirectory: paths.supportDirectory,
        socketPath: paths.socketPath
    )
    #expect(throws: (any Error).self) {
        try contender.start { _ in }
    }
    #expect(lstatExists(paths.socketPath))
}

@Test func eventServerCleansUpFailedStartAndCanRetry() throws {
    let paths = try IsolatedEventServerPaths(createSocketDirectory: false)
    defer { paths.remove() }
    let server = EventServer(
        applicationSupportDirectory: paths.supportDirectory,
        socketPath: paths.socketPath
    )

    #expect(throws: (any Error).self) {
        try server.start { _ in }
    }
    try FileManager.default.createDirectory(
        at: paths.socketDirectory,
        withIntermediateDirectories: true
    )
    try server.start { _ in }
    server.stop()
    #expect(lstatExists(paths.socketPath) == false)
}

@Test func eventServerStopDoesNotUnlinkAReplacementSocket() throws {
    let paths = try IsolatedEventServerPaths()
    defer { paths.remove() }
    let server = EventServer(
        applicationSupportDirectory: paths.supportDirectory,
        socketPath: paths.socketPath
    )
    try server.start { _ in }

    let originalPath = paths.socketPath + ".original"
    try FileManager.default.moveItem(
        atPath: paths.socketPath,
        toPath: originalPath
    )
    let replacementDescriptor = try bindDatagramSocket(at: paths.socketPath)
    defer {
        close(replacementDescriptor)
        unlink(paths.socketPath)
        unlink(originalPath)
    }

    server.stop()
    #expect(lstatExists(paths.socketPath))
}

@Test func eventServerCanStopAndRestartFromItsHandlerWithoutReusingTheOldLoop() throws {
    let paths = try IsolatedEventServerPaths()
    defer { paths.remove() }
    let server = EventServer(
        applicationSupportDirectory: paths.supportDirectory,
        socketPath: paths.socketPath
    )
    let key = try EventKeyStore.loadOrCreateKey(applicationSupportDirectory: paths.supportDirectory)
    let firstPlaintext = try JSONEncoder().encode(
        AgentEvent(source: .opencode, kind: .working, sessionID: "first")
    )
    let secondPlaintext = try JSONEncoder().encode(
        AgentEvent(source: .opencode, kind: .working, sessionID: "second")
    )
    let firstEnvelope = try SecureEventEnvelope.seal(firstPlaintext, using: key)
    let secondEnvelope = try SecureEventEnvelope.seal(secondPlaintext, using: key)
    let secondDelivery = DispatchSemaphore(value: 0)
    let stateLock = NSLock()
    var restartError: Error?
    var secondPayload: Data?

    try server.start { _ in
        server.stop()
        do {
            try server.start { payload in
                stateLock.lock()
                secondPayload = payload
                stateLock.unlock()
                secondDelivery.signal()
            }
            try sendDatagram(secondEnvelope, to: paths.socketPath)
        } catch {
            stateLock.lock()
            restartError = error
            stateLock.unlock()
            secondDelivery.signal()
        }
    }
    try sendDatagram(firstEnvelope, to: paths.socketPath)
    #expect(secondDelivery.wait(timeout: .now() + 2) == .success)
    server.stop()

    stateLock.lock()
    let capturedError = restartError
    let capturedPayload = secondPayload
    stateLock.unlock()
    #expect(capturedError == nil)
    #expect(capturedPayload == secondPlaintext)
}

private struct IsolatedEventServerPaths {
    let root: URL
    let supportDirectory: URL
    let socketDirectory: URL
    let socketPath: String

    init(createSocketDirectory: Bool = true) throws {
        root = URL(fileURLWithPath: "/tmp/notchbot-tests-\(UUID().uuidString)", isDirectory: true)
        supportDirectory = root.appendingPathComponent("support", isDirectory: true)
        socketDirectory = root.appendingPathComponent("socket", isDirectory: true)
        socketPath = socketDirectory.appendingPathComponent("events.sock").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        if createSocketDirectory {
            try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: false)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func sendDatagram(_ data: Data, to path: String) throws {
    let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    defer { close(descriptor) }
    var address = try UnixDatagramClient.socketAddress(path: path)
    let result = data.withUnsafeBytes { payload in
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                sendto(
                    descriptor,
                    payload.baseAddress,
                    payload.count,
                    0,
                    socketPointer,
                    UnixDatagramClient.socketLength(for: path)
                )
            }
        }
    }
    guard result == data.count else { throw CocoaError(.fileWriteUnknown) }
}

private func bindDatagramSocket(at path: String) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    var address = try UnixDatagramClient.socketAddress(path: path)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
            Darwin.bind(
                descriptor,
                socketPointer,
                UnixDatagramClient.socketLength(for: path)
            )
        }
    }
    guard result == 0 else {
        close(descriptor)
        throw CocoaError(.fileWriteUnknown)
    }
    return descriptor
}

private func socketPermissions(at path: String) -> mode_t? {
    var info = stat()
    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK else { return nil }
    return info.st_mode & 0o777
}

private func lstatExists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}
