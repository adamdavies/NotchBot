import Darwin
import Foundation
import NotchBotCore

final class EventServer {
    private var descriptor: Int32 = -1
    private var lockDescriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.notchbot.event-server", qos: .userInitiated)

    func start(handler: @escaping (Data) -> Void) throws {
        let key = try EventKeyStore.loadOrCreateKey()
        try acquireInstanceLock()
        var started = false
        defer {
            if !started {
                releaseInstanceLock()
            }
        }
        try prepareSocketPath()

        descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
            close(descriptor)
            descriptor = -1
            throw CocoaError(.fileWriteUnknown)
        }

        var address = try UnixDatagramClient.socketAddress(path: NotchBotPaths.socketPath)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(
                    descriptor,
                    socketPointer,
                    UnixDatagramClient.socketLength(for: NotchBotPaths.socketPath)
                )
            }
        }
        guard result == 0 else {
            close(descriptor)
            descriptor = -1
            throw CocoaError(.fileWriteUnknown)
        }
        var boundInfo = stat()
        guard lstat(NotchBotPaths.socketPath, &boundInfo) == 0,
              (boundInfo.st_mode & S_IFMT) == S_IFSOCK,
              boundInfo.st_uid == getuid() else {
            close(descriptor)
            descriptor = -1
            throw CocoaError(.fileWriteUnknown)
        }
        guard chmod(NotchBotPaths.socketPath, S_IRUSR | S_IWUSR) == 0 else {
            close(descriptor)
            descriptor = -1
            Self.unlinkSocketIfUnchanged(device: boundInfo.st_dev, inode: boundInfo.st_ino)
            throw CocoaError(.fileWriteUnknown)
        }
        guard lstat(NotchBotPaths.socketPath, &boundInfo) == 0,
              (boundInfo.st_mode & S_IFMT) == S_IFSOCK,
              boundInfo.st_uid == getuid(), (boundInfo.st_mode & 0o777) == 0o600 else {
            close(descriptor)
            descriptor = -1
            Self.unlinkSocketIfUnchanged(device: boundInfo.st_dev, inode: boundInfo.st_ino)
            throw CocoaError(.fileWriteUnknown)
        }

        let fd = descriptor
        let dispatchSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        var replayProtection = ReplayProtection()
        var rateLimiter = TokenBucket(capacity: 120, refillPerSecond: 60)
        dispatchSource.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: AgentEventValidator.maximumDatagramBytes + 1)
            while true {
                let count = recv(fd, &buffer, buffer.count, MSG_DONTWAIT | MSG_TRUNC)
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    break
                }
                guard count > 0, count <= AgentEventValidator.maximumDatagramBytes else { continue }
                guard rateLimiter.consume() else { continue }

                let envelope = Data(buffer.prefix(count))
                guard let identifier = SecureEventEnvelope.replayIdentifier(for: envelope) else { continue }
                guard let plaintext = try? SecureEventEnvelope.open(envelope, using: key) else { continue }
                guard replayProtection.accept(identifier) else { continue }
                handler(plaintext)
            }
        }
        let device = boundInfo.st_dev
        let inode = boundInfo.st_ino
        let heldLockDescriptor = lockDescriptor
        lockDescriptor = -1
        dispatchSource.setCancelHandler {
            close(fd)
            Self.unlinkSocketIfUnchanged(device: device, inode: inode)
            flock(heldLockDescriptor, LOCK_UN)
            close(heldLockDescriptor)
        }
        source = dispatchSource
        dispatchSource.resume()
        started = true
    }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    deinit {
        stop()
    }

    private func prepareSocketPath() throws {
        let path = NotchBotPaths.socketPath
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
                throw CocoaError(.fileWriteFileExists)
            }
            guard unlink(path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } else if errno != ENOENT {
            throw CocoaError(.fileReadUnknown)
        }
    }

    private static func unlinkSocketIfUnchanged(device: dev_t, inode: ino_t) {
        var info = stat()
        guard lstat(NotchBotPaths.socketPath, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == getuid(), info.st_dev == device, info.st_ino == inode else { return }
        unlink(NotchBotPaths.socketPath)
    }

    private func acquireInstanceLock() throws {
        let path = NotchBotPaths.applicationSupportDirectory.appendingPathComponent("instance.lock").path
        let candidate = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard candidate >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var info = stat()
        guard fstat(candidate, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              fchmod(candidate, 0o600) == 0, flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
            close(candidate)
            throw CocoaError(.fileLocking)
        }
        lockDescriptor = candidate
    }

    private func releaseInstanceLock() {
        guard lockDescriptor >= 0 else { return }
        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        lockDescriptor = -1
    }

}
