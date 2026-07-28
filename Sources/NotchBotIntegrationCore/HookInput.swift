import Foundation

public struct HookOptions: Equatable, Sendable {
    public let source: String
    public let kind: String
    public let reason: String?
    public let expiresAfter: TimeInterval?
    public let permissionRequest: Bool
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
        let allowed = Set(["--source", "--kind", "--reason", "--expires-after", "--mode"])

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
        let mode = values["--mode"] ?? "event"
        guard ["event", "permission"].contains(mode), mode != "permission" || kind == "attention" else {
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
            expiresAfter: expiresAfter,
            permissionRequest: mode == "permission"
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
                agentType: boundedLabel(decoded.agentType),
                taskLabel: boundedLabel(decoded.taskLabel),
                agentID: try validatedIdentifier(decoded.agentID),
                parentSessionID: try validatedIdentifier(decoded.parentSessionID),
                permissionSummary: permissionSummary(decoded.permissionSummary),
                permissionCanAlways: decoded.permissionCanAlways ?? false
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
            agentType: boundedLabel(decoded.agentType),
            taskLabel: boundedLabel(decoded.taskLabel),
            agentID: try validatedIdentifier(decoded.agentID),
            parentSessionID: try validatedIdentifier(decoded.parentSessionID),
            permissionSummary: permissionSummary(decoded.permissionSummary),
            permissionCanAlways: decoded.permissionCanAlways ?? false
        )
    }

    public static func taskLabel(from payload: HookPayload?, source: String) -> String? {
        let directoryName = payload?.cwd.flatMap { value -> String? in
            let name = URL(fileURLWithPath: value).lastPathComponent
            return name.isEmpty ? nil : name
        }
        let candidate = source == "claude"
            ? (payload?.sessionTitle ?? payload?.agentType ?? directoryName ?? "Claude Code")
            : (payload?.taskLabel ?? directoryName ?? "OpenCode")
        return normalizedLabel(candidate)
    }

    public static func subagentLabel(from payload: HookPayload?) -> String {
        normalizedLabel(payload?.agentType) ?? "Subagent"
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

    private static func permissionSummary(_ value: String?) -> String? {
        guard let value else { return nil }
        let sanitized = String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
        })
        let normalized = sanitized.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        var result = ""
        for character in normalized {
            guard result.count < 240 else { break }
            let candidate = result + String(character)
            guard candidate.utf8.count <= 1_024 else { break }
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
    public let agentType: String?
    public let taskLabel: String?
    public let agentID: String?
    public let parentSessionID: String?
    public let permissionSummary: String?
    public let permissionCanAlways: Bool
}

private struct BasicPayload: Decodable {
    let sessionID: String?
    let cwd: String?
    let sessionTitle: String?
    let agentType: String?
    let taskLabel: String?
    let agentID: String?
    let parentSessionID: String?
    let permissionSummary: String?
    let permissionCanAlways: Bool?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case sessionTitle = "session_title"
        case agentType = "agent_type"
        case taskLabel = "task_label"
        case agentID = "agent_id"
        case parentSessionID = "parent_session_id"
        case permissionSummary = "permission_summary"
        case permissionCanAlways = "permission_can_always"
    }
}

private struct ExcerptPayload: Decodable {
    let sessionID: String?
    let cwd: String?
    let lastAssistantMessage: String?
    let sessionTitle: String?
    let agentType: String?
    let taskLabel: String?
    let agentID: String?
    let parentSessionID: String?
    let permissionSummary: String?
    let permissionCanAlways: Bool?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case lastAssistantMessage = "last_assistant_message"
        case sessionTitle = "session_title"
        case agentType = "agent_type"
        case taskLabel = "task_label"
        case agentID = "agent_id"
        case parentSessionID = "parent_session_id"
        case permissionSummary = "permission_summary"
        case permissionCanAlways = "permission_can_always"
    }
}

public struct ClaudePermissionInput: Equatable, Sendable {
    public let summary: String
    public let suggestion: Data?

    public static func decode(from input: Data) throws -> Self {
        guard input.count <= HookInput.maximumByteCount else { throw HookInputError.inputTooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else {
            throw HookInputError.invalidJSON
        }
        let toolName = normalized(object["tool_name"] as? String, limit: 128) ?? "Tool"
        let toolInput = object["tool_input"] as? [String: Any] ?? [:]
        let detailKeys = ["command", "file_path", "path", "notebook_path", "url", "query", "pattern", "description"]
        let detail = detailKeys.lazy.compactMap { normalized(toolInput[$0] as? String, limit: 180) }.first
        let summary = normalized(detail.map { "\(toolName): \($0)" } ?? toolName, limit: 240) ?? "Tool permission"

        var suggestion: Data?
        if let suggestions = object["permission_suggestions"] as? [Any], suggestions.count == 1,
           suggestions[0] is [String: Any],
           let encoded = try? JSONSerialization.data(withJSONObject: suggestions[0]),
           encoded.count <= 16 * 1_024 {
            suggestion = encoded
        }
        return Self(summary: summary, suggestion: suggestion)
    }

    private static func normalized(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let sanitized = String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
        })
        let normalized = sanitized.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(limit))
    }
}

public enum ClaudePermissionOutput {
    public static func encode(
        decision: String,
        suggestion: Data?
    ) -> Data? {
        var nativeDecision: [String: Any]
        switch decision {
        case "allowOnce":
            nativeDecision = ["behavior": "allow"]
        case "alwaysAllow":
            guard let suggestion,
                  let object = try? JSONSerialization.jsonObject(with: suggestion) as? [String: Any] else { return nil }
            nativeDecision = ["behavior": "allow", "updatedPermissions": [object]]
        case "decline":
            nativeDecision = [
                "behavior": "deny",
                "message": "The user declined this permission request in NotchBot.",
                "interrupt": false,
            ]
        default:
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": nativeDecision,
            ],
        ])
    }
}
