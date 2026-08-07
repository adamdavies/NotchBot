import Foundation

/// One session cycle that reached a terminal state today.
///
/// This is the only NotchBot record that outlives the process, so its field set is the retained-data
/// story: identity, grouping, a bounded presentation title, the two timestamps, and an optional cost.
/// Working directories, activity descriptions, permission data, reasons, terminal details, context
/// usage, prompts, transcripts, tokens, and models are deliberately absent and must stay absent.
public struct CompletedSession: Codable, Equatable, Identifiable, Sendable {
    /// Stable across writes and restarts, so the same cycle upserts instead of duplicating. Derived
    /// from the session key and the cycle's start instant, both of which are fixed once a cycle runs.
    public let cycleID: String
    public let source: AgentSource
    public let sessionID: String
    public let parentSessionID: String?
    /// The root session ID of the parent/subagent group, so a fan-out reads as one block. Equal to
    /// `sessionID` for a top-level session.
    public let groupID: String
    /// Bounded presentation text, normalized exactly as the live queue's title is.
    public let title: String?
    public let startedAt: Date
    public let endedAt: Date
    /// `nil` means no cost was observed for this cycle — cost tracking was off, or the provider never
    /// reported one. Zero is reserved for a cycle that was tracked and genuinely cost nothing, so the
    /// two cases stay distinguishable in the UI.
    public let costUSD: Double?

    public var id: String { cycleID }

    public init(
        cycleID: String,
        source: AgentSource,
        sessionID: String,
        parentSessionID: String? = nil,
        groupID: String,
        title: String? = nil,
        startedAt: Date,
        endedAt: Date,
        costUSD: Double? = nil
    ) {
        self.cycleID = cycleID
        self.source = source
        self.sessionID = sessionID
        self.parentSessionID = parentSessionID
        self.groupID = groupID
        self.title = AgentPresentationText.normalized(title)
        self.startedAt = startedAt
        // A completion that arrives without any observed working activity uses its own timestamp as
        // the start, which is a zero-duration cycle rather than a negative one.
        self.endedAt = max(startedAt, endedAt)
        self.costUSD = Self.sanitizedCost(costUSD)
    }

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    public var isSubagent: Bool { parentSessionID != nil }

    /// The cycle identity persisted rows are deduplicated by. Millisecond resolution keeps the
    /// textual form stable through an encode/decode round trip.
    public static func cycleID(source: AgentSource, sessionID: String, startedAt: Date) -> String {
        let milliseconds = Int64((startedAt.timeIntervalSince1970 * 1_000).rounded())
        return "\(source.rawValue):\(sessionID):\(milliseconds)"
    }

    static func sanitizedCost(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

/// A single day of completed sessions. Versioned because it is read back from disk: an unrecognized
/// version is discarded rather than guessed at.
public struct SessionTimelineDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    /// Hard cap on rows, whatever their encoded size.
    public static let maximumEntries = 400
    /// Hard cap on the encoded document, so a day of long titles cannot grow the file without limit.
    /// Deliberately tight enough to bind before the entry cap when titles run long — a day of 400
    /// maximum-length titles encodes to roughly twice this — so neither bound is decorative.
    public static let maximumEncodedBytes = 64 * 1_024

    public let version: Int
    /// `DailyCoolnessPreference.dayIdentifier`, so rollover matches the daily total's rollover.
    public let day: String
    public private(set) var sessions: [CompletedSession]

    public init(day: String, sessions: [CompletedSession] = []) {
        version = Self.currentVersion
        self.day = day
        self.sessions = []
        for session in sessions { upsert(session) }
        trimToBounds()
    }

    /// Adds a cycle, or replaces the stored copy when the same cycle is reported again. Returns
    /// `false` when nothing changed, so a caller can skip a pointless write.
    @discardableResult
    public mutating func upsert(_ session: CompletedSession) -> Bool {
        if let index = sessions.firstIndex(where: { $0.cycleID == session.cycleID }) {
            guard sessions[index] != session else { return false }
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sortRows()
        trimToBounds()
        return true
    }

    /// Drops every cost while keeping the rows, for the cost-tracking opt-out. Returns `false` when
    /// no row carried one.
    @discardableResult
    public mutating func removeCosts() -> Bool {
        guard sessions.contains(where: { $0.costUSD != nil }) else { return false }
        sessions = sessions.map {
            CompletedSession(
                cycleID: $0.cycleID,
                source: $0.source,
                sessionID: $0.sessionID,
                parentSessionID: $0.parentSessionID,
                groupID: $0.groupID,
                title: $0.title,
                startedAt: $0.startedAt,
                endedAt: $0.endedAt,
                costUSD: nil
            )
        }
        return true
    }

    /// Groups in reverse chronological order by the group's most recent end, each group's parent
    /// first and its subagents in ascending end order beneath it. This is the display order.
    public var orderedGroups: [SessionTimelineGroup] {
        let grouped = Dictionary(grouping: sessions, by: \.groupID)
        return grouped.keys.sorted { lhs, rhs in
            let left = grouped[lhs] ?? []
            let right = grouped[rhs] ?? []
            let leftEnd = left.map(\.endedAt).max() ?? .distantPast
            let rightEnd = right.map(\.endedAt).max() ?? .distantPast
            if leftEnd != rightEnd { return leftEnd > rightEnd }
            return lhs < rhs
        }.compactMap { groupID in
            let members = grouped[groupID] ?? []
            // A group whose parent row was trimmed is presented under its earliest surviving member
            // rather than dropped, so a subagent never disappears silently.
            let parent = members.first { $0.sessionID == groupID }
                ?? members.min { rowComesFirst($0, $1) }
            guard let parent else { return nil }
            let subagents = members
                .filter { $0.cycleID != parent.cycleID }
                .sorted { rowComesFirst($0, $1) }
            return SessionTimelineGroup(parent: parent, subagents: subagents)
        }
    }

    /// Total observed spend across the day. Rows without cost contribute nothing rather than zero.
    public var totalCostUSD: Double {
        sessions.compactMap(\.costUSD).reduce(0, +)
    }

    public var hasObservedCost: Bool {
        sessions.contains { $0.costUSD != nil }
    }

    private mutating func sortRows() {
        sessions.sort { rowComesFirst($0, $1) }
    }

    /// Trims to both bounds, discarding whole groups from the oldest end first so a surviving
    /// subagent is never left without the parent it belongs under.
    private mutating func trimToBounds() {
        while sessions.count > Self.maximumEntries || encodedByteCount() > Self.maximumEncodedBytes {
            guard removeOldestGroup() else { return }
        }
    }

    private mutating func removeOldestGroup() -> Bool {
        let grouped = Dictionary(grouping: sessions, by: \.groupID)
        guard let oldest = grouped.min(by: { lhs, rhs in
            let left = lhs.value.map(\.endedAt).max() ?? .distantPast
            let right = rhs.value.map(\.endedAt).max() ?? .distantPast
            if left != right { return left < right }
            return lhs.key < rhs.key
        })?.key else { return false }
        let remaining = sessions.filter { $0.groupID != oldest }
        // Guards against a bound so tight that even one group cannot fit: dropping the last group
        // would leave an empty timeline while the caller still loops.
        guard !remaining.isEmpty else { return false }
        sessions = remaining
        return true
    }

    private func encodedByteCount() -> Int {
        (try? encoded())?.count ?? 0
    }

    public func encoded() throws -> Data {
        try Self.encoder().encode(self)
    }

    /// Millisecond epoch dates, so an encode/decode round trip is exact at exactly the resolution
    /// `CompletedSession.cycleID` is derived from. A textual strategy that dropped fractional seconds
    /// would leave a reloaded row's timestamps disagreeing with the cycle ID stored beside them.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

/// A parent cycle and the subagent cycles that ran under it.
public struct SessionTimelineGroup: Equatable, Identifiable, Sendable {
    public let parent: CompletedSession
    public let subagents: [CompletedSession]

    public var id: String { parent.cycleID }

    public init(parent: CompletedSession, subagents: [CompletedSession] = []) {
        self.parent = parent
        self.subagents = subagents
    }

    /// Rows contributed to the "N completed" count: the parent plus each subagent.
    public var rowCount: Int { 1 + subagents.count }
}

/// Ascending by end, then start, then cycle ID, so ordering is total and stable across writes.
private func rowComesFirst(_ lhs: CompletedSession, _ rhs: CompletedSession) -> Bool {
    if lhs.endedAt != rhs.endedAt { return lhs.endedAt < rhs.endedAt }
    if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
    return lhs.cycleID < rhs.cycleID
}
