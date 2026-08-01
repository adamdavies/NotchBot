import CryptoKit
import Darwin
import Foundation

public enum EventSecurityError: Error, LocalizedError, Equatable {
    case insecureSupportDirectory
    case insecureKeyFile
    case invalidKey
    case invalidEnvelope
    case envelopeTooLarge

    public var errorDescription: String? {
        switch self {
        case .insecureSupportDirectory: "NotchBot's Application Support directory is not secure."
        case .insecureKeyFile: "NotchBot's event key file is not secure."
        case .invalidKey: "NotchBot's event key is invalid."
        case .invalidEnvelope: "The NotchBot event envelope is invalid or unauthenticated."
        case .envelopeTooLarge: "The NotchBot event envelope exceeds 8 KiB."
        }
    }
}

public enum EventKeyStore {
    public static var keyURL: URL {
        NotchBotPaths.applicationSupportDirectory.appendingPathComponent("event.key")
    }

    // This rejects messages from processes without the key; it does not isolate NotchBot
    // from another malicious process already running as the same user and able to read it.
    public static func loadOrCreateKey(
        applicationSupportDirectory: URL = NotchBotPaths.applicationSupportDirectory
    ) throws -> SymmetricKey {
        try secureSupportDirectory(applicationSupportDirectory)
        let keyURL = applicationSupportDirectory.appendingPathComponent("event.key")

        var info = stat()
        if lstat(keyURL.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
                  (info.st_mode & 0o777) == 0o600, info.st_nlink == 1 else {
                throw EventSecurityError.insecureKeyFile
            }
            let descriptor = open(keyURL.path, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw EventSecurityError.insecureKeyFile }
            defer { close(descriptor) }
            var openedInfo = stat()
            guard fstat(descriptor, &openedInfo) == 0, (openedInfo.st_mode & S_IFMT) == S_IFREG,
                  openedInfo.st_uid == getuid(), (openedInfo.st_mode & 0o777) == 0o600,
                  openedInfo.st_nlink == 1, openedInfo.st_dev == info.st_dev,
                  openedInfo.st_ino == info.st_ino else {
                throw EventSecurityError.insecureKeyFile
            }
            var bytes = [UInt8](repeating: 0, count: 33)
            let byteCount = bytes.count
            var count = 0
            while count < byteCount {
                let result = bytes.withUnsafeMutableBytes {
                    read(descriptor, $0.baseAddress?.advanced(by: count), byteCount - count)
                }
                if result < 0, errno == EINTR { continue }
                guard result >= 0 else { throw EventSecurityError.insecureKeyFile }
                if result == 0 { break }
                count += result
            }
            guard count == 32 else { throw EventSecurityError.invalidKey }
            return SymmetricKey(data: Data(bytes.prefix(32)))
        }
        guard errno == ENOENT else { throw EventSecurityError.insecureKeyFile }

        let keyData = Data(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        let temporaryURL = applicationSupportDirectory
            .appendingPathComponent(".event-key-\(UUID().uuidString).tmp")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw EventSecurityError.insecureKeyFile }
        var temporaryExists = true
        defer {
            close(descriptor)
            if temporaryExists { unlink(temporaryURL.path) }
        }
        var written = 0
        while written < keyData.count {
            let result = keyData.withUnsafeBytes {
                write(descriptor, $0.baseAddress?.advanced(by: written), $0.count - written)
            }
            if result < 0, errno == EINTR { continue }
            guard result > 0 else {
                throw EventSecurityError.insecureKeyFile
            }
            written += result
        }
        var createdInfo = stat()
        guard fstat(descriptor, &createdInfo) == 0, createdInfo.st_uid == getuid(),
               (createdInfo.st_mode & 0o777) == 0o600, createdInfo.st_nlink == 1,
               fsync(descriptor) == 0 else {
            throw EventSecurityError.insecureKeyFile
        }
        guard renameatx_np(
            AT_FDCWD,
            temporaryURL.path,
            AT_FDCWD,
            keyURL.path,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            if errno == EEXIST {
                return try loadOrCreateKey(applicationSupportDirectory: applicationSupportDirectory)
            }
            throw EventSecurityError.insecureKeyFile
        }
        temporaryExists = false
        return SymmetricKey(data: keyData)
    }

    private static func secureSupportDirectory(_ directory: URL) throws {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw EventSecurityError.insecureSupportDirectory }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } else {
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
                throw EventSecurityError.insecureSupportDirectory
            }
        }
        guard chmod(directory.path, 0o700) == 0 else {
            throw EventSecurityError.insecureSupportDirectory
        }
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else {
            throw EventSecurityError.insecureSupportDirectory
        }
    }
}

public enum SecureEventEnvelope {
    private static let header = Data([0x4e, 0x42, 0x30, 0x32]) // NB02

    public static func seal(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        guard plaintext.count <= AgentEventValidator.maximumDatagramBytes else {
            throw EventSecurityError.envelopeTooLarge
        }
        let event = try JSONDecoder().decode(AgentEvent.self, from: plaintext)
        try AgentEventValidator.validate(event, encodedSize: plaintext.count)
        let box = try ChaChaPoly.seal(plaintext, using: key, authenticating: header)
        let envelope = header + box.combined
        guard envelope.count <= AgentEventValidator.maximumDatagramBytes else {
            throw EventSecurityError.envelopeTooLarge
        }
        return envelope
    }

    public static func open(_ envelope: Data, using key: SymmetricKey, now: Date = Date()) throws -> Data {
        guard envelope.count <= AgentEventValidator.maximumDatagramBytes else {
            throw EventSecurityError.envelopeTooLarge
        }
        guard envelope.count >= header.count + 12 + 16, envelope.starts(with: header) else {
            throw EventSecurityError.invalidEnvelope
        }
        do {
            let box = try ChaChaPoly.SealedBox(combined: envelope.dropFirst(header.count))
            let plaintext = try ChaChaPoly.open(box, using: key, authenticating: header)
            let event = try JSONDecoder().decode(AgentEvent.self, from: plaintext)
            try AgentEventValidator.validate(event, encodedSize: plaintext.count, now: now)
            return plaintext
        } catch {
            throw EventSecurityError.invalidEnvelope
        }
    }

    public static func replayIdentifier(for envelope: Data) -> Data? {
        guard envelope.count >= header.count + 12, envelope.starts(with: header) else { return nil }
        return Data(envelope[header.count..<(header.count + 12)])
    }
}

public enum SecurePermissionResponseEnvelope {
    private static let header = Data([0x4e, 0x42, 0x50, 0x31]) // NBP1

    public static func seal(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        guard plaintext.count <= AgentPermissionResponseValidator.maximumDatagramBytes else {
            throw EventSecurityError.envelopeTooLarge
        }
        let response = try JSONDecoder().decode(AgentPermissionResponse.self, from: plaintext)
        try AgentPermissionResponseValidator.validate(response, encodedSize: plaintext.count)
        let box = try ChaChaPoly.seal(plaintext, using: key, authenticating: header)
        let envelope = header + box.combined
        guard envelope.count <= AgentPermissionResponseValidator.maximumDatagramBytes else {
            throw EventSecurityError.envelopeTooLarge
        }
        return envelope
    }

    public static func open(_ envelope: Data, using key: SymmetricKey, now: Date = Date()) throws -> Data {
        guard envelope.count <= AgentPermissionResponseValidator.maximumDatagramBytes else {
            throw EventSecurityError.envelopeTooLarge
        }
        guard envelope.count >= header.count + 12 + 16, envelope.starts(with: header) else {
            throw EventSecurityError.invalidEnvelope
        }
        do {
            let box = try ChaChaPoly.SealedBox(combined: envelope.dropFirst(header.count))
            let plaintext = try ChaChaPoly.open(box, using: key, authenticating: header)
            let response = try JSONDecoder().decode(AgentPermissionResponse.self, from: plaintext)
            try AgentPermissionResponseValidator.validate(response, encodedSize: plaintext.count, now: now)
            return plaintext
        } catch {
            throw EventSecurityError.invalidEnvelope
        }
    }
}

public struct ReplayProtection: Sendable {
    private let capacity: Int
    private var ring: [Data?]
    private var nextIndex = 0
    private var identifiers: Set<Data> = []

    public init(capacity: Int = 1_024) {
        self.capacity = max(1, capacity)
        self.ring = Array(repeating: nil, count: max(1, capacity))
    }

    public mutating func accept(_ identifier: Data) -> Bool {
        guard !identifiers.contains(identifier) else { return false }
        if let evicted = ring[nextIndex] {
            identifiers.remove(evicted)
        }
        ring[nextIndex] = identifier
        nextIndex = (nextIndex + 1) % capacity
        identifiers.insert(identifier)
        return true
    }
}

public struct TokenBucket: Sendable {
    private let capacity: Double
    private let refillPerSecond: Double
    private var tokens: Double
    private var lastRefill: Date

    public init(capacity: Int, refillPerSecond: Double, now: Date = Date()) {
        self.capacity = Double(max(1, capacity))
        self.refillPerSecond = max(0, refillPerSecond)
        self.tokens = Double(max(1, capacity))
        self.lastRefill = now
    }

    public mutating func consume(now: Date = Date()) -> Bool {
        let elapsed = max(0, now.timeIntervalSince(lastRefill))
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        lastRefill = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}
