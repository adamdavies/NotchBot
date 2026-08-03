import Foundation

public enum CoolnessTier: Int, CaseIterable, Comparable, Identifiable, Sendable {
    case base
    case glow
    case shades
    case crown

    public var id: Int { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(completionCount: Int) {
        self = switch completionCount {
        case 100...: .crown
        case 50...: .shades
        case 25...: .glow
        default: .base
        }
    }

    public var displayName: String {
        switch self {
        case .base: "Base"
        case .glow: "Glow"
        case .shades: "Shades"
        case .crown: "Crown"
        }
    }

    public var threshold: Int {
        switch self {
        case .base: 0
        case .glow: 25
        case .shades: 50
        case .crown: 100
        }
    }
}

public struct DailyCoolnessTracker: Sendable {
    public static let maximumTrackedSessions = 10_000

    public private(set) var completionCount: Int
    private var completedCycles: Set<String> = []

    public init(completionCount: Int = 0) {
        self.completionCount = max(0, completionCount)
    }

    @discardableResult
    public mutating func apply(_ event: AgentEvent, isTopLevel: Bool) -> Bool {
        guard isTopLevel else { return false }
        // `completedCycles` is persisted, so keep the textual form rather than the struct.
        let key = SessionKey(event: event).rawValue

        if event.kind == .working {
            completedCycles.remove(key)
            return false
        }
        guard event.isCompletionAttention, !completedCycles.contains(key) else { return false }

        if !completedCycles.contains(key), completedCycles.count >= Self.maximumTrackedSessions {
            return false
        }
        completedCycles.insert(key)
        if completionCount < Int.max {
            completionCount += 1
        }
        return true
    }

    public mutating func reset() {
        completionCount = 0
        completedCycles.removeAll(keepingCapacity: true)
    }
}

public enum DailyCoolnessPreference {
    public static let dayKey = "dailyCoolnessDay"
    public static let countKey = "dailyCoolnessCount"

    public static func load(
        from defaults: UserDefaults,
        now: Date,
        calendar: Calendar
    ) -> Int {
        guard
            let day = defaults.string(forKey: dayKey),
            day == dayIdentifier(for: now, calendar: calendar)
        else {
            return 0
        }
        let count = defaults.integer(forKey: countKey)
        return count >= 0 ? count : 0
    }

    public static func save(
        completionCount: Int,
        to defaults: UserDefaults,
        now: Date,
        calendar: Calendar
    ) {
        defaults.set(dayIdentifier(for: now, calendar: calendar), forKey: dayKey)
        defaults.set(max(0, completionCount), forKey: countKey)
    }

    public static func dayIdentifier(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.era, .year, .month, .day], from: date)
        return [components.era, components.year, components.month, components.day]
            .map { String($0 ?? 0) }
            .joined(separator: "-")
    }
}
