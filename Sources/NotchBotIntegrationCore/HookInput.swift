import Foundation

public struct HookOptions: Equatable, Sendable {
    public let source: String
    public let kind: String
    public let reason: String?
    public let expiresAfter: TimeInterval?
    public let permissionRequest: Bool
    public let statusLine: Bool
}

public enum HookInputError: Error, Equatable {
    case invalidArguments
    case inputTooLarge
    case invalidJSON
}

/// A provider's context-window report as it arrives at the helper.
///
/// `nil` at the call site means the payload said nothing about usage and the app should keep
/// whatever it already has. `.unavailable` is an explicit retraction — the provider told us the
/// old figure no longer applies (compaction, a removed message, a response with no usable
/// context limit) and a stale percentage would be worse than none.
public enum ContextWindowUsage: Equatable, Sendable {
    case unavailable
    case percentage(Double)
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
            ["working", "attention", "cleared", "metadata", "request_resolved"].contains(kind),
            values["--reason"].map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true
        else {
            throw HookInputError.invalidArguments
        }
        let mode = values["--mode"] ?? "event"
        guard ["event", "permission", "statusline"].contains(mode) else {
            throw HookInputError.invalidArguments
        }
        guard mode != "permission" || kind == "attention" else {
            throw HookInputError.invalidArguments
        }
        guard mode != "statusline" || (source == "claude" && kind == "metadata") else {
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
            permissionRequest: mode == "permission",
            statusLine: mode == "statusline"
        )
    }

    public static func decodePayload(from input: Data) throws -> HookPayload? {
        guard input.count <= maximumByteCount else { throw HookInputError.inputTooLarge }
        guard !input.isEmpty else { return nil }
        guard let decoded = try? JSONDecoder().decode(BasicPayload.self, from: input) else {
            throw HookInputError.invalidJSON
        }
        let costUSD = decoded.costUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return HookPayload(
            sessionID: try validatedIdentifier(decoded.sessionID),
            cwd: bounded(decoded.cwd, bytes: 1_024),
            sessionTitle: boundedLabel(decoded.sessionTitle),
            agentType: boundedLabel(decoded.agentType),
            activityDescription: boundedLabel(decoded.activityDescription),
            claudeToolActivityDescription: claudeToolActivityDescription(from: decoded),
            agentID: try validatedIdentifier(decoded.agentID),
            parentSessionID: try validatedIdentifier(decoded.parentSessionID),
            permissionSummary: permissionSummary(decoded.permissionSummary),
            permissionContext: permissionSummary(decoded.permissionContext),
            permissionCanAlways: decoded.permissionCanAlways ?? false,
            requestID: try validatedIdentifier(decoded.requestID),
            requestKind: decoded.requestKind,
            requestState: decoded.requestState,
            costUSD: costUSD,
            costGeneration: try validatedIdentifier(decoded.costGeneration),
            contextWindow: contextWindowUsage(decoded.contextWindow)
        )
    }

    /// Maps the generated plugin's nested `context_window` object onto the three-state update.
    /// Only `used_percentage` is read, so token counts or model details sitting alongside it in a
    /// malformed payload are ignored rather than forwarded. A present-but-unusable number is
    /// treated as a retraction: we know the old figure is suspect and we have nothing to replace
    /// it with.
    private static func contextWindowUsage(_ value: ContextWindowJSON?) -> ContextWindowUsage? {
        guard let value else { return nil }
        guard let percentage = value.usedPercentage,
              percentage.isFinite, (0...100).contains(percentage) else { return .unavailable }
        return .percentage(percentage)
    }

    public static func sessionTitle(from payload: HookPayload?, source: String) -> String? {
        let directoryName = payload?.cwd.flatMap { value -> String? in
            let name = URL(fileURLWithPath: value).lastPathComponent
            return name.isEmpty ? nil : name
        }
        let candidate = source == "claude"
            ? (payload?.sessionTitle ?? directoryName ?? "Claude Code")
            : (payload?.sessionTitle ?? directoryName ?? "OpenCode")
        return normalizedLabel(candidate)
    }

    public static func subagentLabel(from payload: HookPayload?) -> String {
        normalizedLabel(payload?.agentType) ?? "Subagent"
    }

    public static func activityDescription(from payload: HookPayload?, source: String) -> String? {
        source == "claude" ? payload?.claudeToolActivityDescription : payload?.activityDescription
    }

    private static func claudeToolActivityDescription(from payload: BasicPayload) -> String? {
        guard let toolName = payload.toolName?.lowercased(), ["bash", "agent", "task"].contains(toolName) else {
            return nil
        }
        return boundedLabel(payload.toolInput?.description)
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
    public let sessionTitle: String?
    public let agentType: String?
    public let activityDescription: String?
    public let claudeToolActivityDescription: String?
    public let agentID: String?
    public let parentSessionID: String?
    public let permissionSummary: String?
    public let permissionContext: String?
    public let permissionCanAlways: Bool
    public let requestID: String?
    public let requestKind: String?
    public let requestState: String?
    public let costUSD: Double?
    public let costGeneration: String?
    public let contextWindow: ContextWindowUsage?
}

/// Shared shape for both provider paths: Claude's status line and the generated OpenCode plugin
/// each nest the final percentage under `context_window.used_percentage`. An object with no
/// percentage is the wire form of an explicit retraction.
private struct ContextWindowJSON: Decodable {
    let usedPercentage: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
    }
}

private struct BasicPayload: Decodable {
    let sessionID: String?
    let cwd: String?
    let sessionTitle: String?
    let agentType: String?
    let activityDescription: String?
    let toolName: String?
    let toolInput: ToolInput?
    let agentID: String?
    let parentSessionID: String?
    let permissionSummary: String?
    let permissionContext: String?
    let permissionCanAlways: Bool?
    let requestID: String?
    let requestKind: String?
    let requestState: String?
    let costUSD: Double?
    let costGeneration: String?
    let contextWindow: ContextWindowJSON?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case sessionTitle = "session_title"
        case agentType = "agent_type"
        case activityDescription = "activity_description"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case agentID = "agent_id"
        case parentSessionID = "parent_session_id"
        case permissionSummary = "permission_summary"
        case permissionContext = "permission_context"
        case permissionCanAlways = "permission_can_always"
        case requestID = "request_id"
        case requestKind = "request_kind"
        case requestState = "request_state"
        case costUSD = "cost_usd"
        case costGeneration = "cost_generation"
        case contextWindow = "context_window"
    }

    struct ToolInput: Decodable {
        let description: String?
    }
}

public struct StatusLinePayload: Equatable, Sendable {
    public let sessionID: String?
    public let costUSD: Double?
    public let contextWindow: ContextWindowUsage?
}

private struct StatusLineJSON: Decodable {
    let sessionID: String?
    let cost: StatusLineCost?
    let contextWindow: ContextWindowJSON?

    struct StatusLineCost: Decodable {
        let totalCostUSD: Double?
        enum CodingKeys: String, CodingKey {
            case totalCostUSD = "total_cost_usd"
        }
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cost
        case contextWindow = "context_window"
    }
}

extension HookInput {
    public static func decodeStatusLinePayload(from input: Data) throws -> StatusLinePayload? {
        guard input.count <= maximumByteCount else { throw HookInputError.inputTooLarge }
        guard !input.isEmpty else { return nil }
        guard let decoded = try? JSONDecoder().decode(StatusLineJSON.self, from: input) else {
            throw HookInputError.invalidJSON
        }
        let costUSD = decoded.cost?.totalCostUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return StatusLinePayload(
            sessionID: try validatedIdentifier(decoded.sessionID),
            costUSD: costUSD,
            // Older Claude builds omit `context_window` entirely; that stays a no-update rather
            // than clearing a percentage a newer session already reported.
            contextWindow: contextWindowUsage(decoded.contextWindow)
        )
    }
}

public struct ClaudePermissionInput: Equatable, Sendable {
    public let summary: String
    public let context: String?
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
        let summary = normalized(toolName, limit: 240) ?? "Tool permission"

        var suggestion: Data?
        if let suggestions = object["permission_suggestions"] as? [Any], suggestions.count == 1,
           suggestions[0] is [String: Any],
           let encoded = try? JSONSerialization.data(withJSONObject: suggestions[0]),
           encoded.count <= 16 * 1_024 {
            suggestion = encoded
        }
        return Self(summary: summary, context: detail, suggestion: suggestion)
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
