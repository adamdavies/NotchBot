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

    #expect(throws: HookInputError.invalidArguments) {
        try HookInput.parse(arguments: ["--source", "opencode", "--kind", "working", "--session", "secret"])
    }
    #expect(throws: HookInputError.invalidArguments) {
        try HookInput.parse(arguments: ["--source", "opencode", "--source", "claude", "--kind", "working"])
    }
}

@Test func inputIsBoundedAndOnlyWhitelistedFieldsAreDecoded() throws {
    let data = Data("""
    {"session_id":"session","cwd":"/tmp/project","last_assistant_message":"private result","prompt":"ignored"}
    """.utf8)
    let disabled = try HookInput.decodePayload(from: data, assistantExcerptsEnabled: false)
    let enabled = try HookInput.decodePayload(from: data, assistantExcerptsEnabled: true)

    #expect(disabled?.sessionID == "session")
    #expect(disabled?.cwd == "/tmp/project")
    #expect(disabled?.lastAssistantMessage == nil)
    #expect(enabled?.lastAssistantMessage == "private result")

    let overflow = Data(repeating: 0x20, count: HookInput.maximumByteCount + 1)
    #expect(throws: HookInputError.inputTooLarge) {
        try HookInput.decodePayload(from: overflow, assistantExcerptsEnabled: true)
    }
}

@Test func oversizedSessionIdentifiersAreRejected() throws {
    let longSession = String(repeating: "s", count: 129)
    let data = try JSONSerialization.data(withJSONObject: ["session_id": longSession])
    #expect(throws: HookInputError.invalidJSON) {
        try HookInput.decodePayload(from: data, assistantExcerptsEnabled: false)
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
      "task_label":"OpenCode title",
      "prompt":"private prompt",
      "task_description":"private description",
      "transcript":"private transcript"
    }
    """.utf8)
    let payload = try HookInput.decodePayload(from: data, assistantExcerptsEnabled: false)

    #expect(payload?.sessionTitle == "Session title")
    #expect(payload?.agentType == "Explore")
    #expect(HookInput.taskLabel(from: payload, source: "claude") == "Session title")
    #expect(HookInput.taskLabel(from: payload, source: "opencode") == "OpenCode title")
}

@Test func taskLabelFallbacksAreBoundedAndDoNotUseExcerptText() throws {
    let data = Data("""
    {"cwd":"/tmp/project","last_assistant_message":"private result","prompt":"private prompt"}
    """.utf8)
    let payload = try HookInput.decodePayload(from: data, assistantExcerptsEnabled: true)

    #expect(HookInput.taskLabel(from: payload, source: "claude") == "project")
    #expect(HookInput.taskLabel(from: nil, source: "claude") == "Claude Code")
    #expect(HookInput.taskLabel(from: nil, source: "opencode") == "OpenCode")
    #expect(HookInput.taskLabel(from: payload, source: "claude") != payload?.lastAssistantMessage)
}

@Test func subagentIdentifiersAreAllowlistedAndValidated() throws {
    let data = Data("""
    {"session_id":"parent","agent_id":"child","parent_session_id":"root","agent_type":"Explore","task_id":"ignored"}
    """.utf8)
    let payload = try HookInput.decodePayload(from: data, assistantExcerptsEnabled: false)

    #expect(payload?.sessionID == "parent")
    #expect(payload?.agentID == "child")
    #expect(payload?.parentSessionID == "root")
    #expect(HookInput.subagentLabel(from: payload) == "Explore")

    let invalid = Data("{\"agent_id\":\"bad\\nidentifier\"}".utf8)
    #expect(throws: HookInputError.invalidJSON) {
        try HookInput.decodePayload(from: invalid, assistantExcerptsEnabled: false)
    }
}
