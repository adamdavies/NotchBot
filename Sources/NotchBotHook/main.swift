import Darwin
import Foundation
import NotchBotCore

struct HookPayload: Decodable {
    let sessionID: String?
    let cwd: String?
    let lastAssistantMessage: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case lastAssistantMessage = "last_assistant_message"
    }
}

func option(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

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

let arguments = Array(CommandLine.arguments.dropFirst())
guard
    let sourceValue = option("--source", in: arguments),
    let source = AgentSource(rawValue: sourceValue),
    let kindValue = option("--kind", in: arguments),
    let kind = AgentEventKind(rawValue: kindValue)
else {
    FileHandle.standardError.write(
        Data("usage: notchbot-hook --source <claude|opencode> --kind <working|attention|cleared> [--session id] [--reason text]\n".utf8)
    )
    exit(64)
}

let input = FileHandle.standardInput.readDataToEndOfFile()
let hookPayload = input.isEmpty ? nil : try? JSONDecoder().decode(HookPayload.self, from: input)
let environment = ProcessInfo.processInfo.environment
let sessionID = option("--session", in: arguments)
    ?? hookPayload?.sessionID
    ?? environment["CLAUDE_SESSION_ID"]
    ?? "\(source.rawValue)-\(getppid())"
let cwd = option("--cwd", in: arguments) ?? hookPayload?.cwd ?? environment["PWD"]

let event = AgentEvent(
    source: source,
    kind: kind,
    sessionID: sessionID,
    workingDirectory: cwd,
    terminalBundleIdentifier: terminalBundleIdentifier(environment: environment),
    terminalProcessID: nil,
    reason: option("--reason", in: arguments),
    expiresAfter: option("--expires-after", in: arguments).flatMap(TimeInterval.init),
    summary: AgentSummaryText.excerpt(
        from: option("--summary", in: arguments) ?? hookPayload?.lastAssistantMessage ?? ""
    )
)

do {
    let data = try JSONEncoder().encode(event)
    try UnixDatagramClient.send(data)
} catch {
    // Agent hooks must never fail because the optional UI is not running.
    exit(0)
}
