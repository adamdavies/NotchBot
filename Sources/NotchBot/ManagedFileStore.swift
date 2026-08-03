import Darwin
import Foundation

/// Bounded, symlink-refusing reads and permission-preserving writes for the files the integration
/// manages. Every managed-file access goes through here so the safety checks stay in one place.
struct ManagedFileStore {
    let fileManager: FileManager
    let fileWriter: any AtomicFileWriting

    func writeAtomically(
        _ data: Data,
        to url: URL,
        permissions: Int,
        expectation: AtomicFileExpectation = .unconstrained
    ) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileWriter.write(
            data,
            to: url,
            permissions: mode_t(permissions),
            expectation: expectation
        )
    }

    func regularFile(at url: URL) throws -> Bool {
        let parentDescriptor = open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parentDescriptor >= 0 else {
            if errno == ENOENT { return false }
            throw CocoaError(.fileReadUnknown)
        }
        defer { close(parentDescriptor) }
        var info = stat()
        guard fstatat(parentDescriptor, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return false }
            throw CocoaError(.fileReadUnknown)
        }
        return (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid()
    }

    func itemExists(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    func fileMode(at url: URL) throws -> Int? {
        let descriptor = try openRegularFile(at: url)
        guard descriptor >= 0 else {
            return nil
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid() else {
            throw IntegrationError.invalidManagedFile(url.path)
        }
        return Int(info.st_mode & mode_t(0o7777))
    }

    func boundedData(at url: URL, maximum: Int) throws -> Data {
        try boundedSnapshot(at: url, maximum: maximum).data
    }

    func boundedSnapshot(at url: URL, maximum: Int) throws -> ManagedFileSnapshot {
        let descriptor = try openRegularFile(at: url)
        guard descriptor >= 0 else { throw CocoaError(.fileNoSuchFile) }
        defer { close(descriptor) }
        var initialInfo = stat()
        guard fstat(descriptor, &initialInfo) == 0,
              (initialInfo.st_mode & S_IFMT) == S_IFREG,
              initialInfo.st_uid == getuid() else {
            throw IntegrationError.invalidManagedFile(url.path)
        }
        var data = Data(count: maximum + 1)
        let count = try data.withUnsafeMutableBytes { bytes -> Int in
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.read(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw CocoaError(.fileReadUnknown)
                }
                if result == 0 { break }
                offset += result
            }
            return offset
        }
        data.count = count
        guard data.count <= maximum else { throw IntegrationError.managedFileTooLarge(url.path) }
        var finalInfo = stat()
        guard fstat(descriptor, &finalInfo) == 0,
              AtomicFileIdentity(initialInfo) == AtomicFileIdentity(finalInfo) else {
            throw IntegrationError.concurrentSettingsChange
        }
        return ManagedFileSnapshot(data: data, identity: AtomicFileIdentity(finalInfo))
    }

    func boundedString(at url: URL, maximum: Int) throws -> String {
        guard let value = String(data: try boundedData(at: url, maximum: maximum), encoding: .utf8) else {
            throw IntegrationError.invalidManagedFile(url.path)
        }
        return value
    }

    func decodeJSONObject(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return object
    }

    func preparePrivateSupportDirectory(_ directory: URL) throws {
        if itemExists(at: directory) {
            var info = stat()
            guard lstat(directory.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid() else {
                throw IntegrationError.unsafeSupportDirectory
            }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try secureDirectory(directory, permissions: 0o700)
    }

    func secureDirectory(_ directory: URL, permissions: Int) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw IntegrationError.unsafeSupportDirectory }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid() else {
            throw IntegrationError.unsafeSupportDirectory
        }
        guard fchmod(descriptor, mode_t(permissions)) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    func privateDirectory(at directory: URL) throws -> Bool {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT || errno == ELOOP || errno == ENOTDIR { return false }
            throw CocoaError(.fileReadUnknown)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        return (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == getuid()
            && info.st_mode & (S_IWGRP | S_IWOTH) == 0
    }

    private func openRegularFile(at url: URL) throws -> Int32 {
        let parent = url.deletingLastPathComponent()
        let directoryDescriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            if errno == ENOENT { return -1 }
            throw IntegrationError.invalidManagedFile(url.path)
        }
        defer { close(directoryDescriptor) }
        let descriptor = openat(directoryDescriptor, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return -1 }
            throw IntegrationError.invalidManagedFile(url.path)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid() else {
            close(descriptor)
            throw IntegrationError.invalidManagedFile(url.path)
        }
        return descriptor
    }
}
