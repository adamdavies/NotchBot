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

@Test func statusLineContextWindowBecomesASetUpdate() throws {
    let recorder = Recorder()
    let payload = try JSONSerialization.data(withJSONObject: [
        "session_id": "session-ctx",
        "cost": ["total_cost_usd": 0.5],
        "context_window": ["used_percentage": 82],
    ])
    let status = HookRunner.run(
        arguments: ["--source", "claude", "--kind", "metadata", "--mode", "statusline"],
        environment: [:],
        services: services(input: payload, recorder: recorder)
    )
    #expect(status == 0)
    let event = try decodeEvent(#require(recorder.sent.first))
    #expect(event.contextWindow?.usedPercentage == 82)
    #expect(event.costUSD == 0.5)
    try AgentEventValidator.validate(event)
}

/// A context reading with no cost still has to reach the app, and a `context_window` object with
/// no usable percentage is a retraction rather than a no-op.
@Test func statusLineSendsContextWithoutCostAndClearsOnNullPercentage() throws {
    let withoutCost = Recorder()
    let contextOnly = try JSONSerialization.data(withJSONObject: [
        "session_id": "session-ctx",
        "context_window": ["used_percentage": 44],
    ])
    #expect(HookRunner.run(
        arguments: ["--source", "claude", "--kind", "metadata", "--mode", "statusline"],
        environment: [:],
        services: services(input: contextOnly, recorder: withoutCost)
    ) == 0)
    let contextEvent = try decodeEvent(#require(withoutCost.sent.first))
    #expect(contextEvent.costUSD == nil)
    #expect(contextEvent.contextWindow?.usedPercentage == 44)

    let cleared = Recorder()
    let clearing = try JSONSerialization.data(withJSONObject: [
        "session_id": "session-ctx",
        "context_window": [:] as [String: Any],
    ])
    #expect(HookRunner.run(
        arguments: ["--source", "claude", "--kind", "metadata", "--mode", "statusline"],
        environment: [:],
        services: services(input: clearing, recorder: cleared)
    ) == 0)
    let clearedEvent = try decodeEvent(#require(cleared.sent.first))
    #expect(clearedEvent.contextWindow != nil)
    #expect(clearedEvent.contextWindow?.usedPercentage == nil)
    try AgentEventValidator.validate(clearedEvent)
}

/// Older Claude builds send no `context_window` at all. That must stay a no-update, not a clear,
/// or a percentage a newer session reported would be wiped on the next status-line tick.
@Test func statusLineWithoutContextWindowLeavesUsageUntouched() throws {
    let recorder = Recorder()
    let payload = try JSONSerialization.data(withJSONObject: [
        "session_id": "session-legacy",
        "cost": ["total_cost_usd": 2],
    ])
    #expect(HookRunner.run(
        arguments: ["--source", "claude", "--kind", "metadata", "--mode", "statusline"],
        environment: [:],
        services: services(input: payload, recorder: recorder)
    ) == 0)
    let event = try decodeEvent(#require(recorder.sent.first))
    #expect(event.contextWindow == nil)
}

@Test func openCodeContextWindowRidesOnlyOnMetadataEvents() throws {
    let metadata = Recorder()
    let payload = try JSONSerialization.data(withJSONObject: [
        "session_id": "oc-1",
        "context_window": ["used_percentage": 63],
    ])
    #expect(HookRunner.run(
        arguments: ["--source", "opencode", "--kind", "metadata"],
        environment: [:],
        services: services(input: payload, recorder: metadata)
    ) == 0)
    let metadataEvent = try decodeEvent(#require(metadata.sent.first))
    #expect(metadataEvent.contextWindow?.usedPercentage == 63)
    try AgentEventValidator.validate(metadataEvent)

    // A lifecycle event carrying usage would fail validation and take the transition with it,
    // so the helper drops the field instead of forwarding it.
    let working = Recorder()
    #expect(HookRunner.run(
        arguments: ["--source", "opencode", "--kind", "working"],
        environment: [:],
        services: services(input: payload, recorder: working)
    ) == 0)
    let workingEvent = try decodeEvent(#require(working.sent.first))
    #expect(workingEvent.contextWindow == nil)
    try AgentEventValidator.validate(workingEvent)
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
