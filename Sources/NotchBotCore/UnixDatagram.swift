import Darwin
import Foundation

public enum UnixDatagramError: Error, LocalizedError {
    case payloadTooLarge
    case pathTooLong
    case socketCreation(Int32)
    case send(Int32)

    public var errorDescription: String? {
        switch self {
        case .payloadTooLarge: "The NotchBot event exceeds 8 KiB."
        case .pathTooLong: "The NotchBot socket path is too long."
        case .socketCreation(let code): "Unable to create socket (errno \(code))."
        case .send(let code): "Unable to send event to NotchBot (errno \(code))."
        }
    }
}

public enum UnixDatagramClient {
    public static func send(_ data: Data, to path: String = NotchBotPaths.socketPath) throws {
        let envelope = try SecureEventEnvelope.seal(data, using: EventKeyStore.loadOrCreateKey())
        try sendEnvelope(envelope, maximumBytes: AgentEventValidator.maximumDatagramBytes, to: path)
    }

    public static func send(
        _ response: AgentPermissionResponse,
        to path: String? = nil
    ) throws {
        let plaintext = try JSONEncoder().encode(response)
        let envelope = try SecurePermissionResponseEnvelope.seal(
            plaintext,
            using: EventKeyStore.loadOrCreateKey()
        )
        try sendEnvelope(
            envelope,
            maximumBytes: AgentPermissionResponseValidator.maximumDatagramBytes,
            to: path ?? NotchBotPaths.permissionSocketPath(responseToken: response.responseToken)
        )
    }

    private static func sendEnvelope(_ envelope: Data, maximumBytes: Int, to path: String) throws {
        guard envelope.count <= maximumBytes else {
            throw UnixDatagramError.payloadTooLarge
        }
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            throw UnixDatagramError.socketCreation(errno)
        }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
            throw UnixDatagramError.socketCreation(errno)
        }

        var address = try socketAddress(path: path)
        let result = envelope.withUnsafeBytes { payload in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                    sendto(
                        descriptor,
                        payload.baseAddress,
                        payload.count,
                        0,
                        socketPointer,
                        socketLength(for: path)
                    )
                }
            }
        }
        guard result == envelope.count else {
            throw UnixDatagramError.send(errno)
        }
    }

    public static func socketAddress(path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8CString)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else {
            throw UnixDatagramError.pathTooLong
        }

        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.copyMemory(from: source)
            }
        }
        return address
    }

    public static func socketLength(for path: String) -> socklen_t {
        socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
    }
}
