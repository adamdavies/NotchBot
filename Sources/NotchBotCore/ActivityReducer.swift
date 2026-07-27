import Foundation

public enum RobotState: String, Equatable, Sendable {
    case idle
    case working
    case attention
}

public struct SessionActivity: Equatable, Sendable {
    public let source: AgentSource
    public let sessionID: String
    public var state: RobotState
    public var updatedAt: Date
    public var workingDirectory: String?
    public var terminalBundleIdentifier: String?
    public var terminalProcessID: Int32?
    public var reason: String?
}

public struct ActivityChange: Equatable, Sendable {
    public let state: RobotState
    public let primarySession: SessionActivity?
    public let shouldNotify: Bool
}

public struct ActivityReducer: Sendable {
    private var sessions: [String: SessionActivity] = [:]

    public init() {}

    @discardableResult
    public mutating func apply(_ event: AgentEvent) -> ActivityChange {
        let key = Self.key(source: event.source, sessionID: event.sessionID)
        let wasAttention = sessions[key]?.state == .attention

        if event.kind == .cleared {
            sessions.removeValue(forKey: key)
        } else {
            sessions[key] = SessionActivity(
                source: event.source,
                sessionID: event.sessionID,
                state: event.kind == .attention ? .attention : .working,
                updatedAt: event.timestamp,
                workingDirectory: event.workingDirectory ?? sessions[key]?.workingDirectory,
                terminalBundleIdentifier: event.terminalBundleIdentifier ?? sessions[key]?.terminalBundleIdentifier,
                terminalProcessID: event.terminalProcessID ?? sessions[key]?.terminalProcessID,
                reason: event.reason
            )
        }

        let current = primarySession
        return ActivityChange(
            state: current?.state ?? .idle,
            primarySession: current,
            shouldNotify: event.kind == .attention && !wasAttention
        )
    }

    public mutating func removeSessions(olderThan cutoff: Date) {
        sessions = sessions.filter { $0.value.updatedAt >= cutoff }
    }

    @discardableResult
    public mutating func expireAttention(
        source: AgentSource,
        sessionID: String,
        unchangedSince timestamp: Date
    ) -> ActivityChange {
        let key = Self.key(source: source, sessionID: sessionID)
        if let session = sessions[key], session.state == .attention, session.updatedAt <= timestamp {
            sessions.removeValue(forKey: key)
        }
        let current = primarySession
        return ActivityChange(state: current?.state ?? .idle, primarySession: current, shouldNotify: false)
    }

    public var state: RobotState {
        primarySession?.state ?? .idle
    }

    public var primarySession: SessionActivity? {
        sessions.values.sorted { lhs, rhs in
            if lhs.state != rhs.state {
                return Self.priority(lhs.state) > Self.priority(rhs.state)
            }
            return lhs.updatedAt > rhs.updatedAt
        }.first
    }

    public var sessionCount: Int {
        sessions.count
    }

    public var attentionCount: Int {
        sessions.values.filter { $0.state == .attention }.count
    }

    private static func key(source: AgentSource, sessionID: String) -> String {
        "\(source.rawValue):\(sessionID)"
    }

    private static func priority(_ state: RobotState) -> Int {
        switch state {
        case .idle: 0
        case .working: 1
        case .attention: 2
        }
    }
}
