import Foundation
import NotchBotCore
import NotchBotIntegrationCore

public enum HookRunner {
    static let usage = """
        usage: notchbot-hook --source <claude|opencode> \
        --kind <working|attention|cleared|metadata|request_resolved> \
        [--reason text] [--expires-after seconds] [--mode permission]

        """

    public static func run(
        arguments: [String],
        environment: [String: String],
        services: HookServices = .live
    ) -> Int32 {
        let options: HookOptions
        do {
            options = try HookInput.parse(arguments: arguments)
        } catch {
            services.writeError(Data(usage.utf8))
            return 64
        }

        let input = services.readInput(HookInput.maximumByteCount + 1)

        if options.statusLine {
            return runStatusLine(input: input, environment: environment, services: services)
        }

        // parse() allowlists the raw values, so this only trips if an enum case is renamed or
        // added without updating the allowlist. Report it instead of trapping.
        guard let source = AgentSource(rawValue: options.source) else {
            services.writeError(Data("notchbot-hook: unsupported --source \(options.source)\n".utf8))
            return 1
        }
        guard let kind = AgentEventKind(rawValue: options.kind) else {
            services.writeError(Data("notchbot-hook: unsupported --kind \(options.kind)\n".utf8))
            return 1
        }

        let payload = try? HookInput.decodePayload(from: input)

        var permissionServer: PermissionResponding?
        var permissionInput: ClaudePermissionInput?
        var permission: AgentPermissionRequest?
        if options.permissionRequest {
            do {
                let server = services.makePermissionServer()
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
                    return 0
                }
            } catch {
                permissionServer?.stop()
                return 0
            }
        }

        let event = makeEvent(
            source: source,
            kind: kind,
            options: options,
            payload: payload,
            environment: environment,
            permission: permission
        )

        do {
            try services.send(JSONEncoder().encode(event))
        } catch {
            // Agent hooks must never fail because the optional UI is not running.
            permissionServer?.stop()
            return 0
        }

        if let permissionServer {
            if let decision = try? permissionServer.receive(timeout: 240) {
                if source == .claude, let output = ClaudePermissionOutput.encode(
                    decision: decision.rawValue,
                    suggestion: permissionInput?.suggestion
                ) {
                    services.writeOutput(output)
                } else if source == .opencode,
                          let output = try? JSONSerialization.data(
                              withJSONObject: ["decision": decision.rawValue]
                          ) {
                    services.writeOutput(output)
                }
            }
            permissionServer.stop()
        }
        return 0
    }

    private static func runStatusLine(
        input: Data,
        environment: [String: String],
        services: HookServices
    ) -> Int32 {
        let statusLinePayload: StatusLinePayload?
        do {
            statusLinePayload = try HookInput.decodeStatusLinePayload(from: input)
        } catch {
            return 65
        }
        guard let statusLinePayload,
              statusLinePayload.costUSD != nil || statusLinePayload.contextWindow != nil else { return 0 }
        let sessionID = statusLinePayload.sessionID
            ?? bounded(environment["CLAUDE_SESSION_ID"], bytes: 128)
            ?? "claude-\(getppid())"
        let event = AgentEvent(
            source: .claude,
            kind: .metadata,
            sessionID: sessionID,
            costUSD: statusLinePayload.costUSD,
            contextWindow: contextWindowUpdate(statusLinePayload.contextWindow)
        )
        try? services.send(JSONEncoder().encode(event))
        return 0
    }

    /// Field derivation for a provider event. Pure, so the allowlisting and fallback rules can be
    /// tested without a socket or a running app.
    static func makeEvent(
        source: AgentSource,
        kind: AgentEventKind,
        options: HookOptions,
        payload: HookPayload?,
        environment: [String: String],
        permission: AgentPermissionRequest?
    ) -> AgentEvent {
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
        let sessionTitle: String? = if isClaudeSubagent {
            HookInput.subagentLabel(from: payload)
        } else if source == .claude {
            payload?.sessionTitle
        } else {
            HookInput.sessionTitle(from: payload, source: options.source)
        }
        let activityDescription = HookInput.activityDescription(from: payload, source: options.source)
        let request: AgentRequestUpdate? = if source == .opencode,
            let requestID = payload?.requestID,
            let requestKind = payload?.requestKind.flatMap(AgentRequestKind.init(rawValue:)),
            let requestState = payload?.requestState.flatMap(AgentRequestState.init(rawValue:)) {
            AgentRequestUpdate(id: requestID, kind: requestKind, state: requestState)
        } else {
            nil
        }
        return AgentEvent(
            source: source,
            kind: kind,
            sessionID: sessionID,
            parentSessionID: parentSessionID,
            workingDirectory: payload?.cwd ?? bounded(environment["PWD"], bytes: 1_024),
            terminalBundleIdentifier: terminalBundleIdentifier(environment: environment),
            terminalProcessID: nil,
            reason: options.reason,
            expiresAfter: options.expiresAfter,
            sessionTitle: sessionTitle,
            activityDescription: activityDescription,
            permission: permission,
            request: request,
            costUSD: payload?.costUSD,
            costGeneration: payload?.costGeneration,
            // Usage rides only on metadata. Attaching it to a lifecycle event would fail
            // validation and take the lifecycle transition down with it.
            contextWindow: kind == .metadata ? contextWindowUpdate(payload?.contextWindow) : nil
        )
    }

    static func contextWindowUpdate(_ usage: ContextWindowUsage?) -> ContextWindowUsageUpdate? {
        switch usage {
        case nil: nil
        case .unavailable: .unavailable
        case .percentage(let percentage): ContextWindowUsageUpdate(usedPercentage: percentage)
        }
    }

    static func terminalBundleIdentifier(environment: [String: String]) -> String? {
        switch environment["TERM_PROGRAM"]?.lowercased() {
        case "apple_terminal": "com.apple.Terminal"
        case "iterm.app": "com.googlecode.iterm2"
        case "warpterminal", "warp": "dev.warp.Warp-Stable"
        case "ghostty": "com.mitchellh.ghostty"
        case "kitty": "net.kovidgoyal.kitty"
        default: nil
        }
    }

    static func bounded(_ value: String?, bytes maximum: Int) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= maximum else { return nil }
        return value
    }
}
