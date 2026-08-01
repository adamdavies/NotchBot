import Darwin
import Foundation
import NotchBotCore

enum EventServerError: Error, Equatable {
    case alreadyStarted
}

final class EventServer {
    private var descriptor: Int32 = -1
    private var lockDescriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.notchbot.event-server", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Void>()
    private let lifecycleLock = NSLock()
    private let applicationSupportDirectory: URL
    private let socketPath: String
    private var socketDevice: dev_t?
    private var socketInode: ino_t?

    init(
        applicationSupportDirectory: URL = NotchBotPaths.applicationSupportDirectory,
        socketPath: String = NotchBotPaths.socketPath
    ) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.socketPath = socketPath
        queue.setSpecific(key: queueKey, value: ())
    }

    func start(handler: @escaping (Data) -> Void) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard source == nil, descriptor < 0, lockDescriptor < 0 else {
            throw EventServerError.alreadyStarted
        }

        let key = try EventKeyStore.loadOrCreateKey(
            applicationSupportDirectory: applicationSupportDirectory
        )
        let acquiredLockDescriptor = try acquireInstanceLock()
        var socketDescriptor: Int32 = -1
        var boundDevice: dev_t?
        var boundInode: ino_t?
        var started = false
        defer {
            if !started {
                if socketDescriptor >= 0 { close(socketDescriptor) }
                if let boundDevice, let boundInode {
                    unlinkSocketIfUnchanged(device: boundDevice, inode: boundInode)
                }
                Self.releaseInstanceLock(acquiredLockDescriptor)
            }
        }
        try prepareSocketPath()

        socketDescriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard socketDescriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard fcntl(
            socketDescriptor,
            F_SETFL,
            fcntl(socketDescriptor, F_GETFL) | O_NONBLOCK
        ) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }

        var address = try UnixDatagramClient.socketAddress(path: socketPath)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(
                    socketDescriptor,
                    socketPointer,
                    UnixDatagramClient.socketLength(for: socketPath)
                )
            }
        }
        guard result == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        var boundInfo = stat()
        guard lstat(socketPath, &boundInfo) == 0,
              (boundInfo.st_mode & S_IFMT) == S_IFSOCK,
              boundInfo.st_uid == getuid() else {
            throw CocoaError(.fileWriteUnknown)
        }
        boundDevice = boundInfo.st_dev
        boundInode = boundInfo.st_ino
        guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard lstat(socketPath, &boundInfo) == 0,
              (boundInfo.st_mode & S_IFMT) == S_IFSOCK,
              boundInfo.st_uid == getuid(), (boundInfo.st_mode & 0o777) == 0o600,
              boundInfo.st_dev == boundDevice, boundInfo.st_ino == boundInode else {
            throw CocoaError(.fileWriteUnknown)
        }

        let fd = socketDescriptor
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
                if dispatchSource.isCancelled { break }
            }
        }
        descriptor = socketDescriptor
        lockDescriptor = acquiredLockDescriptor
        socketDevice = boundDevice
        socketInode = boundInode
        source = dispatchSource
        dispatchSource.resume()
        started = true
    }

    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard let activeSource = source else { return }

        activeSource.cancel()
        if DispatchQueue.getSpecific(key: queueKey) == nil {
            queue.sync {}
        }
        close(descriptor)
        if let socketDevice, let socketInode {
            unlinkSocketIfUnchanged(device: socketDevice, inode: socketInode)
        }
        Self.releaseInstanceLock(lockDescriptor)

        source = nil
        descriptor = -1
        lockDescriptor = -1
        socketDevice = nil
        socketInode = nil
    }

    deinit {
        stop()
    }

    private func prepareSocketPath() throws {
        var info = stat()
        if lstat(socketPath, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
                throw CocoaError(.fileWriteFileExists)
            }
            guard unlink(socketPath) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } else if errno != ENOENT {
            throw CocoaError(.fileReadUnknown)
        }
    }

    private func unlinkSocketIfUnchanged(device: dev_t, inode: ino_t) {
        var info = stat()
        guard lstat(socketPath, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == getuid(), info.st_dev == device, info.st_ino == inode else { return }
        unlink(socketPath)
    }

    private func acquireInstanceLock() throws -> Int32 {
        let path = applicationSupportDirectory.appendingPathComponent("instance.lock").path
        let candidate = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard candidate >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var info = stat()
        guard fstat(candidate, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1,
              fchmod(candidate, 0o600) == 0, flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
            close(candidate)
            throw CocoaError(.fileLocking)
        }
        return candidate
    }

    private static func releaseInstanceLock(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

}
