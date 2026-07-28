import Darwin
import Foundation
import NotchBotCore
import NotchBotIntegrationCore

func terminalBundleIdentifier(environment: [String: String]) -> String? {
    switch environment["TERM_PROGRAM"]?.lowercased() {
    case "apple_terminal": "com.apple.Terminal"
    case "iterm.app": "com.googlecode.iterm2"
    case "warpterminal", "warp": "dev.warp.Warp-Stable"
    case "ghostty": "com.mitchellh.ghostty"
    case "kitty": "net.kovidgoyal.kitty"
    default: nil
    }
}

func bounded(_ value: String?, bytes maximum: Int) -> String? {
    guard let value, !value.isEmpty, value.utf8.count <= maximum else { return nil }
    return value
}

let options: HookOptions
do {
    options = try HookInput.parse(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data(
        "usage: notchbot-hook --source <claude|opencode> --kind <working|attention|cleared|metadata> [--reason text] [--expires-after seconds]\n".utf8
    ))
    exit(64)
}

let policyURL = NotchBotIntegrationFiles.privacyPolicyURL(
    applicationSupportDirectory: NotchBotPaths.applicationSupportDirectory
)
let policy = IntegrationPrivacyPolicy.load(from: policyURL)
let input = FileHandle.standardInput.readData(ofLength: HookInput.maximumByteCount + 1)
let payload: HookPayload?
do {
    payload = try HookInput.decodePayload(
        from: input,
        assistantExcerptsEnabled: policy.assistantExcerptsEnabled
    )
} catch {
    exit(65)
}

let environment = ProcessInfo.processInfo.environment
let source = AgentSource(rawValue: options.source)!
let kind = AgentEventKind(rawValue: options.kind)!
let sessionID = payload?.sessionID
    ?? bounded(environment["CLAUDE_SESSION_ID"], bytes: 128)
    ?? "\(source.rawValue)-\(getppid())"
let cwd = payload?.cwd ?? bounded(environment["PWD"], bytes: 1_024)
let summary = policy.assistantExcerptsEnabled
    ? AgentSummaryText.excerpt(from: payload?.lastAssistantMessage ?? "")
    : nil
let taskLabel = source == .claude && kind != .metadata
    ? nil
    : HookInput.taskLabel(from: payload, source: options.source)

let event = AgentEvent(
    source: source,
    kind: kind,
    sessionID: sessionID,
    workingDirectory: cwd,
    terminalBundleIdentifier: terminalBundleIdentifier(environment: environment),
    terminalProcessID: nil,
    reason: options.reason,
    expiresAfter: options.expiresAfter,
    summary: summary,
    taskLabel: taskLabel
)

do {
    try UnixDatagramClient.send(JSONEncoder().encode(event))
} catch {
    // Agent hooks must never fail because the optional UI is not running.
    exit(0)
}
