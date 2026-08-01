import Darwin
import Foundation
import Testing
@testable import NotchBot

@Test func secureAtomicWriterAppliesModeAndReplacesOnlyAtRename() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("managed")
    try Data("old".utf8).write(to: destination)

    let writer = SecureAtomicFileWriter(beforeRename: { descriptor in
        let contents = try Data(contentsOf: destination)
        #expect(contents == Data("old".utf8))
        var info = stat()
        #expect(fstat(descriptor, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o700)
    })
    try writer.write(Data("new".utf8), to: destination, permissions: 0o700)

    #expect(try Data(contentsOf: destination) == Data("new".utf8))
    #expect(try permissions(of: destination) == 0o700)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["managed"])
}

@Test func secureAtomicWriterRejectsSymlinkAndPreservesTarget() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("target")
    let destination = directory.appendingPathComponent("managed")
    try Data("target".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)

    #expect(throws: SecureAtomicFileWriterError.self) {
        try SecureAtomicFileWriter().write(Data("new".utf8), to: destination, permissions: 0o600)
    }
    #expect(try Data(contentsOf: target) == Data("target".utf8))

    let directoryDestination = directory.appendingPathComponent("directory", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryDestination, withIntermediateDirectories: false)
    #expect(throws: SecureAtomicFileWriterError.self) {
        try SecureAtomicFileWriter().write(Data(), to: directoryDestination, permissions: 0o600)
    }
}

@Test func secureAtomicWriterDetectsChangedDestinationAndCleansTemporaryFile() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("managed")
    try Data("old".utf8).write(to: destination)
    let writer = SecureAtomicFileWriter(beforeRename: { _ in
        try FileManager.default.removeItem(at: destination)
        try Data("concurrent".utf8).write(to: destination)
    })

    #expect(throws: SecureAtomicFileWriterError.self) {
        try writer.write(Data("new".utf8), to: destination, permissions: 0o600)
    }
    #expect(try Data(contentsOf: destination) == Data("concurrent".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["managed"])
}

@Test func secureAtomicWriterDetectsInPlaceDestinationChanges() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("managed")
    try Data("old".utf8).write(to: destination)
    let writer = SecureAtomicFileWriter(beforeRename: { _ in
        let descriptor = open(destination.path, O_WRONLY | O_TRUNC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        let replacement = Data("changed in place".utf8)
        let written = replacement.withUnsafeBytes {
            Darwin.write(descriptor, $0.baseAddress, $0.count)
        }
        guard written == replacement.count else { throw CocoaError(.fileWriteUnknown) }
    })

    #expect(throws: SecureAtomicFileWriterError.self) {
        try writer.write(Data("new".utf8), to: destination, permissions: 0o600)
    }
    #expect(try Data(contentsOf: destination) == Data("changed in place".utf8))
}

@Test func secureAtomicWriterRejectsUnsafeOrSymlinkParent() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let unsafe = directory.appendingPathComponent("unsafe", isDirectory: true)
    try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: unsafe.path)
    #expect(throws: SecureAtomicFileWriterError.self) {
        try SecureAtomicFileWriter().write(Data(), to: unsafe.appendingPathComponent("file"), permissions: 0o600)
    }

    let link = directory.appendingPathComponent("link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
    #expect(throws: SecureAtomicFileWriterError.self) {
        try SecureAtomicFileWriter().write(Data(), to: link.appendingPathComponent("file"), permissions: 0o600)
    }
}

@Test func secureAtomicWriterFailurePreservesDestinationAndCleansTemporaryFile() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("managed")
    try Data("old".utf8).write(to: destination)
    let writer = SecureAtomicFileWriter(beforeRename: { _ in throw CocoaError(.fileWriteUnknown) })

    #expect(throws: CocoaError.self) {
        try writer.write(Data("new".utf8), to: destination, permissions: 0o600)
    }
    #expect(try Data(contentsOf: destination) == Data("old".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["managed"])
}

@Test func secureAtomicWriterHandlesEmptyAndLargeDataAndRejectsInvalidMode() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let empty = directory.appendingPathComponent("empty")
    let large = directory.appendingPathComponent("large")
    let largeData = Data(repeating: 0x5a, count: 256 * 1_024)

    try SecureAtomicFileWriter().write(Data(), to: empty, permissions: 0o600)
    try SecureAtomicFileWriter().write(largeData, to: large, permissions: 0o600)

    #expect(try Data(contentsOf: empty).isEmpty)
    #expect(try Data(contentsOf: large) == largeData)
    #expect(throws: SecureAtomicFileWriterError.self) {
        try SecureAtomicFileWriter().write(Data(), to: directory.appendingPathComponent("invalid"), permissions: 0o10_000)
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return url
}

private func permissions(of url: URL) throws -> Int {
    let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    return value?.intValue ?? 0
}
