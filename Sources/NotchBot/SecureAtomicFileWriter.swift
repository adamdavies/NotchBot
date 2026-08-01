import Darwin
import Foundation

protocol AtomicFileWriting {
    func write(
        _ data: Data,
        to destination: URL,
        permissions: mode_t,
        expectation: AtomicFileExpectation
    ) throws
}

extension AtomicFileWriting {
    func write(_ data: Data, to destination: URL, permissions: mode_t) throws {
        try write(data, to: destination, permissions: permissions, expectation: .unconstrained)
    }
}

enum AtomicFileExpectation {
    case unconstrained
    case absent
    case identity(AtomicFileIdentity)
}

struct SecureAtomicFileWriter: AtomicFileWriting {
    private let makeUUID: () -> UUID
    private let beforeRename: ((Int32) throws -> Void)?

    init(
        makeUUID: @escaping () -> UUID = UUID.init,
        beforeRename: ((Int32) throws -> Void)? = nil
    ) {
        self.makeUUID = makeUUID
        self.beforeRename = beforeRename
    }

    func write(
        _ data: Data,
        to destination: URL,
        permissions: mode_t,
        expectation: AtomicFileExpectation
    ) throws {
        guard permissions & ~mode_t(0o7777) == 0 else {
            throw SecureAtomicFileWriterError.invalidPermissions
        }
        let parent = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else {
            throw SecureAtomicFileWriterError.invalidDestination(destination.path)
        }

        let directoryDescriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            throw SecureAtomicFileWriterError.unsafeParent(parent.path)
        }
        defer { close(directoryDescriptor) }

        var directoryInfo = stat()
        guard fstat(directoryDescriptor, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == getuid(),
              directoryInfo.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw SecureAtomicFileWriterError.unsafeParent(parent.path)
        }

        let original = try destinationIdentity(name: name, directoryDescriptor: directoryDescriptor)
        switch expectation {
        case .unconstrained:
            break
        case .absent:
            guard original == nil else {
                throw SecureAtomicFileWriterError.destinationChanged(destination.path)
            }
        case let .identity(expected):
            guard original == expected else {
                throw SecureAtomicFileWriterError.destinationChanged(destination.path)
            }
        }
        let temporaryName = ".notchbot-\(makeUUID().uuidString).tmp"
        let descriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var temporaryExists = true
        defer {
            close(descriptor)
            if temporaryExists {
                _ = unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard result > 0 else { throw POSIXError(.EIO) }
                offset += result
            }
        }
        guard fchmod(descriptor, permissions) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        try beforeRename?(descriptor)
        guard try destinationIdentity(name: name, directoryDescriptor: directoryDescriptor) == original else {
            throw SecureAtomicFileWriterError.destinationChanged(destination.path)
        }

        let renameResult: Int32
        if original == nil {
            renameResult = renameatx_np(
                directoryDescriptor,
                temporaryName,
                directoryDescriptor,
                name,
                UInt32(RENAME_EXCL)
            )
        } else {
            renameResult = renameat(directoryDescriptor, temporaryName, directoryDescriptor, name)
        }
        guard renameResult == 0 else {
            if errno == EEXIST { throw SecureAtomicFileWriterError.destinationChanged(destination.path) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        temporaryExists = false
        guard fsync(directoryDescriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func destinationIdentity(name: String, directoryDescriptor: Int32) throws -> AtomicFileIdentity? {
        var info = stat()
        if fstatat(directoryDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else {
            throw SecureAtomicFileWriterError.unsafeDestination(name)
        }
        return AtomicFileIdentity(info)
    }
}

struct AtomicFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modificationSeconds: Int
    let modificationNanoseconds: Int
    let changeSeconds: Int
    let changeNanoseconds: Int

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modificationSeconds = info.st_mtimespec.tv_sec
        modificationNanoseconds = info.st_mtimespec.tv_nsec
        changeSeconds = info.st_ctimespec.tv_sec
        changeNanoseconds = info.st_ctimespec.tv_nsec
    }
}

enum SecureAtomicFileWriterError: LocalizedError {
    case invalidDestination(String)
    case unsafeParent(String)
    case unsafeDestination(String)
    case destinationChanged(String)
    case invalidPermissions

    var errorDescription: String? {
        switch self {
        case let .invalidDestination(path):
            "Invalid destination: \(path)."
        case let .unsafeParent(path):
            "Destination directory is not a safe user-owned directory: \(path)."
        case let .unsafeDestination(path):
            "Destination is not a user-owned regular file: \(path)."
        case let .destinationChanged(path):
            "Destination changed while it was being replaced: \(path)."
        case .invalidPermissions:
            "Invalid destination permissions."
        }
    }
}
