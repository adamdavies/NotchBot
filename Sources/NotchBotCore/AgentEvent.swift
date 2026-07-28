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
    case metadata
}

public struct AgentEvent: Codable, Equatable, Sendable {
    public static let protocolVersion = 2

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
    public let taskLabel: String?

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
        summary: String? = nil,
        taskLabel: String? = nil
    ) {
        self.version = Self.protocolVersion
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
        self.taskLabel = AgentTaskLabel.normalized(taskLabel)
    }
}

public enum AgentEventValidationError: Error, Equatable, Sendable {
    case payloadTooLarge
    case unsupportedVersion
    case previewSourceNotAllowed
    case invalidSessionID
    case stringTooLong(String)
    case invalidTimestamp
    case invalidExpiry
    case invalidProcessID
}

public enum AgentEventValidator {
    public static let maximumDatagramBytes = 8 * 1024
    public static let maximumTimestampSkew: TimeInterval = 5 * 60

    public static func validate(
        _ event: AgentEvent,
        encodedSize: Int? = nil,
        now: Date = Date(),
        allowPreview: Bool = false
    ) throws {
        if let encodedSize, encodedSize > maximumDatagramBytes {
            throw AgentEventValidationError.payloadTooLarge
        }
        guard event.version == AgentEvent.protocolVersion else {
            throw AgentEventValidationError.unsupportedVersion
        }
        guard allowPreview || event.source != .preview else {
            throw AgentEventValidationError.previewSourceNotAllowed
        }
        guard !event.sessionID.isEmpty, event.sessionID.utf8.count <= 128 else {
            throw AgentEventValidationError.invalidSessionID
        }
        try check(event.workingDirectory, name: "workingDirectory", maximumBytes: 1_024)
        try check(event.terminalBundleIdentifier, name: "terminalBundleIdentifier", maximumBytes: 255)
        try check(event.reason, name: "reason", maximumBytes: 256)
        try check(event.summary, name: "summary", maximumBytes: 1_024)
        try check(event.taskLabel, name: "taskLabel", maximumBytes: AgentTaskLabel.maximumBytes)
        if let taskLabel = event.taskLabel,
           taskLabel.count > AgentTaskLabel.maximumCharacters || AgentTaskLabel.normalized(taskLabel) != taskLabel {
                throw AgentEventValidationError.stringTooLong("taskLabel")
        }

        let timestamp = event.timestamp.timeIntervalSince1970
        guard timestamp.isFinite, abs(event.timestamp.timeIntervalSince(now)) <= maximumTimestampSkew else {
            throw AgentEventValidationError.invalidTimestamp
        }
        if let expiry = event.expiresAfter {
            guard expiry.isFinite, (0...300).contains(expiry) else {
                throw AgentEventValidationError.invalidExpiry
            }
        }
        if let processID = event.terminalProcessID, processID <= 0 {
            throw AgentEventValidationError.invalidProcessID
        }
    }

    private static func check(_ value: String?, name: String, maximumBytes: Int) throws {
        guard let value else { return }
        guard value.utf8.count <= maximumBytes else {
            throw AgentEventValidationError.stringTooLong(name)
        }
        guard !value.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw AgentEventValidationError.stringTooLong(name)
        }
    }
}

public enum AgentTaskLabel {
    public static let maximumCharacters = 100
    public static let maximumBytes = 512

    public static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let sanitized = String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
        })
        let normalized = sanitized
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }

        var result = ""
        result.reserveCapacity(min(normalized.utf8.count, maximumBytes))
        for character in normalized {
            guard result.count < maximumCharacters else { break }
            let candidate = result + String(character)
            guard candidate.utf8.count <= maximumBytes else { break }
            result = candidate
        }
        return result.isEmpty ? nil : result
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

    @discardableResult
    public mutating func removeLatest(olderThan cutoff: Date) -> LatestAgentSummary? {
        if let latest, latest.updatedAt < cutoff {
            self.latest = nil
        }
        return latest
    }
}
