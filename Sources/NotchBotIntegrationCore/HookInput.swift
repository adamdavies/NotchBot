import Foundation

public struct HookOptions: Equatable, Sendable {
    public let source: String
    public let kind: String
    public let reason: String?
    public let expiresAfter: TimeInterval?
}

public enum HookInputError: Error, Equatable {
    case invalidArguments
    case inputTooLarge
    case invalidJSON
}

public enum HookInput {
    public static let maximumByteCount = 64 * 1_024

    public static func parse(arguments: [String]) throws -> HookOptions {
        var values: [String: String] = [:]
        var index = 0
        let allowed = Set(["--source", "--kind", "--reason", "--expires-after"])

        while index < arguments.count {
            let name = arguments[index]
            guard
                allowed.contains(name),
                values[name] == nil,
                index + 1 < arguments.count
            else {
                throw HookInputError.invalidArguments
            }
            values[name] = arguments[index + 1]
            index += 2
        }

        guard
            let source = values["--source"],
            ["claude", "opencode"].contains(source),
            let kind = values["--kind"],
            ["working", "attention", "cleared"].contains(kind),
            values["--reason"].map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true
        else {
            throw HookInputError.invalidArguments
        }

        let expiresAfter: TimeInterval?
        if let value = values["--expires-after"] {
            guard let parsed = TimeInterval(value), parsed.isFinite, parsed >= 0, parsed <= 300 else {
                throw HookInputError.invalidArguments
            }
            expiresAfter = parsed
        } else {
            expiresAfter = nil
        }

        return HookOptions(
            source: source,
            kind: kind,
            reason: values["--reason"],
            expiresAfter: expiresAfter
        )
    }

    public static func decodePayload(
        from input: Data,
        assistantExcerptsEnabled: Bool
    ) throws -> HookPayload? {
        guard input.count <= maximumByteCount else { throw HookInputError.inputTooLarge }
        guard !input.isEmpty else { return nil }
        if assistantExcerptsEnabled {
            guard let decoded = try? JSONDecoder().decode(ExcerptPayload.self, from: input) else {
                throw HookInputError.invalidJSON
            }
            return HookPayload(
                sessionID: bounded(decoded.sessionID, bytes: 128),
                cwd: bounded(decoded.cwd, bytes: 1_024),
                lastAssistantMessage: bounded(decoded.lastAssistantMessage, bytes: 1_024)
            )
        }
        guard let decoded = try? JSONDecoder().decode(BasicPayload.self, from: input) else {
            throw HookInputError.invalidJSON
        }
        return HookPayload(
            sessionID: bounded(decoded.sessionID, bytes: 128),
            cwd: bounded(decoded.cwd, bytes: 1_024),
            lastAssistantMessage: nil
        )
    }

    private static func bounded(_ value: String?, bytes maximum: Int) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= maximum else { return nil }
        return value
    }
}

public struct HookPayload: Equatable, Sendable {
    public let sessionID: String?
    public let cwd: String?
    public let lastAssistantMessage: String?
}

private struct BasicPayload: Decodable {
    let sessionID: String?
    let cwd: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
    }
}

private struct ExcerptPayload: Decodable {
    let sessionID: String?
    let cwd: String?
    let lastAssistantMessage: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case lastAssistantMessage = "last_assistant_message"
    }
}
