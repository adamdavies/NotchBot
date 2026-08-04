import Foundation
import NotchBotCore
import NotchBotIntegrationCore
import Testing
@testable import NotchBotHookCore

private final class RecordingPermissionServer: PermissionResponding, @unchecked Sendable {
    let responseToken = "token-abc"
    var startError: Error?
    var decision: AgentPermissionDecision?
    private(set) var started = false
    private(set) var stopped = false

    func start() throws {
        if let startError { throw startError }
        started = true
    }

    func receive(timeout: TimeInterval) throws -> AgentPermissionDecision? { decision }

    func stop() { stopped = true }
}

private final class Recorder: @unchecked Sendable {
    var sent: [Data] = []
    var output = Data()
    var errorOutput = Data()
    var sendError: Error?
}

private struct SendFailure: Error {}

private func services(
    input: Data = Data(),
    recorder: Recorder,
    server: RecordingPermissionServer? = nil
) -> HookServices {
    HookServices(
        readInput: { _ in input },
        send: { data in
            if let error = recorder.sendError { throw error }
            recorder.sent.append(data)
        },
        makePermissionServer: { server ?? RecordingPermissionServer() },
        writeOutput: { recorder.output.append($0) },
        writeError: { recorder.errorOutput.append($0) }
    )
}

private func decodeEvent(_ data: Data) throws -> AgentEvent {
    try JSONDecoder().decode(AgentEvent.self, from: data)
}

@Test func invalidArgumentsReportUsageAndExitSixtyFour() {
    let recorder = Recorder()
    let status = HookRunner.run(
        arguments: ["--source", "nope"],
        environment: [:],
        services: services(recorder: recorder)
    )
    #expect(status == 64)
    #expect(recorder.sent.isEmpty)
    #expect(String(decoding: recorder.errorOutput, as: UTF8.self).contains("usage: notchbot-hook"))
}

@Test func workingEventCarriesSessionTerminalAndDirectoryFromEnvironment() throws {
    let recorder = Recorder()
    let status = HookRunner.run(
        arguments: ["--source", "claude", "--kind", "working"],
        environment: [
            "CLAUDE_SESSION_ID": "session-1",
            "PWD": "/tmp/project",
            "TERM_PROGRAM": "iTerm.app",
        ],
        services: services(recorder: recorder)
    )
    #expect(status == 0)
    let event = try decodeEvent(#require(recorder.sent.first))
    #expect(event.source == .claude)
    #expect(event.kind == .working)
    #expect(event.sessionID == "session-1")
    #expect(event.workingDirectory == "/tmp/project")
    #expect(event.terminalBundleIdentifier == "com.googlecode.iterm2")
    #expect(event.permission == nil)
    #expect(event.sessionTitle == nil)
    #expect(event.activityDescription == nil)
}

@Test func claudeEventSeparatesStableSessionAndSubagentTitlesFromActivity() throws {
    let parentRecorder = Recorder()
    let parentPayload = Data("""
    {"session_id":"parent","session_title":"Feature work","agent_type":"ignored","tool_name":"BASH","tool_input":{"description":"Run tests","command":"private"}}
    """.utf8)
    _ = HookRunner.run(
        arguments: ["--source", "claude", "--kind", "working"],
        environment: [:],
        services: services(input: parentPayload, recorder: parentRecorder)
    )
    let parent = try decodeEvent(#require(parentRecorder.sent.first))
    #expect(parent.sessionTitle == "Feature work")
    #expect(parent.activityDescription == "Run tests")

    let childRecorder = Recorder()
    let childPayload = Data("""
    {"session_id":"parent","agent_id":"child","session_title":"Feature work","agent_type":"Explore","tool_name":"Task","tool_input":{"description":"Inspect API"}}
    """.utf8)
    _ = HookRunner.run(
        arguments: ["--source", "claude", "--kind", "working"],
        environment: [:],
        services: services(input: childPayload, recorder: childRecorder)
    )
    let child = try decodeEvent(#require(childRecorder.sent.first))
    #expect(child.sessionID == "child")
    #expect(child.parentSessionID == "parent")
    #expect(child.sessionTitle == "Explore")
    #expect(child.activityDescription == "Inspect API")
}

@Test func openCodeEventCarriesSessionTitleAndActivitySeparately() throws {
    let recorder = Recorder()
    let payload = Data("""
    {"session_id":"session","session_title":"Project","activity_description":"Run tests"}
    """.utf8)
    _ = HookRunner.run(
        arguments: ["--source", "opencode", "--kind", "working"],
        environment: [:],
        services: services(input: payload, recorder: recorder)
    )
    let event = try decodeEvent(#require(recorder.sent.first))
    #expect(event.sessionTitle == "Project")
    #expect(event.activityDescription == "Run tests")
}

@Test func transportFailureStillExitsZeroSoProviderHooksNeverFail() {
    let recorder = Recorder()
    recorder.sendError = SendFailure()
    let server = RecordingPermissionServer()
    let status = HookRunner.run(
        arguments: ["--source", "opencode", "--kind", "working"],
        environment: ["CLAUDE_SESSION_ID": "session-2"],
        services: services(recorder: recorder, server: server)
    )
    #expect(status == 0)
    #expect(recorder.sent.isEmpty)
}

@Test func openCodePermissionRequestWritesDecisionAndStopsServer() throws {
    let recorder = Recorder()
    let server = RecordingPermissionServer()
    server.decision = .allowOnce
    let payload = try JSONSerialization.data(withJSONObject: [
        "session_id": "session-3",
        "permission_summary": "Run tests",
        "permission_can_always": true,
    ])
    let status = HookRunner.run(
        arguments: ["--source", "opencode", "--kind", "attention", "--mode", "permission"],
        environment: [:],
        services: services(input: payload, recorder: recorder, server: server)
    )
    #expect(status == 0)
    #expect(server.started)
    #expect(server.stopped)
    let event = try decodeEvent(#require(recorder.sent.first))
    #expect(event.permission?.responseToken == "token-abc")
    #expect(event.permission?.summary == "Run tests")
    #expect(event.permission?.canAlwaysAllow == true)
    let decision = try JSONSerialization.jsonObject(with: recorder.output) as? [String: String]
    #expect(decision?["decision"] == "allowOnce")
}

@Test func permissionRequestWithoutSummaryExitsWithoutSendingAnEvent() {
    let recorder = Recorder()
    let server = RecordingPermissionServer()
    let status = HookRunner.run(
        arguments: ["--source", "opencode", "--kind", "attention", "--mode", "permission"],
        environment: [:],
        services: services(recorder: recorder, server: server)
    )
    #expect(status == 0)
    #expect(recorder.sent.isEmpty)
    #expect(server.stopped)
    #expect(recorder.output.isEmpty)
}

@Test func statusLineWithoutCostSendsNothingAndNonJSONFailsClosed() {
    let withoutCost = Recorder()
    let emptyStatus = HookRunner.run(
        arguments: ["--source", "claude", "--kind", "metadata", "--mode", "statusline"],
        environment: [:],
        services: services(input: Data("{}".utf8), recorder: withoutCost)
    )
    #expect(emptyStatus == 0)
    #expect(withoutCost.sent.isEmpty)

    let malformed = Recorder()
    let malformedStatus = HookRunner.run(
        arguments: ["--source", "claude", "--kind", "metadata", "--mode", "statusline"],
        environment: [:],
        services: services(input: Data("not json".utf8), recorder: malformed)
    )
    #expect(malformedStatus == 65)
    #expect(malformed.sent.isEmpty)
}

@Test func statusLineCostBecomesAClaudeMetadataEvent() throws {
    let recorder = Recorder()
    let payload = try JSONSerialization.data(withJSONObject: [
        "session_id": "session-4",
        "cost": ["total_cost_usd": 1.25],
    ])
    let status = HookRunner.run(
        arguments: ["--source", "claude", "--kind", "metadata", "--mode", "statusline"],
        environment: [:],
        services: services(input: payload, recorder: recorder)
    )
    #expect(status == 0)
    let event = try decodeEvent(#require(recorder.sent.first))
    #expect(event.kind == .metadata)
    #expect(event.sessionID == "session-4")
    #expect(event.costUSD == 1.25)
}

// Guards the drift the force-unwraps used to hide: parse() allowlists raw strings independently
// of the enums, so anything it accepts must still map to a case.
@Test func everyAllowlistedSourceAndKindMapsToAnEnumCase() throws {
    for source in [AgentSource.claude, .opencode] {
        let options = try HookInput.parse(arguments: ["--source", source.rawValue, "--kind", "working"])
        #expect(AgentSource(rawValue: options.source) == source)
    }
    for kind in ["working", "attention", "cleared", "metadata", "request_resolved"] {
        let options = try HookInput.parse(arguments: ["--source", "opencode", "--kind", kind])
        #expect(AgentEventKind(rawValue: options.kind) != nil)
    }
    // `preview` is a UI-only source and must stay off the provider-facing CLI.
    #expect(throws: HookInputError.invalidArguments) {
        try HookInput.parse(arguments: ["--source", AgentSource.preview.rawValue, "--kind", "working"])
    }
}

@Test func terminalBundleIdentifierMapsKnownTerminalsOnly() {
    #expect(HookRunner.terminalBundleIdentifier(environment: ["TERM_PROGRAM": "Apple_Terminal"])
        == "com.apple.Terminal")
    #expect(HookRunner.terminalBundleIdentifier(environment: ["TERM_PROGRAM": "ghostty"])
        == "com.mitchellh.ghostty")
    #expect(HookRunner.terminalBundleIdentifier(environment: ["TERM_PROGRAM": "unknown"]) == nil)
    #expect(HookRunner.terminalBundleIdentifier(environment: [:]) == nil)
}

@Test func boundedRejectsEmptyAndOversizedValues() {
    #expect(HookRunner.bounded("value", bytes: 16) == "value")
    #expect(HookRunner.bounded("", bytes: 16) == nil)
    #expect(HookRunner.bounded(nil, bytes: 16) == nil)
    #expect(HookRunner.bounded(String(repeating: "a", count: 17), bytes: 16) == nil)
}
