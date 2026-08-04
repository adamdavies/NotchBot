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
    case requestResolved = "request_resolved"
}

public enum AgentRequestKind: String, Codable, Sendable {
    case permission
    case question
}

public enum AgentRequestState: String, Codable, Sendable {
    case opened
    case resolved
}

public struct AgentRequestUpdate: Codable, Equatable, Sendable {
    public let id: String
    public let kind: AgentRequestKind
    public let state: AgentRequestState

    public init(id: String, kind: AgentRequestKind, state: AgentRequestState) {
        self.id = id
        self.kind = kind
        self.state = state
    }
}

public struct AgentPermissionRequest: Codable, Equatable, Sendable {
    public static let maximumSummaryCharacters = 240
    public static let maximumSummaryBytes = 1_024

    public let responseToken: String
    public let summary: String
    public let context: String?
    public let canAlwaysAllow: Bool

    public init(responseToken: String, summary: String, context: String? = nil, canAlwaysAllow: Bool) {
        self.responseToken = responseToken
        self.summary = summary
        self.context = Self.normalizedSummary(context)
        self.canAlwaysAllow = canAlwaysAllow
    }

    public static func normalizedSummary(_ value: String?) -> String? {
        guard let value else { return nil }
        let sanitized = String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
        })
        let normalized = sanitized.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !normalized.isEmpty else { return nil }

        var result = ""
        for character in normalized {
            guard result.count < maximumSummaryCharacters else { break }
            let candidate = result + String(character)
            guard candidate.utf8.count <= maximumSummaryBytes else { break }
            result = candidate
        }
        return result.isEmpty ? nil : result
    }
}

public struct AgentEvent: Codable, Equatable, Sendable {
    public static let protocolVersion = 4

    public let version: Int
    public let source: AgentSource
    public let kind: AgentEventKind
    public let sessionID: String
    public let parentSessionID: String?
    public let timestamp: Date
    public let workingDirectory: String?
    public let terminalBundleIdentifier: String?
    public let terminalProcessID: Int32?
    public let reason: String?
    public let expiresAfter: TimeInterval?
    public let sessionTitle: String?
    public let activityDescription: String?
    public let permission: AgentPermissionRequest?
    public let request: AgentRequestUpdate?
    public let costUSD: Double?
    public let costGeneration: String?

    public init(
        source: AgentSource,
        kind: AgentEventKind,
        sessionID: String,
        parentSessionID: String? = nil,
        timestamp: Date = Date(),
        workingDirectory: String? = nil,
        terminalBundleIdentifier: String? = nil,
        terminalProcessID: Int32? = nil,
        reason: String? = nil,
        expiresAfter: TimeInterval? = nil,
        sessionTitle: String? = nil,
        activityDescription: String? = nil,
        permission: AgentPermissionRequest? = nil,
        request: AgentRequestUpdate? = nil,
        costUSD: Double? = nil,
        costGeneration: String? = nil
    ) {
        self.version = Self.protocolVersion
        self.source = source
        self.kind = kind
        self.sessionID = sessionID
        self.parentSessionID = parentSessionID
        self.timestamp = timestamp
        self.workingDirectory = workingDirectory
        self.terminalBundleIdentifier = terminalBundleIdentifier
        self.terminalProcessID = terminalProcessID
        self.reason = reason
        self.expiresAfter = expiresAfter
        self.sessionTitle = AgentPresentationText.normalized(sessionTitle)
        self.activityDescription = AgentPresentationText.normalized(activityDescription)
        self.permission = permission
        self.request = request
        self.costUSD = costUSD
        self.costGeneration = costGeneration
    }

    public var isCompletionAttention: Bool {
        guard kind == .attention else { return false }
        return switch source {
        case .claude:
            reason == "Claude Code finished working"
        case .opencode:
            reason == "OpenCode finished working"
        case .preview:
            false
        }
    }
}

public enum AgentEventValidationError: Error, Equatable, Sendable {
    case payloadTooLarge
    case unsupportedVersion
    case previewSourceNotAllowed
    case invalidSessionID
    case invalidParentSessionID
    case stringTooLong(String)
    case invalidTimestamp
    case invalidExpiry
    case invalidProcessID
    case invalidPermission
    case invalidRequest
    case invalidCost
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
        guard validIdentifier(event.sessionID) else {
            throw AgentEventValidationError.invalidSessionID
        }
        if let parentSessionID = event.parentSessionID,
           !validIdentifier(parentSessionID) || parentSessionID == event.sessionID {
            throw AgentEventValidationError.invalidParentSessionID
        }
        try check(event.workingDirectory, name: "workingDirectory", maximumBytes: 1_024)
        try check(event.terminalBundleIdentifier, name: "terminalBundleIdentifier", maximumBytes: 255)
        try check(event.reason, name: "reason", maximumBytes: 256)
        try validatePresentationText(event.sessionTitle, name: "sessionTitle")
        try validatePresentationText(event.activityDescription, name: "activityDescription")
        if let permission = event.permission {
            guard event.kind == .attention, event.source != .preview,
                   validResponseToken(permission.responseToken),
                   AgentPermissionRequest.normalizedSummary(permission.summary) == permission.summary,
                   AgentPermissionRequest.normalizedSummary(permission.context) == permission.context else {
                throw AgentEventValidationError.invalidPermission
            }
        }
        if let request = event.request {
            guard event.source == .opencode, validIdentifier(request.id),
                  (request.state == .opened && event.kind == .attention
                      || request.state == .resolved && event.kind == .requestResolved),
                  event.permission == nil || request.kind == .permission else {
                throw AgentEventValidationError.invalidRequest
            }
        } else if event.kind == .requestResolved {
            throw AgentEventValidationError.invalidRequest
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
        if let cost = event.costUSD {
            guard event.kind == .metadata, event.source != .preview,
                  cost.isFinite, (0...1_000_000).contains(cost) else {
                throw AgentEventValidationError.invalidCost
            }
        }
        if let generation = event.costGeneration {
            guard event.costUSD != nil, validIdentifier(generation) else {
                throw AgentEventValidationError.invalidCost
            }
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

    private static func validatePresentationText(_ value: String?, name: String) throws {
        try check(value, name: name, maximumBytes: AgentPresentationText.maximumBytes)
        if let value,
           value.count > AgentPresentationText.maximumCharacters || AgentPresentationText.normalized(value) != value {
            throw AgentEventValidationError.stringTooLong(name)
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    public static func validResponseToken(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

public enum AgentPresentationText {
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
