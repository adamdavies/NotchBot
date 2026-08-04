import Foundation
import Testing
@testable import NotchBotIntegrationCore

@Test func strictArgumentsAcceptOnlyStaticOptions() throws {
    let options = try HookInput.parse(arguments: [
        "--source", "opencode",
        "--kind", "attention",
        "--reason", "OpenCode finished working",
        "--expires-after", "2.5",
    ])
    #expect(options.source == "opencode")
    #expect(options.kind == "attention")
    #expect(options.expiresAfter == 2.5)
    #expect(!options.permissionRequest)

    let permission = try HookInput.parse(arguments: [
        "--source", "claude", "--kind", "attention", "--mode", "permission",
    ])
    #expect(permission.permissionRequest)

    #expect(throws: HookInputError.invalidArguments) {
        try HookInput.parse(arguments: ["--source", "opencode", "--kind", "working", "--session", "secret"])
    }
    #expect(throws: HookInputError.invalidArguments) {
        try HookInput.parse(arguments: ["--source", "opencode", "--source", "claude", "--kind", "working"])
    }
}

@Test func permissionInputIsBoundedAndKeepsOnlyOneNativeSuggestion() throws {
    let data = Data("""
    {
      "tool_name":"Bash",
      "tool_input":{"command":"  npm   test  ","private":"ignored"},
      "permission_suggestions":[
        {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test"}],"behavior":"allow","destination":"localSettings"}
      ]
    }
    """.utf8)
    let input = try ClaudePermissionInput.decode(from: data)
    #expect(input.summary == "Bash")
    #expect(input.context == "npm test")
    #expect(input.suggestion != nil)

    let always = ClaudePermissionOutput.encode(decision: "alwaysAllow", suggestion: input.suggestion)
    let object = try JSONSerialization.jsonObject(with: always!) as! [String: Any]
    let hookOutput = object["hookSpecificOutput"] as! [String: Any]
    let decision = hookOutput["decision"] as! [String: Any]
    #expect(decision["behavior"] as? String == "allow")
    #expect((decision["updatedPermissions"] as? [[String: Any]])?.count == 1)

    let ambiguous = try ClaudePermissionInput.decode(from: Data("""
    {"tool_name":"Edit","tool_input":{"file_path":"/tmp/a"},"permission_suggestions":[{},{}]}
    """.utf8))
    #expect(ambiguous.summary == "Edit")
    #expect(ambiguous.context == "/tmp/a")
    #expect(ambiguous.suggestion == nil)
    #expect(ClaudePermissionOutput.encode(decision: "alwaysAllow", suggestion: nil) == nil)
}

@Test func openCodePermissionContextIsAllowlistedAndBounded() throws {
    let data = Data("""
    {
      "session_id":"session",
      "permission_summary":"External directory · /tmp/*",
      "permission_context":"  rm   /tmp/example  ",
      "permission_can_always":true,
      "request_id":"per-test",
      "request_kind":"permission",
      "request_state":"opened",
      "raw_event":{"secret":"ignored"}
    }
    """.utf8)
    let payload = try HookInput.decodePayload(from: data)

    #expect(payload?.permissionSummary == "External directory · /tmp/*")
    #expect(payload?.permissionContext == "rm /tmp/example")
    #expect(payload?.permissionCanAlways == true)
    #expect(payload?.requestID == "per-test")
    #expect(payload?.requestKind == "permission")
    #expect(payload?.requestState == "opened")
}

@Test func declineOutputDoesNotInterruptClaude() throws {
    let data = ClaudePermissionOutput.encode(decision: "decline", suggestion: nil)!
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let hookOutput = object["hookSpecificOutput"] as! [String: Any]
    let decision = hookOutput["decision"] as! [String: Any]
    #expect(decision["behavior"] as? String == "deny")
    #expect(decision["interrupt"] as? Bool == false)
}

@Test func inputIsBoundedAndOnlyWhitelistedFieldsAreDecoded() throws {
    let data = Data("""
    {"session_id":"session","cwd":"/tmp/project","last_assistant_message":"private result","prompt":"ignored"}
    """.utf8)
    let payload = try HookInput.decodePayload(from: data)
    let withoutPrivateFields = try HookInput.decodePayload(from: Data(
        "{\"session_id\":\"session\",\"cwd\":\"/tmp/project\"}".utf8
    ))

    #expect(payload?.sessionID == "session")
    #expect(payload?.cwd == "/tmp/project")
    #expect(payload == withoutPrivateFields)

    let overflow = Data(repeating: 0x20, count: HookInput.maximumByteCount + 1)
    #expect(throws: HookInputError.inputTooLarge) {
        try HookInput.decodePayload(from: overflow)
    }
}

@Test func oversizedSessionIdentifiersAreRejected() throws {
    let longSession = String(repeating: "s", count: 129)
    let data = try JSONSerialization.data(withJSONObject: ["session_id": longSession])
    #expect(throws: HookInputError.invalidJSON) {
        try HookInput.decodePayload(from: data)
    }

    #expect(throws: HookInputError.invalidArguments) {
        try HookInput.parse(arguments: [
            "--source", "claude", "--kind", "attention", "--expires-after", "301",
        ])
    }
}

@Test func sessionMetadataIsAllowlistedAndUsesClaudePrecedence() throws {
    let data = Data("""
    {
      "session_id":"session",
      "cwd":"/tmp/project",
      "session_title":"  Session   title  ",
      "task_subject":"Task subject",
      "agent_type":"Explore",
      "activity_description":"OpenCode activity",
      "tool_name":"Bash",
      "tool_input":{"description":"  Run   focused tests  ","command":"private command"},
      "prompt":"private prompt",
      "task_description":"private description",
      "transcript":"private transcript"
    }
    """.utf8)
    let payload = try HookInput.decodePayload(from: data)

    #expect(payload?.sessionTitle == "Session title")
    #expect(payload?.agentType == "Explore")
    #expect(HookInput.sessionTitle(from: payload, source: "claude") == "Session title")
    #expect(HookInput.sessionTitle(from: payload, source: "opencode") == "Session title")
    #expect(HookInput.activityDescription(from: payload, source: "claude") == "Run focused tests")
    #expect(HookInput.activityDescription(from: payload, source: "opencode") == "OpenCode activity")
}

@Test func sessionTitleFallbacksAreBoundedAndIgnoreResponseText() throws {
    let data = Data("""
    {"cwd":"/tmp/project","last_assistant_message":"private result","prompt":"private prompt"}
    """.utf8)
    let payload = try HookInput.decodePayload(from: data)

    #expect(HookInput.sessionTitle(from: payload, source: "claude") == "project")
    #expect(HookInput.sessionTitle(from: nil, source: "claude") == "Claude Code")
    #expect(HookInput.sessionTitle(from: nil, source: "opencode") == "OpenCode")
}

@Test func claudeActivityUsesOnlyDescriptionsFromDocumentedTools() throws {
    for toolName in ["Bash", "agent", "TASK"] {
        let data = try JSONSerialization.data(withJSONObject: [
            "tool_name": toolName,
            "tool_input": [
                "description": "  Check   the build  ",
                "command": "private command",
                "prompt": "private prompt",
            ],
            "activity_description": "must not be used for Claude",
        ])
        let payload = try HookInput.decodePayload(from: data)
        #expect(HookInput.activityDescription(from: payload, source: "claude") == "Check the build")
    }

    for toolName in ["Read", "Edit", "WebFetch"] {
        let data = try JSONSerialization.data(withJSONObject: [
            "tool_name": toolName,
            "tool_input": ["description": "Do not collect"],
        ])
        let payload = try HookInput.decodePayload(from: data)
        #expect(HookInput.activityDescription(from: payload, source: "claude") == nil)
    }

    let rawFields = try HookInput.decodePayload(from: Data("""
    {"tool_name":"Bash","tool_input":{"command":"secret"},"prompt":"secret","task_description":"secret"}
    """.utf8))
    #expect(HookInput.activityDescription(from: rawFields, source: "claude") == nil)
}

@Test func subagentIdentifiersAreAllowlistedAndValidated() throws {
    let data = Data("""
    {"session_id":"parent","agent_id":"child","parent_session_id":"root","agent_type":"Explore","task_id":"ignored"}
    """.utf8)
    let payload = try HookInput.decodePayload(from: data)

    #expect(payload?.sessionID == "parent")
    #expect(payload?.agentID == "child")
    #expect(payload?.parentSessionID == "root")
    #expect(HookInput.subagentLabel(from: payload) == "Explore")

    let invalid = Data("{\"agent_id\":\"bad\\nidentifier\"}".utf8)
    #expect(throws: HookInputError.invalidJSON) {
        try HookInput.decodePayload(from: invalid)
    }
}

@Test func statusLineModeRequiresMetadataKind() throws {
    let valid = try HookInput.parse(arguments: [
        "--source", "claude", "--kind", "metadata", "--mode", "statusline",
    ])
    #expect(valid.statusLine)
    #expect(!valid.permissionRequest)

    #expect(throws: HookInputError.invalidArguments) {
        try HookInput.parse(arguments: [
            "--source", "claude", "--kind", "working", "--mode", "statusline",
        ])
    }
}

@Test func statusLinePayloadExtractsCost() throws {
    let data = Data("""
    {
      "session_id": "abc123",
      "cost": { "total_cost_usd": 1.23 },
      "context_window": { "total_input_tokens": 5000, "total_output_tokens": 1200 },
      "model": { "id": "claude-sonnet-4-20250514", "display_name": "Sonnet" }
    }
    """.utf8)
    let payload = try HookInput.decodeStatusLinePayload(from: data)

    #expect(payload?.sessionID == "abc123")
    #expect(payload?.costUSD == 1.23)
}

@Test func statusLinePayloadHandlesMissingFields() throws {
    let minimal = try HookInput.decodeStatusLinePayload(from: Data("{}".utf8))
    #expect(minimal?.sessionID == nil)
    #expect(minimal?.costUSD == nil)

    let empty = try HookInput.decodeStatusLinePayload(from: Data())
    #expect(empty == nil)
}

@Test func statusLinePayloadRejectsInvalidCost() throws {
    let negative = Data("""
    {"session_id":"s1","cost":{"total_cost_usd":-1.0}}
    """.utf8)
    let payload = try HookInput.decodeStatusLinePayload(from: negative)
    #expect(payload?.costUSD == nil)
}

@Test func hookPayloadCarriesCostFields() throws {
    let data = Data("""
    {"session_id":"s1","cost_usd":0.42,"cost_generation":"launch-1","input_tokens":1000,"output_tokens":500}
    """.utf8)
    let payload = try HookInput.decodePayload(from: data)

    #expect(payload?.costUSD == 0.42)
    #expect(payload?.costGeneration == "launch-1")
}

@Test func hookPayloadRejectsNegativeCostFields() throws {
    let data = Data("""
    {"session_id":"s1","cost_usd":-1.0,"input_tokens":-5,"output_tokens":-10}
    """.utf8)
    let payload = try HookInput.decodePayload(from: data)

    #expect(payload?.costUSD == nil)
}
