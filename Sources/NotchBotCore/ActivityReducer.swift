import Foundation

public enum RobotState: String, Equatable, Hashable, Sendable {
    case idle
    case working
    case attention
}

public struct AgentPendingRequest: Equatable, Sendable {
    public let id: String
    public let kind: AgentRequestKind
    public let openedAt: Date
    public let reason: String?
    public var permission: AgentPermissionRequest?
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
    public var sessionTitle: String?
    public var activityDescription: String?
    public var permission: AgentPermissionRequest?
    public var isAwaitingPermissionResolution: Bool
    public var pendingRequests: [AgentPendingRequest]
    public var providerState: RobotState
    public var providerReason: String?
    public var providerUpdatedAt: Date
    public var hasProviderActivity: Bool

    public var costUSD: Double?
    /// The provider's cumulative-cost generation. OpenCode restarts its running total when this
    /// changes, so it is retained to rebase the cycle baseline instead of producing a negative delta.
    public var costGeneration: String?
    /// Latest provider-reported context-window usage, 0...100. Process memory only — it is never
    /// persisted, so it is absent again after a restart until the provider reports it afresh.
    public var contextUsedPercentage: Double?

    /// When the current run of work began. `nil` until the session shows its first non-metadata
    /// provider activity; a completion that arrives first adopts its own timestamp.
    public var cycleStartedAt: Date?
    /// Set once the current cycle has been handed to the session timeline, so a later
    /// acknowledgement, clear, or repeated completion attention cannot record it twice.
    public var isCycleArchived: Bool
    /// The cumulative provider cost at the moment this cycle started. The cycle's own cost is the
    /// delta from here, so a session's second run is not charged for its first.
    public var cycleCostBaseline: Double?
    /// Whether valid cost metadata was observed during this cycle while tracking was enabled. This
    /// is what separates "cost tracking was off" from "tracked and cost nothing".
    public var hasCycleCost: Bool

    public var key: SessionKey { SessionKey(source: source, sessionID: sessionID) }
    public var id: String { key.rawValue }
    public var isSubagent: Bool { parentSessionID != nil }
    public var pendingRequestCount: Int { pendingRequests.count }

    /// This cycle's spend, or `nil` when none was observed. A delta that cannot be trusted — a
    /// cumulative value that moved backwards despite the generation rebase — is reported as absent
    /// rather than clamped to zero, because zero is a claim that the cycle was free.
    public var cycleCostUSD: Double? {
        guard hasCycleCost, let costUSD, costUSD.isFinite else { return nil }
        let delta = costUSD - (cycleCostBaseline ?? 0)
        guard delta.isFinite, delta >= 0 else { return nil }
        return delta
    }
}

public struct ActivityChange: Equatable, Sendable {
    public let state: RobotState
    public let primarySession: SessionActivity?
    public let shouldNotify: Bool
    /// Cycles that reached a terminal state on this mutation, for the session timeline. Empty for
    /// every non-terminal path: stale cleanup, capacity eviction, delayed-event rejection, attention
    /// expiry, and manual dismissal all remove rows without recording them.
    public let completedSessions: [CompletedSession]
}

/// Why a session subtree is being removed. Only `providerTerminal` produces timeline entries — the
/// rest are housekeeping or a user dismissing a row they have already dealt with.
public enum SessionRemovalDisposition: Equatable, Sendable {
    /// The provider reported the session ended.
    case providerTerminal
    /// The user cleared the row from the queue.
    case manualDismissal
    /// The session went quiet long enough to be swept.
    case staleCleanup
    /// Room had to be made, or an event arrived for a subtree whose parent was already cleared.
    case capacityCleanup
}

public struct ActivityReducer: Sendable {
    public static let maximumSessions = 256

    /// The cumulative provider cost already recorded for a session before this launch, if any.
    ///
    /// A session that was already running when NotchBot started reports its whole running total on
    /// its first metadata event. Without a baseline the first cycle NotchBot observes is charged for
    /// every dollar spent before it was watching — a twelve-second row billed for the whole session.
    /// Seeded from the cost baselines that already persist across restarts for the daily total.
    public var launchCostBaseline: (@Sendable (SessionKey) -> Double?)?

    private var sessions: [SessionKey: SessionActivity] = [:]
    private var latestEventAt: [SessionKey: Date] = [:]
    private var latestMetadataAt: [SessionKey: Date] = [:]
    private var latestSessionTitleAt: [SessionKey: Date] = [:]
    private var latestActivityAt: [SessionKey: Date] = [:]
    private var latestRequestAt: [RequestEventKey: Date] = [:]
    private var resolvedRequests: Set<RequestEventKey> = []
    private var acknowledgedRequests: Set<RequestEventKey> = []
    private var acknowledgedLegacyPermissions: Set<String> = []
    private var latestClearedAt: [SessionKey: Date] = [:]
    private var pendingMetadata: [SessionKey: PendingMetadata] = [:]

    public init() {}

    public func canApply(_ event: AgentEvent) -> Bool {
        let key = Self.key(source: event.source, sessionID: event.sessionID)
        if let request = event.request {
            guard latestClearedAt[key].map({ event.timestamp > $0 }) ?? true else { return false }
            if request.state == .resolved {
                return !resolvedRequests.contains(Self.requestKey(event: event, request: request))
            }
            let latest = latestRequestAt[Self.requestKey(event: event, request: request)]
            return latest.map({ event.timestamp > $0 }) ?? true
        }
        let latest = event.kind == .metadata ? latestMetadataAt[key] : latestEventAt[key]
        guard latest.map({ event.timestamp > $0 }) ?? true else { return false }
        guard latestClearedAt[key].map({ event.timestamp > $0 }) ?? true else { return false }
        guard let parentSessionID = event.parentSessionID else { return true }
        let parentKey = Self.key(source: event.source, sessionID: parentSessionID)
        return latestClearedAt[parentKey].map { event.timestamp > $0 } ?? true
    }

    public func activity(source: AgentSource, sessionID: String) -> SessionActivity? {
        sessions[Self.key(source: source, sessionID: sessionID)]
    }

    @discardableResult
    public mutating func apply(_ event: AgentEvent) -> ActivityChange {
        if let rejected = rejectDescendantOfClearedSession(event) { return rejected }
        let key = Self.key(source: event.source, sessionID: event.sessionID)
        guard canApply(event) else { return currentChange() }
        let appliesSessionTitle = event.sessionTitle != nil
            && (latestSessionTitleAt[key].map { event.timestamp > $0 } ?? true)
        let appliesActivity = event.activityDescription != nil
            && (latestActivityAt[key].map { event.timestamp > $0 } ?? true)
        if appliesSessionTitle { latestSessionTitleAt[key] = event.timestamp }
        if appliesActivity { latestActivityAt[key] = event.timestamp }
        if let request = event.request {
            let requestKey = Self.requestKey(event: event, request: request)
            latestRequestAt[requestKey] = max(event.timestamp, latestRequestAt[requestKey] ?? .distantPast)
        } else if event.kind == .metadata {
            latestMetadataAt[key] = event.timestamp
        } else {
            latestEventAt[key] = event.timestamp
        }
        if let request = event.request, request.state == .opened,
           resolvedRequests.contains(Self.requestKey(event: event, request: request)) {
            trimEventHistory()
            return currentChange()
        }
        let previousSession = sessions[key]
        if let request = event.request, request.state == .opened,
           previousSession?.pendingRequests.contains(where: { $0.id == request.id && $0.kind == request.kind }) != true,
           totalPendingRequestCount >= Self.maximumSessions {
            trimEventHistory()
            return currentChange()
        }
        let wasAttention = previousSession?.state == .attention
        let isNewRequest = event.request.map { request in
            request.state == .opened
                && previousSession?.pendingRequests.contains(where: { $0.id == request.id && $0.kind == request.kind }) != true
        } ?? false
        let isNewLegacyPermission = event.request == nil && event.permission.map {
            $0.responseToken != previousSession?.permission?.responseToken
        } ?? false

        var completedSessions: [CompletedSession] = []
        if event.kind == .cleared {
            completedSessions = removeTree(
                rootedAt: key,
                clearedAt: event.timestamp,
                disposition: .providerTerminal,
                endedAt: event.timestamp
            )
        } else if event.kind == .metadata {
            let parentSessionID = normalizedParentSessionID(event.parentSessionID, for: key, source: event.source)
            let parentClearedAt = parentSessionID.flatMap {
                latestClearedAt[Self.key(source: event.source, sessionID: $0)]
            }
            if let session = sessions[key], let parentClearedAt,
               !session.hasProviderActivity || session.providerUpdatedAt <= parentClearedAt {
                // The provider already ended this subtree's parent; this late metadata is what
                // finally reveals the relationship, so the subtree ends on the provider's terms.
                completedSessions = removeTree(
                    rootedAt: key,
                    clearedAt: parentClearedAt,
                    disposition: .providerTerminal,
                    endedAt: parentClearedAt
                )
            } else if sessions[key] != nil {
                if appliesSessionTitle { sessions[key]?.sessionTitle = event.sessionTitle }
                if appliesActivity { sessions[key]?.activityDescription = event.activityDescription }
                if let parentSessionID, event.timestamp >= sessions[key]!.updatedAt {
                    sessions[key]?.parentSessionID = parentSessionID
                }
                if let cost = event.costUSD, cost >= 0, cost.isFinite {
                    // A *changed* generation means the provider restarted its running total, so
                    // rebase rather than letting the delta go negative. Seeing a generation for the
                    // first time is not a restart, and must not discard a launch baseline.
                    if let previousGeneration = sessions[key]?.costGeneration,
                       previousGeneration != event.costGeneration {
                        sessions[key]?.cycleCostBaseline = nil
                    }
                    sessions[key]?.costGeneration = event.costGeneration
                    sessions[key]?.costUSD = cost
                    sessions[key]?.hasCycleCost = true
                }
                // Presence is the signal: a present update replaces the percentage even when its
                // value is nil, which is how compaction retracts a figure that no longer holds.
                if let contextWindow = event.contextWindow {
                    sessions[key]?.contextUsedPercentage = contextWindow.usedPercentage
                }
            } else if parentClearedAt == nil
                && (appliesSessionTitle || appliesActivity || parentSessionID != nil
                    || event.costUSD != nil || event.contextWindow != nil) {
                if pendingMetadata[key] == nil, pendingMetadata.count >= Self.maximumSessions,
                   let oldest = pendingMetadata.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
                    pendingMetadata.removeValue(forKey: oldest)
                    latestMetadataAt.removeValue(forKey: oldest)
                    latestSessionTitleAt.removeValue(forKey: oldest)
                    latestActivityAt.removeValue(forKey: oldest)
                }
                pendingMetadata[key] = PendingMetadata(
                    source: event.source,
                    sessionTitle: appliesSessionTitle ? event.sessionTitle : pendingMetadata[key]?.sessionTitle,
                    activityDescription: appliesActivity
                        ? event.activityDescription : pendingMetadata[key]?.activityDescription,
                    parentSessionID: parentSessionID ?? pendingMetadata[key]?.parentSessionID,
                    costUSD: [event.costUSD, pendingMetadata[key]?.costUSD].compactMap { $0 }.max(),
                    costGeneration: event.costGeneration ?? pendingMetadata[key]?.costGeneration,
                    contextUsedPercentage: event.contextWindow.map { $0.usedPercentage }
                        ?? pendingMetadata[key]?.contextUsedPercentage,
                    updatedAt: event.timestamp
                )
            }
        } else if event.kind == .requestResolved, let request = event.request {
            let requestKey = Self.requestKey(event: event, request: request)
            resolvedRequests.insert(requestKey)
            acknowledgedRequests.remove(requestKey)
            if var session = sessions[key] {
                session.pendingRequests.removeAll { $0.id == request.id && $0.kind == request.kind }
                session.updatedAt = max(event.timestamp, session.updatedAt)
                sessions[key] = session
                applyRequestOverlay(to: key)
            }
        } else {
            latestClearedAt.removeValue(forKey: key)
            if sessions[key] == nil, sessions.count >= Self.maximumSessions,
               let oldest = sessions.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
                removeTree(rootedAt: rootKey(for: oldest), disposition: .capacityCleanup)
            }
            let parentSessionID = normalizedParentSessionID(
                event.parentSessionID ?? sessions[key]?.parentSessionID ?? pendingMetadata[key]?.parentSessionID,
                for: key,
                source: event.source
            )
            var pendingRequests = previousSession?.pendingRequests ?? []
            let opensRequest = event.request?.state == .opened
            if let request = event.request, opensRequest,
               !resolvedRequests.contains(Self.requestKey(event: event, request: request)) {
                let pending = AgentPendingRequest(
                    id: request.id,
                    kind: request.kind,
                    openedAt: event.timestamp,
                    reason: event.reason,
                    permission: event.permission
                )
                if let index = pendingRequests.firstIndex(where: { $0.id == request.id && $0.kind == request.kind }) {
                    pendingRequests[index] = pending
                } else if totalPendingRequestCount < Self.maximumSessions {
                    pendingRequests.append(pending)
                    pendingRequests.sort { $0.openedAt < $1.openedAt }
                }
            }
            let providerState = opensRequest
                ? previousSession?.providerState ?? .working
                : event.kind == .attention ? RobotState.attention : .working
            let providerReason = opensRequest ? previousSession?.providerReason : event.reason
            let preservesLegacyPermission = event.request == nil
                && event.kind == .attention
                && event.reason == previousSession?.reason
            let legacyPermission = event.request == nil
                ? event.permission ?? (preservesLegacyPermission ? previousSession?.permission : nil)
                : nil
            let presentedRequest = pendingRequests.first(where: { $0.permission != nil })
            let displayedRequest = presentedRequest ?? pendingRequests.first
            let hasPendingRequests = !pendingRequests.isEmpty
            let hasUnacknowledgedRequests = pendingRequests.contains {
                !acknowledgedRequests.contains(Self.requestKey(
                    source: event.source,
                    sessionID: event.sessionID,
                    request: $0
                ))
            }
            let legacyPermissionIsAcknowledged = legacyPermission.map {
                acknowledgedLegacyPermissions.contains($0.responseToken)
            } ?? false
            let providerUpdatedAt = opensRequest
                ? previousSession?.providerUpdatedAt ?? event.timestamp
                : event.timestamp
            let hasProviderActivity = opensRequest ? previousSession?.hasProviderActivity ?? false : true

            // Cycle bookkeeping for the session timeline. A request opening is not new work, so it
            // must never move the start time; a `.working` event after an archived completion is the
            // start of a genuinely new run and rebases the cost baseline onto what has been spent so
            // far, so the second run is not charged for the first.
            var cycleStartedAt = previousSession?.cycleStartedAt
            var isCycleArchived = previousSession?.isCycleArchived ?? false
            // A session appearing for the first time starts from whatever it had already spent before
            // this launch, so only what accrues from here counts towards the cycle.
            var cycleCostBaseline = previousSession == nil
                ? launchCostBaseline?(key)
                : previousSession?.cycleCostBaseline
            var hasCycleCost = previousSession?.hasCycleCost ?? (pendingMetadata[key]?.costUSD != nil)
            if !opensRequest {
                if cycleStartedAt == nil {
                    cycleStartedAt = event.timestamp
                } else if isCycleArchived, event.kind == .working {
                    cycleStartedAt = event.timestamp
                    isCycleArchived = false
                    cycleCostBaseline = previousSession?.costUSD
                    hasCycleCost = false
                }
            }

            sessions[key] = SessionActivity(
                source: event.source,
                sessionID: event.sessionID,
                parentSessionID: parentSessionID,
                state: hasPendingRequests
                    ? (hasUnacknowledgedRequests ? .attention : .idle)
                    : (legacyPermissionIsAcknowledged ? .idle : providerState),
                updatedAt: max(event.timestamp, previousSession?.updatedAt ?? .distantPast),
                workingDirectory: event.workingDirectory ?? sessions[key]?.workingDirectory,
                terminalBundleIdentifier: event.terminalBundleIdentifier ?? sessions[key]?.terminalBundleIdentifier,
                terminalProcessID: event.terminalProcessID ?? sessions[key]?.terminalProcessID,
                reason: hasPendingRequests ? displayedRequest?.reason : providerReason,
                sessionTitle: appliesSessionTitle
                    ? event.sessionTitle : sessions[key]?.sessionTitle ?? pendingMetadata[key]?.sessionTitle,
                activityDescription: appliesActivity
                    ? event.activityDescription
                    : sessions[key]?.activityDescription ?? pendingMetadata[key]?.activityDescription,
                permission: presentedRequest?.permission ?? legacyPermission,
                isAwaitingPermissionResolution: hasPendingRequests || legacyPermission != nil
                    || (preservesLegacyPermission && previousSession?.isAwaitingPermissionResolution == true),
                pendingRequests: pendingRequests,
                providerState: providerState,
                providerReason: providerReason,
                providerUpdatedAt: providerUpdatedAt,
                hasProviderActivity: hasProviderActivity,
                costUSD: previousSession?.costUSD ?? pendingMetadata[key]?.costUSD,
                costGeneration: previousSession?.costGeneration ?? pendingMetadata[key]?.costGeneration,
                contextUsedPercentage: previousSession?.contextUsedPercentage
                    ?? pendingMetadata[key]?.contextUsedPercentage,
                cycleStartedAt: cycleStartedAt,
                isCycleArchived: isCycleArchived,
                cycleCostBaseline: cycleCostBaseline,
                hasCycleCost: hasCycleCost
            )
            pendingMetadata.removeValue(forKey: key)

            // A top-level session entering completion attention is the main way a cycle reaches the
            // timeline. The archived flag makes it idempotent: a repeated completion attention, a
            // later acknowledgement, and the eventual clear all find the cycle already recorded.
            if event.isCompletionAttention, let session = sessions[key],
               !session.isSubagent, !session.isCycleArchived {
                completedSessions.append(snapshot(of: session, endedAt: event.timestamp))
                sessions[key]?.isCycleArchived = true
            }
        }
        trimEventHistory()

        let current = primarySession
        return ActivityChange(
            state: current?.state ?? .idle,
            primarySession: current,
            shouldNotify: event.kind == .attention
                && (isNewRequest || isNewLegacyPermission || event.request == nil && !wasAttention),
            completedSessions: completedSessions
        )
    }

    public mutating func rejectDescendantOfClearedSession(_ event: AgentEvent) -> ActivityChange? {
        guard let parentSessionID = event.parentSessionID else { return nil }
        let parentKey = Self.key(source: event.source, sessionID: parentSessionID)
        guard let clearedAt = latestClearedAt[parentKey], event.timestamp <= clearedAt else { return nil }
        let key = Self.key(source: event.source, sessionID: event.sessionID)
        removeTree(rootedAt: key, clearedAt: clearedAt, disposition: .capacityCleanup)
        trimEventHistory()
        return currentChange()
    }

    /// Removes a session subtree because the user dismissed it, not because the provider ended it.
    /// The row leaves the queue without producing a timeline entry; a cycle this session already
    /// completed stays in Today, because it was archived when the completion arrived.
    @discardableResult
    public mutating func dismiss(source: AgentSource, sessionID: String, at timestamp: Date) -> ActivityChange {
        let key = Self.key(source: source, sessionID: sessionID)
        // `clearedAt` is still recorded so a late provider event cannot resurrect a dismissed row.
        removeTree(rootedAt: key, clearedAt: timestamp, disposition: .manualDismissal)
        trimEventHistory()
        return currentChange()
    }

    @discardableResult
    public mutating func dismissAll(at timestamp: Date) -> ActivityChange {
        // Snapshot the keys: each removal takes a whole subtree, so the dictionary changes shape
        // underneath the loop. Keys an earlier iteration already removed are skipped.
        for key in Array(sessions.keys) where sessions[key] != nil {
            removeTree(rootedAt: key, clearedAt: timestamp, disposition: .manualDismissal)
        }
        trimEventHistory()
        return currentChange()
    }

    public mutating func removeSessions(olderThan cutoff: Date) {
        let staleKeys = sessions.compactMap { $0.value.updatedAt < cutoff ? $0.key : nil }
        // Built once for the whole sweep. Keys removed by an earlier iteration stay in the
        // index, but every lookup filters through `sessions`, so a stale entry is a no-op.
        let childKeys = childKeysByParent()
        for key in staleKeys where sessions[key] != nil {
            let subtree = treeKeys(rootedAt: key, childKeys: childKeys)
            if subtree.compactMap({ sessions[$0] }).allSatisfy({ $0.updatedAt < cutoff }) {
                removeTree(rootedAt: key, childKeys: childKeys, disposition: .staleCleanup)
            }
        }
        latestEventAt = latestEventAt.filter { $0.value >= cutoff }
        latestMetadataAt = latestMetadataAt.filter { $0.value >= cutoff }
        latestSessionTitleAt = latestSessionTitleAt.filter {
            $0.value >= cutoff || sessions[$0.key] != nil || pendingMetadata[$0.key] != nil
        }
        latestActivityAt = latestActivityAt.filter {
            $0.value >= cutoff || sessions[$0.key] != nil || pendingMetadata[$0.key] != nil
        }
        latestRequestAt = latestRequestAt.filter { $0.value >= cutoff }
        resolvedRequests = resolvedRequests.filter { latestRequestAt[$0] != nil }
        acknowledgedRequests = acknowledgedRequests.filter { latestRequestAt[$0] != nil }
        let activePermissionTokens = Set(sessions.values.compactMap { $0.permission?.responseToken })
        acknowledgedLegacyPermissions.formIntersection(activePermissionTokens)
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
        if let session = sessions[key], session.state == .attention, session.pendingRequests.isEmpty,
           session.updatedAt <= timestamp {
            sessions[key]?.state = .idle
            sessions[key]?.reason = nil
        }
        let current = primarySession
        return ActivityChange(
            state: current?.state ?? .idle,
            primarySession: current,
            shouldNotify: false,
            completedSessions: []
        )
    }

    /// Drops every context percentage, live and pending. Called when the user turns usage and cost
    /// tracking off: the figures must leave the UI at once rather than lingering until the sessions
    /// that produced them expire.
    @discardableResult
    public mutating func clearContextWindowUsage() -> ActivityChange {
        for key in sessions.keys {
            sessions[key]?.contextUsedPercentage = nil
        }
        for key in pendingMetadata.keys {
            pendingMetadata[key]?.contextUsedPercentage = nil
        }
        return currentChange()
    }

    /// Drops every cost figure and marks the running cycles as having no observed cost. Called when
    /// the user turns tracking off: without this, a value captured while tracking was on would keep
    /// flowing into timeline rows written after the opt-out.
    @discardableResult
    public mutating func clearCostTracking() -> ActivityChange {
        for key in sessions.keys {
            sessions[key]?.costUSD = nil
            sessions[key]?.costGeneration = nil
            sessions[key]?.cycleCostBaseline = nil
            sessions[key]?.hasCycleCost = false
        }
        for key in pendingMetadata.keys {
            pendingMetadata[key]?.costUSD = nil
        }
        return currentChange()
    }

    @discardableResult
    public mutating func acknowledgeAttention(source: AgentSource, sessionID: String) -> ActivityChange {
        let key = Self.key(source: source, sessionID: sessionID)
        guard let session = sessions[key], session.state == .attention else {
            return currentChange()
        }
        for request in session.pendingRequests {
            acknowledgedRequests.insert(Self.requestKey(source: source, sessionID: sessionID, request: request))
        }
        if session.pendingRequests.isEmpty, let permission = session.permission {
            acknowledgedLegacyPermissions.insert(permission.responseToken)
        }
        sessions[key]?.state = .idle
        if session.pendingRequests.isEmpty, session.permission == nil {
            sessions[key]?.reason = nil
            sessions[key]?.isAwaitingPermissionResolution = false
        }
        let current = primarySession
        return ActivityChange(
            state: current?.state ?? .idle,
            primarySession: current,
            shouldNotify: false,
            completedSessions: []
        )
    }

    @discardableResult
    public mutating func markPermissionSubmitted(
        source: AgentSource,
        sessionID: String,
        responseToken: String
    ) -> ActivityChange {
        let key = Self.key(source: source, sessionID: sessionID)
        guard sessions[key]?.permission?.responseToken == responseToken else { return currentChange() }
        if let index = sessions[key]?.pendingRequests.firstIndex(where: { $0.permission?.responseToken == responseToken }) {
            sessions[key]?.pendingRequests[index].permission = nil
            applyRequestOverlay(to: key)
        } else {
            sessions[key]?.permission = nil
        }
        return currentChange()
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

    private var totalPendingRequestCount: Int {
        sessions.values.reduce(0) { $0 + $1.pendingRequests.count }
    }

    private static func key(source: AgentSource, sessionID: String) -> SessionKey {
        SessionKey(source: source, sessionID: sessionID)
    }

    private static func requestKey(event: AgentEvent, request: AgentRequestUpdate) -> RequestEventKey {
        RequestEventKey(source: event.source, sessionID: event.sessionID, kind: request.kind, requestID: request.id)
    }

    private static func requestKey(
        source: AgentSource,
        sessionID: String,
        request: AgentPendingRequest
    ) -> RequestEventKey {
        RequestEventKey(source: source, sessionID: sessionID, kind: request.kind, requestID: request.id)
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
        return lhs.key < rhs.key
    }

    private func normalizedParentSessionID(
        _ parentSessionID: String?,
        for key: SessionKey,
        source: AgentSource
    ) -> String? {
        guard let parentSessionID else { return nil }
        let parentKey = Self.key(source: source, sessionID: parentSessionID)
        guard parentKey != key else { return nil }
        var current: SessionKey? = parentKey
        var visited: Set<SessionKey> = []
        while let candidate = current {
            guard candidate != key else { return nil }
            guard let session = sessions[candidate] else { break }
            guard visited.insert(candidate).inserted else { return nil }
            current = session.parentSessionID.map { Self.key(source: session.source, sessionID: $0) }
        }
        return parentSessionID
    }

    private func rootKey(for key: SessionKey) -> SessionKey {
        var current = key
        var visited: Set<SessionKey> = []
        while let session = sessions[current], let parentSessionID = session.parentSessionID {
            guard visited.insert(current).inserted else { return key }
            let parentKey = Self.key(source: session.source, sessionID: parentSessionID)
            guard sessions[parentKey] != nil else { return current }
            current = parentKey
        }
        return current
    }

    private func groupSortValue(for keys: [SessionKey]) -> (priority: Int, updatedAt: Date) {
        keys.compactMap { sessions[$0] }.reduce((priority: -1, updatedAt: .distantPast)) { result, session in
            let priority = Self.priority(session.state)
            if priority > result.priority { return (priority, session.updatedAt) }
            if priority == result.priority { return (priority, max(result.updatedAt, session.updatedAt)) }
            return result
        }
    }

    private func flattenedGroup(rootKey: SessionKey, members: Set<SessionKey>) -> [SessionActivity] {
        var result: [SessionActivity] = []
        var visited: Set<SessionKey> = []
        func append(_ key: SessionKey) {
            guard members.contains(key), visited.insert(key).inserted, let session = sessions[key] else { return }
            result.append(session)
            let children = members.filter { childKey in
                guard let child = sessions[childKey], let parentSessionID = child.parentSessionID else { return false }
                return Self.key(source: child.source, sessionID: parentSessionID) == key
            }.compactMap { sessions[$0] }.sorted(by: Self.activityComesFirst)
            for child in children { append(child.key) }
        }
        append(rootKey)
        for leftover in members.compactMap({ sessions[$0] }).sorted(by: Self.activityComesFirst) {
            append(leftover.key)
        }
        return result
    }

    /// Returns the cycles this removal ended, which is non-empty only for a provider-terminal
    /// removal of sessions that had not already been archived.
    @discardableResult
    private mutating func removeTree(
        rootedAt rootKey: SessionKey,
        clearedAt: Date? = nil,
        childKeys: [SessionKey: [SessionKey]]? = nil,
        disposition: SessionRemovalDisposition,
        endedAt: Date? = nil
    ) -> [CompletedSession] {
        let keysToRemove = treeKeys(rootedAt: rootKey, childKeys: childKeys)
        var completed: [CompletedSession] = []
        if disposition == .providerTerminal, let endedAt {
            // Captured before anything is deleted. A snapshot's group is resolved by walking parent
            // links through `sessions`, so a removed subagent must still see its hierarchy intact.
            completed = keysToRemove
                .compactMap { sessions[$0] }
                .filter { !$0.isCycleArchived }
                .sorted { $0.key < $1.key }
                .map { snapshot(of: $0, endedAt: endedAt) }
        }
        for key in keysToRemove {
            if let session = sessions.removeValue(forKey: key) {
                for request in session.pendingRequests {
                    acknowledgedRequests.remove(Self.requestKey(
                        source: session.source,
                        sessionID: session.sessionID,
                        request: request
                    ))
                }
                if let token = session.permission?.responseToken {
                    acknowledgedLegacyPermissions.remove(token)
                }
            }
            if let clearedAt {
                latestEventAt[key] = max(latestEventAt[key] ?? .distantPast, clearedAt)
                latestClearedAt[key] = max(latestClearedAt[key] ?? .distantPast, clearedAt)
            } else {
                latestEventAt.removeValue(forKey: key)
                latestClearedAt.removeValue(forKey: key)
            }
            latestMetadataAt.removeValue(forKey: key)
            latestSessionTitleAt.removeValue(forKey: key)
            latestActivityAt.removeValue(forKey: key)
            pendingMetadata.removeValue(forKey: key)
        }
        return completed
    }

    /// Builds the persisted row for one cycle. A session that reached a terminal state without ever
    /// showing working activity adopts the end instant as its start, producing a zero-duration row
    /// rather than a missing one.
    private func snapshot(of session: SessionActivity, endedAt: Date) -> CompletedSession {
        let startedAt = session.cycleStartedAt ?? endedAt
        return CompletedSession(
            cycleID: CompletedSession.cycleID(
                source: session.source,
                sessionID: session.sessionID,
                startedAt: startedAt
            ),
            source: session.source,
            sessionID: session.sessionID,
            parentSessionID: session.parentSessionID,
            groupID: rootKey(for: session.key).sessionID,
            title: session.sessionTitle,
            startedAt: startedAt,
            endedAt: endedAt,
            costUSD: session.cycleCostUSD
        )
    }

    private mutating func applyRequestOverlay(to key: SessionKey) {
        guard var session = sessions[key] else { return }
        if let request = session.pendingRequests.first {
            let presentedRequest = session.pendingRequests.first(where: { $0.permission != nil }) ?? request
            let hasUnacknowledgedRequests = session.pendingRequests.contains {
                !acknowledgedRequests.contains(Self.requestKey(
                    source: session.source,
                    sessionID: session.sessionID,
                    request: $0
                ))
            }
            session.state = hasUnacknowledgedRequests ? .attention : .idle
            session.reason = presentedRequest.reason
            session.permission = presentedRequest.permission
            session.isAwaitingPermissionResolution = true
        } else {
            if session.providerState == .attention {
                session.providerState = .working
                session.providerReason = nil
            }
            session.state = session.providerState
            session.reason = session.providerReason
            session.permission = nil
            session.isAwaitingPermissionResolution = false
        }
        sessions[key] = session
    }

    private func childKeysByParent() -> [SessionKey: [SessionKey]] {
        var index: [SessionKey: [SessionKey]] = [:]
        for (key, session) in sessions {
            guard let parentSessionID = session.parentSessionID else { continue }
            index[Self.key(source: session.source, sessionID: parentSessionID), default: []].append(key)
        }
        for (key, metadata) in pendingMetadata {
            guard let parentSessionID = metadata.parentSessionID else { continue }
            index[Self.key(source: metadata.source, sessionID: parentSessionID), default: []].append(key)
        }
        return index
    }

    private func treeKeys(
        rootedAt rootKey: SessionKey,
        childKeys: [SessionKey: [SessionKey]]? = nil
    ) -> Set<SessionKey> {
        let index = childKeys ?? childKeysByParent()
        var keys: Set<SessionKey> = [rootKey]
        var pending = [rootKey]
        while let key = pending.popLast() {
            for child in index[key] ?? [] where keys.insert(child).inserted {
                pending.append(child)
            }
        }
        return keys
    }

    private func currentChange() -> ActivityChange {
        let current = primarySession
        return ActivityChange(
            state: current?.state ?? .idle,
            primarySession: current,
            shouldNotify: false,
            completedSessions: []
        )
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
        while latestRequestAt.count > Self.maximumSessions * 4 {
            let active = Set(sessions.values.flatMap { session in
                session.pendingRequests.map {
                    RequestEventKey(source: session.source, sessionID: session.sessionID, kind: $0.kind, requestID: $0.id)
                }
            })
            guard let oldest = latestRequestAt.filter({ !active.contains($0.key) })
                .min(by: { $0.value < $1.value })?.key else { return }
            latestRequestAt.removeValue(forKey: oldest)
            resolvedRequests.remove(oldest)
        }
    }
}

private struct PendingMetadata: Sendable {
    let source: AgentSource
    let sessionTitle: String?
    let activityDescription: String?
    let parentSessionID: String?
    var costUSD: Double?
    let costGeneration: String?
    var contextUsedPercentage: Double?
    let updatedAt: Date
}

private struct RequestEventKey: Hashable, Sendable {
    let source: AgentSource
    let sessionID: String
    let kind: AgentRequestKind
    let requestID: String
}
