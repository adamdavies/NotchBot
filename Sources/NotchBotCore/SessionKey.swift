import Foundation

/// Identity for one provider session. Sessions are only unique per source, so both fields are
/// required to address one — building the composite by hand let a typo create an orphan entry.
public struct SessionKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let source: AgentSource
    public let sessionID: String

    public init(source: AgentSource, sessionID: String) {
        self.source = source
        self.sessionID = sessionID
    }

    public init(event: AgentEvent) {
        self.init(source: event.source, sessionID: event.sessionID)
    }

    /// Stable textual form. Persisted by `DailyCoolness`, so the separator must not change.
    public var rawValue: String { "\(source.rawValue):\(sessionID)" }

    public var description: String { rawValue }

    public static func < (lhs: SessionKey, rhs: SessionKey) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
