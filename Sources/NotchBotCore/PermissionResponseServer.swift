import CryptoKit
import Darwin
import Foundation

public final class PermissionResponseServer {
    public let responseToken: String

    private var descriptor: Int32 = -1
    private var device: dev_t?
    private var inode: ino_t?

    public init() {
        responseToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    deinit {
        stop()
    }

    public func start() throws {
        guard descriptor < 0 else { return }
        _ = try EventKeyStore.loadOrCreateKey()
        let path = NotchBotPaths.permissionSocketPath(responseToken: responseToken)
        var existing = stat()
        guard lstat(path, &existing) != 0, errno == ENOENT else {
            throw CocoaError(.fileWriteFileExists)
        }

        let candidate = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard candidate >= 0 else { throw UnixDatagramError.socketCreation(errno) }
        var address = try UnixDatagramClient.socketAddress(path: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(candidate, $0, UnixDatagramClient.socketLength(for: path))
            }
        }
        guard result == 0 else {
            close(candidate)
            throw CocoaError(.fileWriteUnknown)
        }

        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == getuid(), chmod(path, 0o600) == 0,
              lstat(path, &info) == 0, (info.st_mode & 0o777) == 0o600 else {
            close(candidate)
            unlink(path)
            throw CocoaError(.fileWriteNoPermission)
        }
        descriptor = candidate
        device = info.st_dev
        inode = info.st_ino
    }

    public func receive(timeout: TimeInterval) throws -> AgentPermissionDecision? {
        guard descriptor >= 0, timeout.isFinite, timeout > 0 else { return nil }
        let key = try EventKeyStore.loadOrCreateKey()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(min(remaining * 1_000, Double(Int32.max)).rounded(.up))
            let pollResult = Darwin.poll(&pollDescriptor, 1, milliseconds)
            if pollResult < 0, errno == EINTR { continue }
            guard pollResult > 0 else { return nil }

            var buffer = [UInt8](repeating: 0, count: AgentPermissionResponseValidator.maximumDatagramBytes + 1)
            let count = recv(descriptor, &buffer, buffer.count, MSG_TRUNC)
            guard count > 0, count <= AgentPermissionResponseValidator.maximumDatagramBytes else { continue }
            let envelope = Data(buffer.prefix(count))
            guard let plaintext = try? SecurePermissionResponseEnvelope.open(envelope, using: key),
                  let response = try? JSONDecoder().decode(AgentPermissionResponse.self, from: plaintext),
                  response.responseToken == responseToken else { continue }
            return response.decision
        }
    }

    public func stop() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
        let path = NotchBotPaths.permissionSocketPath(responseToken: responseToken)
        var info = stat()
        if let device, let inode, lstat(path, &info) == 0,
           (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid(),
           info.st_dev == device, info.st_ino == inode {
            unlink(path)
        }
        device = nil
        inode = nil
    }
}
