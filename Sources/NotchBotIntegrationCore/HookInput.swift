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
            ["working", "attention", "cleared", "metadata"].contains(kind),
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
                sessionID: try validatedIdentifier(decoded.sessionID),
                cwd: bounded(decoded.cwd, bytes: 1_024),
                lastAssistantMessage: bounded(decoded.lastAssistantMessage, bytes: 1_024),
                sessionTitle: boundedLabel(decoded.sessionTitle),
                taskSubject: boundedLabel(decoded.taskSubject),
                agentType: boundedLabel(decoded.agentType),
                taskLabel: boundedLabel(decoded.taskLabel)
            )
        }
        guard let decoded = try? JSONDecoder().decode(BasicPayload.self, from: input) else {
            throw HookInputError.invalidJSON
        }
        return HookPayload(
            sessionID: try validatedIdentifier(decoded.sessionID),
            cwd: bounded(decoded.cwd, bytes: 1_024),
            lastAssistantMessage: nil,
            sessionTitle: boundedLabel(decoded.sessionTitle),
            taskSubject: boundedLabel(decoded.taskSubject),
            agentType: boundedLabel(decoded.agentType),
            taskLabel: boundedLabel(decoded.taskLabel)
        )
    }

    public static func taskLabel(from payload: HookPayload?, source: String) -> String? {
        let directoryName = payload?.cwd.flatMap { value -> String? in
            let name = URL(fileURLWithPath: value).lastPathComponent
            return name.isEmpty ? nil : name
        }
        let candidate = source == "claude"
            ? (payload?.sessionTitle ?? payload?.taskSubject ?? payload?.agentType ?? directoryName ?? "Claude Code")
            : (payload?.taskLabel ?? directoryName ?? "OpenCode")
        return normalizedLabel(candidate)
    }

    private static func bounded(_ value: String?, bytes maximum: Int) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= maximum else { return nil }
        return value
    }

    private static func validatedIdentifier(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard !value.isEmpty, value.utf8.count <= 128,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw HookInputError.invalidJSON
        }
        return value
    }

    private static func boundedLabel(_ value: String?) -> String? {
        normalizedLabel(value)
    }

    private static func normalizedLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        var result = ""
        for character in normalized {
            guard result.count < 100 else { break }
            let candidate = result + String(character)
            guard candidate.utf8.count <= 512 else { break }
            result = candidate
        }
        return result.isEmpty ? nil : result
    }
}

public struct HookPayload: Equatable, Sendable {
    public let sessionID: String?
    public let cwd: String?
    public let lastAssistantMessage: String?
    public let sessionTitle: String?
    public let taskSubject: String?
    public let agentType: String?
    public let taskLabel: String?
}

private struct BasicPayload: Decodable {
    let sessionID: String?
    let cwd: String?
    let sessionTitle: String?
    let taskSubject: String?
    let agentType: String?
    let taskLabel: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case sessionTitle = "session_title"
        case taskSubject = "task_subject"
        case agentType = "agent_type"
        case taskLabel = "task_label"
    }
}

private struct ExcerptPayload: Decodable {
    let sessionID: String?
    let cwd: String?
    let lastAssistantMessage: String?
    let sessionTitle: String?
    let taskSubject: String?
    let agentType: String?
    let taskLabel: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case lastAssistantMessage = "last_assistant_message"
        case sessionTitle = "session_title"
        case taskSubject = "task_subject"
        case agentType = "agent_type"
        case taskLabel = "task_label"
    }
}
