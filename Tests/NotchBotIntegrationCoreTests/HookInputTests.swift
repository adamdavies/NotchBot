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

@Test func oversizedWhitelistedValuesAreDiscarded() throws {
    let longSession = String(repeating: "s", count: 129)
    let data = try JSONSerialization.data(withJSONObject: ["session_id": longSession])
    let payload = try HookInput.decodePayload(from: data, assistantExcerptsEnabled: false)
    #expect(payload?.sessionID == nil)

    #expect(throws: HookInputError.invalidArguments) {
        try HookInput.parse(arguments: [
            "--source", "claude", "--kind", "attention", "--expires-after", "301",
        ])
    }
}
