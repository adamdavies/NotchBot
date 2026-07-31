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
        append(event: "SubagentStart", kind: "working", reason: nil, matcher: nil, expiry: nil, hookPath: hookPath, hooks: &hooks)
        append(event: "SubagentStop", kind: "cleared", reason: nil, matcher: nil, expiry: nil, hookPath: hookPath, hooks: &hooks)
        append(event: "PreToolUse", kind: "working", reason: nil, matcher: nil, expiry: nil, hookPath: hookPath, hooks: &hooks)
        append(event: "PermissionRequest", kind: "attention", reason: "Claude Code needs permission", matcher: nil, expiry: nil, hookPath: hookPath, hooks: &hooks)
        append(event: "Notification", kind: "attention", reason: "Claude Code needs input", matcher: "agent_needs_input", expiry: nil, hookPath: hookPath, hooks: &hooks)
        append(event: "Stop", kind: "attention", reason: "Claude Code finished working", matcher: nil, expiry: nil, hookPath: hookPath, hooks: &hooks)
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
                    !isReclaimableHandler($0, event: event, matcher: group["matcher"] as? String, hookPath: hookPath)
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

    /// Handlers we clean up before rewriting our own. Looser than `isOwnedHandler` so that
    /// malformed entries pointing at our helper are reclaimed rather than accumulating: an
    /// entry without `args` runs through a shell, and the space in "Application Support"
    /// splits the path, so Claude Code reports "No such file or directory" on every event.
    private static func isReclaimableHandler(
        _ handler: [String: Any],
        event: String,
        matcher: String?,
        hookPath: String
    ) -> Bool {
        if isOwnedHandler(handler, event: event, matcher: matcher, hookPath: hookPath) { return true }
        guard
            handler["type"] as? String == "command",
            handler["command"] as? String == hookPath
        else { return false }
        return !(handler["args"] is [String])
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
            let timeout = handler["timeout"] as? Int,
            let arguments = handler["args"] as? [String]
        else { return false }
        guard timeout == 5 || (event == "PermissionRequest" && timeout == 245) else { return false }
        return generatedHooks.contains(HookSignature(event: event, matcher: matcher, arguments: arguments))
    }

    private static var generatedHooks: Set<HookSignature> {
        Set([
            HookSignature(event: "UserPromptSubmit", matcher: nil, arguments: workingArguments),
            HookSignature(event: "SessionStart", matcher: nil, arguments: metadataArguments),
            HookSignature(event: "SubagentStart", matcher: nil, arguments: workingArguments),
            HookSignature(event: "SubagentStop", matcher: nil, arguments: clearedArguments),
            // Recognize and remove the v0.2.1 task metadata hook during migration.
            HookSignature(event: "TaskCreated", matcher: nil, arguments: metadataArguments),
            HookSignature(event: "PreToolUse", matcher: nil, arguments: workingArguments),
            HookSignature(event: "PermissionRequest", matcher: nil, arguments: permissionRequestArguments),
            HookSignature(event: "PermissionRequest", matcher: nil, arguments: legacyPermissionArguments),
            HookSignature(event: "Notification", matcher: "agent_needs_input", arguments: inputArguments),
            HookSignature(event: "Notification", matcher: "permission_prompt|agent_needs_input", arguments: permissionArguments),
            HookSignature(event: "Stop", matcher: nil, arguments: completionArguments),
            // Recognize and remove the expiring v0.2.1 completion hooks during migration.
            HookSignature(event: "Notification", matcher: "idle_prompt", arguments: legacyFinishedArguments),
            HookSignature(event: "Stop", matcher: nil, arguments: legacyFinishedArguments),
            HookSignature(event: "SessionEnd", matcher: nil, arguments: clearedArguments),
        ])
    }

    private static let workingArguments = ["--source", "claude", "--kind", "working"]
    private static let metadataArguments = ["--source", "claude", "--kind", "metadata"]
    private static let legacyPermissionArguments = ["--source", "claude", "--kind", "attention", "--reason", "Claude Code needs permission"]
    private static let permissionRequestArguments = legacyPermissionArguments + ["--mode", "permission"]
    private static let inputArguments = ["--source", "claude", "--kind", "attention", "--reason", "Claude Code needs input"]
    private static let permissionArguments = legacyPermissionArguments
    private static let completionArguments = ["--source", "claude", "--kind", "attention", "--reason", "Claude Code finished working"]
    private static let legacyFinishedArguments = completionArguments + ["--expires-after", "2.5"]
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
        if event == "PermissionRequest" { arguments += ["--mode", "permission"] }
        let handler: [String: Any] = [
            "type": "command",
            "command": hookPath,
            "args": arguments,
            "timeout": event == "PermissionRequest" ? 245 : 5,
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
