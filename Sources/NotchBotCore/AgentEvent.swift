import Foundation

public enum AgentSource: String, Codable, Sendable, CaseIterable {
    case claude
    case opencode
    case preview
}

public enum AgentEventKind: String, Codable, Sendable {
    case working
    case attention
    case cleared
}

public struct AgentEvent: Codable, Equatable, Sendable {
    public let version: Int
    public let source: AgentSource
    public let kind: AgentEventKind
    public let sessionID: String
    public let timestamp: Date
    public let workingDirectory: String?
    public let terminalBundleIdentifier: String?
    public let terminalProcessID: Int32?
    public let reason: String?
    public let expiresAfter: TimeInterval?
    public let summary: String?

    public init(
        source: AgentSource,
        kind: AgentEventKind,
        sessionID: String,
        timestamp: Date = Date(),
        workingDirectory: String? = nil,
        terminalBundleIdentifier: String? = nil,
        terminalProcessID: Int32? = nil,
        reason: String? = nil,
        expiresAfter: TimeInterval? = nil,
        summary: String? = nil
    ) {
        self.version = 1
        self.source = source
        self.kind = kind
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.workingDirectory = workingDirectory
        self.terminalBundleIdentifier = terminalBundleIdentifier
        self.terminalProcessID = terminalProcessID
        self.reason = reason
        self.expiresAfter = expiresAfter
        self.summary = summary
    }
}

public enum AgentSummaryText {
    public static func excerpt(from text: String, limit: Int = 240) -> String? {
        let normalized = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty, limit > 0 else { return nil }
        guard normalized.count > limit else { return normalized }

        let end = normalized.index(normalized.startIndex, offsetBy: max(1, limit - 3))
        return String(normalized[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}

public struct LatestAgentSummary: Equatable, Sendable {
    public let source: AgentSource
    public let text: String
    public let workingDirectory: String?
    public let updatedAt: Date

    public var projectName: String? {
        workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
}

public struct AgentSummaryStore: Sendable {
    public private(set) var latest: LatestAgentSummary?

    public init() {}

    @discardableResult
    public mutating func apply(_ event: AgentEvent) -> LatestAgentSummary? {
        guard
            let text = event.summary.flatMap({ AgentSummaryText.excerpt(from: $0) }),
            latest == nil || event.timestamp >= latest!.updatedAt
        else {
            return latest
        }

        latest = LatestAgentSummary(
            source: event.source,
            text: text,
            workingDirectory: event.workingDirectory,
            updatedAt: event.timestamp
        )
        return latest
    }
}
