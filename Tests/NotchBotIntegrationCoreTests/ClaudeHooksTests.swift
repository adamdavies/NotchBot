import Foundation
import Testing
@testable import NotchBotIntegrationCore

@Test func mergePreservesUnrelatedSettingsAndIsIdempotent() throws {
    let path = "/tmp/notchbot-hook"
    let original: [String: Any] = [
        "theme": "dark",
        "hooks": [
            "Stop": [[
                "hooks": [["type": "command", "command": "/tmp/other", "args": ["--keep"]]],
            ]],
        ],
    ]
    let once = ClaudeHooks.merging(into: original, hookPath: path)
    let twice = ClaudeHooks.merging(into: once, hookPath: path)

    #expect(once["theme"] as? String == "dark")
    #expect(canonicalJSON(once) == canonicalJSON(twice))
}

@Test func removalDeletesOnlyVerifiedGeneratedHandlers() throws {
    let path = "/tmp/notchbot-hook"
    var settings = ClaudeHooks.merging(into: [:], hookPath: path)
    var hooks = settings["hooks"] as! [String: Any]
    hooks["Custom"] = [[
        "hooks": [
            ["type": "command", "command": path, "args": ["--user-owned"]],
            ["type": "command", "command": "/tmp/other", "args": ["--source", "claude", "--kind", "working"]],
        ],
    ]]
    settings["hooks"] = hooks

    let removed = ClaudeHooks.removing(from: settings, hookPath: path)
    let remainingHooks = removed["hooks"] as! [String: Any]
    let customGroups = remainingHooks["Custom"] as! [[String: Any]]
    let customHandlers = customGroups[0]["hooks"] as! [[String: Any]]
    #expect(customHandlers.count == 2)
    #expect(customHandlers[0]["args"] as? [String] == ["--user-owned"])
    #expect(customHandlers[1]["command"] as? String == "/tmp/other")
    #expect(remainingHooks["Stop"] == nil)
}

@Test func mergeAddsSubagentHooksAndMigratesPreviousHookSet() {
    let path = "/tmp/notchbot-hook"
    let previous: [String: Any] = [
        "hooks": [
            "UserPromptSubmit": [[
                "hooks": [[
                    "type": "command", "command": path,
                    "args": ["--source", "claude", "--kind", "working"], "timeout": 5,
                ]],
            ]],
            "TaskCreated": [[
                "hooks": [[
                    "type": "command", "command": path,
                    "args": ["--source", "claude", "--kind", "metadata"], "timeout": 5,
                ]],
            ]],
            "Custom": [[
                "hooks": [[
                    "type": "command", "command": path,
                    "args": ["--source", "claude", "--kind", "working"], "timeout": 5,
                ]],
            ]],
        ],
    ]

    let merged = ClaudeHooks.merging(into: previous, hookPath: path)
    let hooks = merged["hooks"] as! [String: Any]
    #expect((hooks["SessionStart"] as? [[String: Any]])?.count == 1)
    #expect((hooks["SubagentStart"] as? [[String: Any]])?.count == 1)
    #expect((hooks["SubagentStop"] as? [[String: Any]])?.count == 1)
    #expect(hooks["TaskCreated"] == nil)
    #expect(hooks["Notification"].flatMap { $0 as? [[String: Any]] }?.contains {
        $0["matcher"] as? String == "idle_prompt"
    } == false)
    let stopGroups = hooks["Stop"] as! [[String: Any]]
    let stopHandlers = stopGroups[0]["hooks"] as! [[String: Any]]
    #expect(stopHandlers[0]["args"] as? [String] == [
        "--source", "claude", "--kind", "attention", "--reason", "Claude Code finished working",
    ])
    #expect((hooks["UserPromptSubmit"] as? [[String: Any]])?.count == 1)
    #expect((hooks["Custom"] as? [[String: Any]])?.count == 1)
    let permissionGroups = hooks["PermissionRequest"] as! [[String: Any]]
    let permissionHandler = (permissionGroups[0]["hooks"] as! [[String: Any]])[0]
    #expect(permissionHandler["timeout"] as? Int == 245)
    #expect(permissionHandler["args"] as? [String] == [
        "--source", "claude", "--kind", "attention", "--reason", "Claude Code needs permission",
        "--mode", "permission",
    ])
    let notificationGroups = hooks["Notification"] as! [[String: Any]]
    #expect(notificationGroups.count == 1)
    #expect(notificationGroups[0]["matcher"] as? String == "agent_needs_input")
}

private func canonicalJSON(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
