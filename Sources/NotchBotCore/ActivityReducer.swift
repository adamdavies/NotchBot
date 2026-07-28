import Foundation

public enum RobotState: String, Equatable, Sendable {
    case idle
    case working
    case attention
}

public struct SessionActivity: Equatable, Identifiable, Sendable {
    public let source: AgentSource
    public let sessionID: String
    public var parentSessionID: String?
    public var state: RobotState
    public var updatedAt: Date
    public var workingDirectory: String?
    public var terminalBundleIdentifier: String?
    public var terminalProcessID: Int32?
    public var reason: String?
    public var taskLabel: String?

    public var id: String { "\(source.rawValue):\(sessionID)" }
    public var isSubagent: Bool { parentSessionID != nil }
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
    private var latestClearedAt: [String: Date] = [:]
    private var pendingMetadata: [String: PendingMetadata] = [:]

    public init() {}

    public func canApply(_ event: AgentEvent) -> Bool {
        let key = Self.key(source: event.source, sessionID: event.sessionID)
        let latest = event.kind == .metadata ? latestMetadataAt[key] : latestEventAt[key]
        guard latest.map({ event.timestamp > $0 }) ?? true else { return false }
        guard let parentSessionID = event.parentSessionID else { return true }
        let parentKey = Self.key(source: event.source, sessionID: parentSessionID)
        return latestClearedAt[parentKey].map { event.timestamp > $0 } ?? true
    }

    @discardableResult
    public mutating func apply(_ event: AgentEvent) -> ActivityChange {
        if let rejected = rejectDescendantOfClearedSession(event) { return rejected }
        let key = Self.key(source: event.source, sessionID: event.sessionID)
        guard canApply(event) else { return currentChange() }
        if event.kind == .metadata {
            latestMetadataAt[key] = event.timestamp
        } else {
            latestEventAt[key] = event.timestamp
        }
        let wasAttention = sessions[key]?.state == .attention

        if event.kind == .cleared {
            removeTree(rootedAt: key, clearedAt: event.timestamp)
        } else if event.kind == .metadata {
            let parentSessionID = normalizedParentSessionID(event.parentSessionID, for: key, source: event.source)
            if sessions[key] != nil {
                if let taskLabel = event.taskLabel {
                    sessions[key]?.taskLabel = taskLabel
                }
                if let parentSessionID, event.timestamp >= sessions[key]!.updatedAt {
                    sessions[key]?.parentSessionID = parentSessionID
                }
            } else if event.taskLabel != nil || parentSessionID != nil {
                if pendingMetadata[key] == nil, pendingMetadata.count >= Self.maximumSessions,
                   let oldest = pendingMetadata.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
                    pendingMetadata.removeValue(forKey: oldest)
                    latestMetadataAt.removeValue(forKey: oldest)
                }
                pendingMetadata[key] = PendingMetadata(
                    source: event.source,
                    taskLabel: event.taskLabel ?? pendingMetadata[key]?.taskLabel,
                    parentSessionID: parentSessionID ?? pendingMetadata[key]?.parentSessionID,
                    updatedAt: event.timestamp
                )
            }
        } else {
            latestClearedAt.removeValue(forKey: key)
            if sessions[key] == nil, sessions.count >= Self.maximumSessions,
               let oldest = sessions.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
                removeTree(rootedAt: rootKey(for: oldest))
            }
            let parentSessionID = normalizedParentSessionID(
                event.parentSessionID ?? sessions[key]?.parentSessionID ?? pendingMetadata[key]?.parentSessionID,
                for: key,
                source: event.source
            )
            sessions[key] = SessionActivity(
                source: event.source,
                sessionID: event.sessionID,
                parentSessionID: parentSessionID,
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

    public mutating func rejectDescendantOfClearedSession(_ event: AgentEvent) -> ActivityChange? {
        guard let parentSessionID = event.parentSessionID else { return nil }
        let parentKey = Self.key(source: event.source, sessionID: parentSessionID)
        guard let clearedAt = latestClearedAt[parentKey], event.timestamp <= clearedAt else { return nil }
        let key = Self.key(source: event.source, sessionID: event.sessionID)
        removeTree(rootedAt: key, clearedAt: clearedAt)
        trimEventHistory()
        return currentChange()
    }

    public mutating func removeSessions(olderThan cutoff: Date) {
        let staleKeys = sessions.compactMap { $0.value.updatedAt < cutoff ? $0.key : nil }
        for key in staleKeys where sessions[key] != nil {
            let subtree = treeKeys(rootedAt: key)
            if subtree.compactMap({ sessions[$0] }).allSatisfy({ $0.updatedAt < cutoff }) {
                removeTree(rootedAt: key)
            }
        }
        latestEventAt = latestEventAt.filter { $0.value >= cutoff }
        latestMetadataAt = latestMetadataAt.filter { $0.value >= cutoff }
        latestClearedAt = latestClearedAt.filter { $0.value >= cutoff }
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
        sessions.values.sorted(by: Self.activityComesFirst).first
    }

    public var activities: [SessionActivity] {
        let groups = Dictionary(grouping: sessions.keys, by: rootKey(for:))
        let orderedRoots = groups.keys.sorted { lhs, rhs in
            let left = groupSortValue(for: groups[lhs] ?? [])
            let right = groupSortValue(for: groups[rhs] ?? [])
            if left.priority != right.priority { return left.priority > right.priority }
            if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
            return lhs < rhs
        }
        return orderedRoots.flatMap { flattenedGroup(rootKey: $0, members: Set(groups[$0] ?? [])) }
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

    private static func activityComesFirst(_ lhs: SessionActivity, _ rhs: SessionActivity) -> Bool {
        if lhs.state != rhs.state { return priority(lhs.state) > priority(rhs.state) }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }

    private func normalizedParentSessionID(
        _ parentSessionID: String?,
        for key: String,
        source: AgentSource
    ) -> String? {
        guard let parentSessionID else { return nil }
        let parentKey = Self.key(source: source, sessionID: parentSessionID)
        guard parentKey != key else { return nil }
        var current: String? = parentKey
        var visited: Set<String> = []
        while let candidate = current {
            guard candidate != key else { return nil }
            guard let session = sessions[candidate] else { break }
            guard visited.insert(candidate).inserted else { return nil }
            current = session.parentSessionID.map { Self.key(source: session.source, sessionID: $0) }
        }
        return parentSessionID
    }

    private func rootKey(for key: String) -> String {
        var current = key
        var visited: Set<String> = []
        while let session = sessions[current], let parentSessionID = session.parentSessionID {
            guard visited.insert(current).inserted else { return key }
            let parentKey = Self.key(source: session.source, sessionID: parentSessionID)
            guard sessions[parentKey] != nil else { return current }
            current = parentKey
        }
        return current
    }

    private func groupSortValue(for keys: [String]) -> (priority: Int, updatedAt: Date) {
        keys.compactMap { sessions[$0] }.reduce((priority: -1, updatedAt: .distantPast)) { result, session in
            let priority = Self.priority(session.state)
            if priority > result.priority { return (priority, session.updatedAt) }
            if priority == result.priority { return (priority, max(result.updatedAt, session.updatedAt)) }
            return result
        }
    }

    private func flattenedGroup(rootKey: String, members: Set<String>) -> [SessionActivity] {
        var result: [SessionActivity] = []
        var visited: Set<String> = []
        func append(_ key: String) {
            guard members.contains(key), visited.insert(key).inserted, let session = sessions[key] else { return }
            result.append(session)
            let children = members.filter { childKey in
                guard let child = sessions[childKey], let parentSessionID = child.parentSessionID else { return false }
                return Self.key(source: child.source, sessionID: parentSessionID) == key
            }.compactMap { sessions[$0] }.sorted(by: Self.activityComesFirst)
            for child in children { append(child.id) }
        }
        append(rootKey)
        for leftover in members.compactMap({ sessions[$0] }).sorted(by: Self.activityComesFirst) {
            append(leftover.id)
        }
        return result
    }

    private mutating func removeTree(rootedAt rootKey: String, clearedAt: Date? = nil) {
        let keysToRemove = treeKeys(rootedAt: rootKey)
        for key in keysToRemove {
            sessions.removeValue(forKey: key)
            if let clearedAt {
                latestEventAt[key] = max(latestEventAt[key] ?? .distantPast, clearedAt)
                latestClearedAt[key] = max(latestClearedAt[key] ?? .distantPast, clearedAt)
            } else {
                latestEventAt.removeValue(forKey: key)
                latestClearedAt.removeValue(forKey: key)
            }
            latestMetadataAt.removeValue(forKey: key)
            pendingMetadata.removeValue(forKey: key)
        }
    }

    private func treeKeys(rootedAt rootKey: String) -> Set<String> {
        var keys: Set<String> = [rootKey]
        var foundDescendant = true
        while foundDescendant {
            foundDescendant = false
            for (key, session) in sessions where !keys.contains(key) {
                guard let parentSessionID = session.parentSessionID else { continue }
                let parentKey = Self.key(source: session.source, sessionID: parentSessionID)
                if keys.contains(parentKey) {
                    keys.insert(key)
                    foundDescendant = true
                }
            }
            for (key, metadata) in pendingMetadata where !keys.contains(key) {
                guard let parentSessionID = metadata.parentSessionID else { continue }
                let parentKey = Self.key(source: metadata.source, sessionID: parentSessionID)
                if keys.contains(parentKey) {
                    keys.insert(key)
                    foundDescendant = true
                }
            }
        }
        return keys
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
        while latestClearedAt.count > Self.maximumSessions * 2 {
            guard let oldest = latestClearedAt.min(by: { $0.value < $1.value })?.key else { return }
            latestClearedAt.removeValue(forKey: oldest)
        }
    }
}

private struct PendingMetadata: Sendable {
    let source: AgentSource
    let taskLabel: String?
    let parentSessionID: String?
    let updatedAt: Date
}
