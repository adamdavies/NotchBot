import Foundation

public enum RobotState: String, Equatable, Sendable {
    case idle
    case working
    case attention
}

public struct SessionActivity: Equatable, Identifiable, Sendable {
    public let source: AgentSource
    public let sessionID: String
    public var state: RobotState
    public var updatedAt: Date
    public var workingDirectory: String?
    public var terminalBundleIdentifier: String?
    public var terminalProcessID: Int32?
    public var reason: String?
    public var taskLabel: String?

    public var id: String { "\(source.rawValue):\(sessionID)" }
}

public struct ActivityChange: Equatable, Sendable {
    public let state: RobotState
    public let primarySession: SessionActivity?
    public let shouldNotify: Bool
}

public struct ActivityReducer: Sendable {
    public static let maximumSessions = 256

    private var sessions: [String: SessionActivity] = [:]
    private var latestEventAt: [String: Date] = [:]
    private var latestMetadataAt: [String: Date] = [:]
    private var pendingMetadata: [String: (taskLabel: String, updatedAt: Date)] = [:]

    public init() {}

    public func canApply(_ event: AgentEvent) -> Bool {
        let key = Self.key(source: event.source, sessionID: event.sessionID)
        let latest = event.kind == .metadata ? latestMetadataAt[key] : latestEventAt[key]
        return latest.map { event.timestamp > $0 } ?? true
    }

    @discardableResult
    public mutating func apply(_ event: AgentEvent) -> ActivityChange {
        let key = Self.key(source: event.source, sessionID: event.sessionID)
        let latest = event.kind == .metadata ? latestMetadataAt[key] : latestEventAt[key]
        if let latest, event.timestamp <= latest {
            return currentChange()
        }
        if event.kind == .metadata {
            latestMetadataAt[key] = event.timestamp
        } else {
            latestEventAt[key] = event.timestamp
        }
        let wasAttention = sessions[key]?.state == .attention

        if event.kind == .cleared {
            sessions.removeValue(forKey: key)
            pendingMetadata.removeValue(forKey: key)
            latestMetadataAt.removeValue(forKey: key)
        } else if event.kind == .metadata {
            if let taskLabel = event.taskLabel {
                if sessions[key] != nil {
                    sessions[key]?.taskLabel = taskLabel
                } else {
                    if pendingMetadata[key] == nil, pendingMetadata.count >= Self.maximumSessions,
                       let oldest = pendingMetadata.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
                        pendingMetadata.removeValue(forKey: oldest)
                        latestMetadataAt.removeValue(forKey: oldest)
                    }
                    pendingMetadata[key] = (taskLabel, event.timestamp)
                }
            }
        } else {
            if sessions[key] == nil, sessions.count >= Self.maximumSessions,
               let oldest = sessions.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
                sessions.removeValue(forKey: oldest)
                latestEventAt.removeValue(forKey: oldest)
            }
            sessions[key] = SessionActivity(
                source: event.source,
                sessionID: event.sessionID,
                state: event.kind == .attention ? .attention : .working,
                updatedAt: event.timestamp,
                workingDirectory: event.workingDirectory ?? sessions[key]?.workingDirectory,
                terminalBundleIdentifier: event.terminalBundleIdentifier ?? sessions[key]?.terminalBundleIdentifier,
                terminalProcessID: event.terminalProcessID ?? sessions[key]?.terminalProcessID,
                reason: event.reason,
                taskLabel: event.taskLabel ?? sessions[key]?.taskLabel ?? pendingMetadata[key]?.taskLabel
            )
            pendingMetadata.removeValue(forKey: key)
        }
        trimEventHistory()

        let current = primarySession
        return ActivityChange(
            state: current?.state ?? .idle,
            primarySession: current,
            shouldNotify: event.kind == .attention && !wasAttention
        )
    }

    public mutating func removeSessions(olderThan cutoff: Date) {
        let staleKeys = sessions.compactMap { $0.value.updatedAt < cutoff ? $0.key : nil }
        for key in staleKeys {
            sessions.removeValue(forKey: key)
            latestEventAt.removeValue(forKey: key)
            latestMetadataAt.removeValue(forKey: key)
        }
        latestEventAt = latestEventAt.filter { $0.value >= cutoff }
        latestMetadataAt = latestMetadataAt.filter { $0.value >= cutoff }
        pendingMetadata = pendingMetadata.filter { $0.value.updatedAt >= cutoff }
    }

    @discardableResult
    public mutating func expireAttention(
        source: AgentSource,
        sessionID: String,
        unchangedSince timestamp: Date
    ) -> ActivityChange {
        let key = Self.key(source: source, sessionID: sessionID)
        if let session = sessions[key], session.state == .attention, session.updatedAt <= timestamp {
            sessions[key]?.state = .idle
            sessions[key]?.reason = nil
        }
        let current = primarySession
        return ActivityChange(state: current?.state ?? .idle, primarySession: current, shouldNotify: false)
    }

    @discardableResult
    public mutating func acknowledgeAttention(source: AgentSource, sessionID: String) -> ActivityChange {
        let key = Self.key(source: source, sessionID: sessionID)
        guard let session = sessions[key], session.state == .attention else {
            return currentChange()
        }
        sessions[key]?.state = .idle
        sessions[key]?.reason = nil
        let current = primarySession
        return ActivityChange(state: current?.state ?? .idle, primarySession: current, shouldNotify: false)
    }

    public var state: RobotState {
        primarySession?.state ?? .idle
    }

    public var primarySession: SessionActivity? {
        activities.first
    }

    public var activities: [SessionActivity] {
        sessions.values.sorted { lhs, rhs in
            if lhs.state != rhs.state {
                return Self.priority(lhs.state) > Self.priority(rhs.state)
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id < rhs.id
        }
    }

    public var sessionCount: Int {
        sessions.count
    }

    public var activeCount: Int {
        sessions.values.filter { $0.state != .idle }.count
    }

    public var attentionCount: Int {
        sessions.values.filter { $0.state == .attention }.count
    }

    public var pendingMetadataCount: Int {
        pendingMetadata.count
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

    private func currentChange() -> ActivityChange {
        let current = primarySession
        return ActivityChange(state: current?.state ?? .idle, primarySession: current, shouldNotify: false)
    }

    private mutating func trimEventHistory() {
        while latestEventAt.count > Self.maximumSessions * 2 {
            let candidates = latestEventAt.filter { sessions[$0.key] == nil && pendingMetadata[$0.key] == nil }
            guard let oldest = candidates.min(by: { $0.value < $1.value })?.key else { return }
            latestEventAt.removeValue(forKey: oldest)
        }
    }
}
