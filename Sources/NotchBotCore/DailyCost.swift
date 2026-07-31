import Foundation

public struct DailyCostTracker: Sendable {
    public static let maximumTrackedSessions = 10_000

    public private(set) var totalCost: Double
    public private(set) var sessionCosts: [String: Double]
    private var seenSessionKeys: Set<String>

    public init(totalCost: Double = 0, sessionCosts: [String: Double] = [:]) {
        self.totalCost = totalCost.isFinite ? max(0, totalCost) : 0
        self.sessionCosts = boundedSessionCosts(sessionCosts)
        seenSessionKeys = Set(self.sessionCosts.keys)
    }

    @discardableResult
    public mutating func apply(_ event: AgentEvent) -> Bool {
        guard let cost = event.costUSD, cost >= 0, cost.isFinite else { return false }
        let key = [event.source.rawValue, event.sessionID, event.costGeneration]
            .compactMap { $0 }
            .joined(separator: ":")
        if sessionCosts[key] != nil || seenSessionKeys.count < Self.maximumTrackedSessions {
            seenSessionKeys.insert(key)
        }
        let previous = sessionCosts[key] ?? 0
        guard cost > previous else { return false }
        if sessionCosts[key] == nil, sessionCosts.count >= Self.maximumTrackedSessions {
            return false
        }
        let updatedTotal = totalCost + cost - previous
        guard updatedTotal.isFinite, updatedTotal >= 0 else { return false }
        sessionCosts[key] = cost
        totalCost = updatedTotal
        return true
    }

    public mutating func beginNewDay() {
        totalCost = 0
        sessionCosts = sessionCosts.filter { seenSessionKeys.contains($0.key) }
        seenSessionKeys.removeAll(keepingCapacity: true)
    }

    public mutating func reset() {
        totalCost = 0
        sessionCosts.removeAll(keepingCapacity: true)
        seenSessionKeys.removeAll(keepingCapacity: true)
    }
}

public enum DailyCostPreference {
    public static let dayKey = "dailyCostDay"
    public static let totalKey = "dailyCostTotal"
    public static let sessionsKey = "dailyCostSessions"

    public static func load(
        from defaults: UserDefaults,
        now: Date,
        calendar: Calendar
    ) -> (totalCost: Double, sessionCosts: [String: Double]) {
        let sessions: [String: Double]
        if let data = defaults.data(forKey: sessionsKey),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            sessions = boundedSessionCosts(decoded)
        } else {
            sessions = [:]
        }
        guard defaults.string(forKey: dayKey)
            == DailyCoolnessPreference.dayIdentifier(for: now, calendar: calendar) else {
            return (0, sessions)
        }
        let total = defaults.double(forKey: totalKey)
        guard total.isFinite, total >= 0 else { return (0, sessions) }
        return (total, sessions)
    }

    public static func save(
        totalCost: Double,
        sessionCosts: [String: Double],
        to defaults: UserDefaults,
        now: Date,
        calendar: Calendar
    ) {
        defaults.set(DailyCoolnessPreference.dayIdentifier(for: now, calendar: calendar), forKey: dayKey)
        defaults.set(totalCost.isFinite ? max(0, totalCost) : 0, forKey: totalKey)
        let boundedSessions = boundedSessionCosts(sessionCosts)
        if let data = try? JSONEncoder().encode(boundedSessions) {
            defaults.set(data, forKey: sessionsKey)
        }
    }

    public static func clear(from defaults: UserDefaults) {
        defaults.removeObject(forKey: dayKey)
        defaults.removeObject(forKey: totalKey)
        defaults.removeObject(forKey: sessionsKey)
    }
}

private func boundedSessionCosts(_ costs: [String: Double]) -> [String: Double] {
    var result: [String: Double] = [:]
    for (key, value) in costs where value.isFinite && value >= 0 {
        guard result.count < DailyCostTracker.maximumTrackedSessions else { break }
        result[key] = value
    }
    return result
}
