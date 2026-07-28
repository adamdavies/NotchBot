import Foundation

public enum AgentPermissionDecision: String, Codable, Sendable, CaseIterable {
    case allowOnce
    case alwaysAllow
    case decline
}

public struct AgentPermissionResponse: Codable, Equatable, Sendable {
    public static let protocolVersion = 1

    public let version: Int
    public let responseToken: String
    public let decision: AgentPermissionDecision
    public let timestamp: Date

    public init(
        responseToken: String,
        decision: AgentPermissionDecision,
        timestamp: Date = Date()
    ) {
        version = Self.protocolVersion
        self.responseToken = responseToken
        self.decision = decision
        self.timestamp = timestamp
    }
}

public enum AgentPermissionResponseValidationError: Error, Equatable, Sendable {
    case payloadTooLarge
    case unsupportedVersion
    case invalidResponseToken
    case invalidTimestamp
}

public enum AgentPermissionResponseValidator {
    public static let maximumDatagramBytes = 1_024

    public static func validate(
        _ response: AgentPermissionResponse,
        encodedSize: Int? = nil,
        now: Date = Date()
    ) throws {
        if let encodedSize, encodedSize > maximumDatagramBytes {
            throw AgentPermissionResponseValidationError.payloadTooLarge
        }
        guard response.version == AgentPermissionResponse.protocolVersion else {
            throw AgentPermissionResponseValidationError.unsupportedVersion
        }
        guard AgentEventValidator.validResponseToken(response.responseToken) else {
            throw AgentPermissionResponseValidationError.invalidResponseToken
        }
        let timestamp = response.timestamp.timeIntervalSince1970
        guard timestamp.isFinite,
              abs(response.timestamp.timeIntervalSince(now)) <= AgentEventValidator.maximumTimestampSkew else {
            throw AgentPermissionResponseValidationError.invalidTimestamp
        }
    }
}
