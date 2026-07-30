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
        "usage: notchbot-hook --source <claude|opencode> --kind <working|attention|cleared|metadata|request_resolved> [--reason text] [--expires-after seconds] [--mode permission]\n".utf8
    ))
    exit(64)
}

let input = FileHandle.standardInput.readData(ofLength: HookInput.maximumByteCount + 1)
let payload: HookPayload?
do {
    payload = try HookInput.decodePayload(from: input)
} catch {
    exit(65)
}

let environment = ProcessInfo.processInfo.environment
let source = AgentSource(rawValue: options.source)!
let kind = AgentEventKind(rawValue: options.kind)!
let isClaudeSubagent = source == .claude && payload?.agentID != nil
let sessionID = (isClaudeSubagent ? payload?.agentID : payload?.sessionID)
    ?? bounded(environment["CLAUDE_SESSION_ID"], bytes: 128)
    ?? "\(source.rawValue)-\(getppid())"
let parentSessionID: String? = if isClaudeSubagent {
    payload?.sessionID
} else if source == .opencode {
    payload?.parentSessionID
} else {
    nil
}
let cwd = payload?.cwd ?? bounded(environment["PWD"], bytes: 1_024)
let taskLabel: String? = if isClaudeSubagent {
    HookInput.subagentLabel(from: payload)
} else if source == .claude && kind != .metadata {
    nil
} else {
    HookInput.taskLabel(from: payload, source: options.source)
}
let request: AgentRequestUpdate? = if source == .opencode,
    let requestID = payload?.requestID,
    let requestKind = payload?.requestKind.flatMap(AgentRequestKind.init(rawValue:)),
    let requestState = payload?.requestState.flatMap(AgentRequestState.init(rawValue:)) {
    AgentRequestUpdate(id: requestID, kind: requestKind, state: requestState)
} else {
    nil
}

var permissionServer: PermissionResponseServer?
var permissionInput: ClaudePermissionInput?
var permission: AgentPermissionRequest?
if options.permissionRequest {
    do {
        let server = PermissionResponseServer()
        try server.start()
        permissionServer = server
        if source == .claude {
            let decoded = try ClaudePermissionInput.decode(from: input)
            permissionInput = decoded
            permission = AgentPermissionRequest(
                responseToken: server.responseToken,
                summary: decoded.summary,
                context: decoded.context,
                canAlwaysAllow: decoded.suggestion != nil
            )
        } else if let nativeSummary = payload?.permissionSummary {
            permission = AgentPermissionRequest(
                responseToken: server.responseToken,
                summary: nativeSummary,
                context: payload?.permissionContext,
                canAlwaysAllow: payload?.permissionCanAlways ?? false
            )
        }
        guard permission != nil else {
            server.stop()
            exit(0)
        }
    } catch {
        permissionServer?.stop()
        exit(0)
    }
}

let event = AgentEvent(
    source: source,
    kind: kind,
    sessionID: sessionID,
    parentSessionID: parentSessionID,
    workingDirectory: cwd,
    terminalBundleIdentifier: terminalBundleIdentifier(environment: environment),
    terminalProcessID: nil,
    reason: options.reason,
    expiresAfter: options.expiresAfter,
    taskLabel: taskLabel,
    permission: permission,
    request: request
)

do {
    try UnixDatagramClient.send(JSONEncoder().encode(event))
} catch {
    // Agent hooks must never fail because the optional UI is not running.
    permissionServer?.stop()
    exit(0)
}

if let permissionServer {
    if let decision = try? permissionServer.receive(timeout: 240) {
        if source == .claude, let output = ClaudePermissionOutput.encode(
            decision: decision.rawValue,
            suggestion: permissionInput?.suggestion
        ) {
            FileHandle.standardOutput.write(output)
        } else if source == .opencode,
                  let output = try? JSONSerialization.data(withJSONObject: ["decision": decision.rawValue]) {
            FileHandle.standardOutput.write(output)
        }
    }
    permissionServer.stop()
}
