import Foundation

public enum ClaudeHooks {
    public static func containsManagedHandlers(in settings: [String: Any], hookPath: String) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.contains { event, value in
            guard let groups = value as? [[String: Any]] else { return false }
            return groups.contains { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return false }
                return handlers.contains {
                    isOwnedHandler($0, event: event, matcher: group["matcher"] as? String, hookPath: hookPath)
                }
            }
        }
    }

    public static func merging(into settings: [String: Any], hookPath: String) -> [String: Any] {
        var result = settings
        var hooks = removingHandlers(from: settings["hooks"] as? [String: Any] ?? [:], hookPath: hookPath)

        append(event: "UserPromptSubmit", kind: "working", reason: nil, matcher: nil, expiry: nil, hookPath: hookPath, hooks: &hooks)
        append(event: "SessionStart", kind: "metadata", reason: nil, matcher: nil, expiry: nil, hookPath: hookPath, hooks: &hooks)
        append(event: "TaskCreated", kind: "metadata", reason: nil, matcher: nil, expiry: nil, hookPath: hookPath, hooks: &hooks)
        append(event: "PreToolUse", kind: "working", reason: nil, matcher: nil, expiry: nil, hookPath: hookPath, hooks: &hooks)
        append(event: "PermissionRequest", kind: "attention", reason: "Claude Code needs permission", matcher: nil, expiry: nil, hookPath: hookPath, hooks: &hooks)
        append(event: "Notification", kind: "attention", reason: "Claude Code needs permission", matcher: "permission_prompt|agent_needs_input", expiry: nil, hookPath: hookPath, hooks: &hooks)
        append(event: "Notification", kind: "attention", reason: "Claude Code finished working", matcher: "idle_prompt", expiry: 2.5, hookPath: hookPath, hooks: &hooks)
        append(event: "Stop", kind: "attention", reason: "Claude Code finished working", matcher: nil, expiry: 2.5, hookPath: hookPath, hooks: &hooks)
        append(event: "SessionEnd", kind: "cleared", reason: nil, matcher: nil, expiry: nil, hookPath: hookPath, hooks: &hooks)
        result["hooks"] = hooks
        return result
    }

    public static func removing(from settings: [String: Any], hookPath: String) -> [String: Any] {
        var result = settings
        result["hooks"] = removingHandlers(from: settings["hooks"] as? [String: Any] ?? [:], hookPath: hookPath)
        return result
    }

    private static func removingHandlers(from hooks: [String: Any], hookPath: String) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                result[event] = value
                continue
            }
            let remaining = groups.compactMap { group -> [String: Any]? in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let kept = handlers.filter {
                    !isOwnedHandler($0, event: event, matcher: group["matcher"] as? String, hookPath: hookPath)
                }
                guard !kept.isEmpty else { return nil }
                var updated = group
                updated["hooks"] = kept
                return updated
            }
            if !remaining.isEmpty { result[event] = remaining }
        }
        return result
    }

    private static func isOwnedHandler(
        _ handler: [String: Any],
        event: String,
        matcher: String?,
        hookPath: String
    ) -> Bool {
        guard
            handler["type"] as? String == "command",
            handler["command"] as? String == hookPath,
            handler["timeout"] as? Int == 5,
            let arguments = handler["args"] as? [String]
        else { return false }
        return generatedHooks.contains(HookSignature(event: event, matcher: matcher, arguments: arguments))
    }

    private static var generatedHooks: Set<HookSignature> {
        Set([
            HookSignature(event: "UserPromptSubmit", matcher: nil, arguments: workingArguments),
            HookSignature(event: "SessionStart", matcher: nil, arguments: metadataArguments),
            HookSignature(event: "TaskCreated", matcher: nil, arguments: metadataArguments),
            HookSignature(event: "PreToolUse", matcher: nil, arguments: workingArguments),
            HookSignature(event: "PermissionRequest", matcher: nil, arguments: permissionArguments),
            HookSignature(event: "Notification", matcher: "permission_prompt|agent_needs_input", arguments: permissionArguments),
            HookSignature(event: "Notification", matcher: "idle_prompt", arguments: finishedArguments),
            HookSignature(event: "Stop", matcher: nil, arguments: finishedArguments),
            HookSignature(event: "SessionEnd", matcher: nil, arguments: clearedArguments),
        ])
    }

    private static let workingArguments = ["--source", "claude", "--kind", "working"]
    private static let metadataArguments = ["--source", "claude", "--kind", "metadata"]
    private static let permissionArguments = ["--source", "claude", "--kind", "attention", "--reason", "Claude Code needs permission"]
    private static let finishedArguments = ["--source", "claude", "--kind", "attention", "--reason", "Claude Code finished working", "--expires-after", "2.5"]
    private static let clearedArguments = ["--source", "claude", "--kind", "cleared"]

    private static func append(
        event: String,
        kind: String,
        reason: String?,
        matcher: String?,
        expiry: TimeInterval?,
        hookPath: String,
        hooks: inout [String: Any]
    ) {
        var arguments = ["--source", "claude", "--kind", kind]
        if let reason { arguments += ["--reason", reason] }
        if let expiry { arguments += ["--expires-after", String(expiry)] }
        let handler: [String: Any] = [
            "type": "command",
            "command": hookPath,
            "args": arguments,
            "timeout": 5,
        ]
        var group: [String: Any] = ["hooks": [handler]]
        if let matcher { group["matcher"] = matcher }
        var groups = hooks[event] as? [[String: Any]] ?? []
        groups.append(group)
        hooks[event] = groups
    }
}

private struct HookSignature: Hashable {
    let event: String
    let matcher: String?
    let arguments: [String]
}
