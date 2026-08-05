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

/// How today's estimated spend compares to the configured alert threshold.
public enum DailyCostAlertLevel: String, Sendable, Equatable {
    case normal
    case warning
    case exceeded
}

/// The user-configured daily spend threshold and its once-per-day fired flag. The flag lives beside
/// the daily total so both reset on the same day boundary.
public struct DailyCostAlert: Sendable, Equatable {
    public static let maximumThreshold: Double = 100_000
    public static let warningFraction: Double = 0.8

    /// The configured threshold in USD. Zero means the alert is disabled.
    public private(set) var threshold: Double
    public private(set) var hasFired: Bool

    public init(threshold: Double = 0, hasFired: Bool = false) {
        self.threshold = Self.sanitize(threshold)
        self.hasFired = hasFired
    }

    public var isEnabled: Bool { threshold > 0 }

    public static func sanitize(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return (min(value, maximumThreshold) * 100).rounded() / 100
    }

    /// Parses a plain user-entered currency amount. Empty, unparseable, or non-positive input
    /// disables the alert.
    public static func parseThreshold(_ text: String, locale: Locale = .current) -> Double {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let symbol = locale.currencySymbol, cleaned.hasPrefix(symbol) {
            cleaned.removeFirst(symbol.count)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !cleaned.isEmpty,
              !cleaned.contains("-"),
              cleaned.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," || $0.isWhitespace }) else {
            return 0
        }
        cleaned.removeAll(where: \Character.isWhitespace)
        let decimalSeparator = locale.decimalSeparator ?? "."
        let groupingSeparator = locale.groupingSeparator ?? ","
        let decimalParts = cleaned.components(separatedBy: decimalSeparator)
        guard decimalParts.count <= 2 else { return 0 }
        let integerPart = decimalParts[0]
        let groups = integerPart.components(separatedBy: groupingSeparator)
        if groups.count > 1 {
            guard (1...3).contains(groups[0].count),
                  groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return 0 }
        }
        guard groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\Character.isNumber) }) else { return 0 }
        let fraction = decimalParts.count == 2 ? decimalParts[1] : ""
        guard fraction.allSatisfy(\Character.isNumber) else { return 0 }
        let canonical = groups.joined() + (decimalParts.count == 2 ? ".\(fraction)" : "")
        return sanitize(Double(canonical) ?? 0)
    }

    /// Returns `true` exactly once per day, on the update that takes the total across the threshold.
    @discardableResult
    public mutating func evaluate(previousTotal: Double, total: Double) -> Bool {
        guard threshold > 0,
              !hasFired,
              previousTotal.isFinite,
              total.isFinite,
              previousTotal < threshold,
              total >= threshold else { return false }
        hasFired = true
        return true
    }

    /// Threshold edits never rearm an alert that already fired during the current day.
    public mutating func setThreshold(_ value: Double) {
        threshold = Self.sanitize(value)
    }

    public mutating func beginNewDay() {
        hasFired = false
    }

    public func level(total: Double) -> DailyCostAlertLevel {
        guard threshold > 0, total.isFinite, total > 0 else { return .normal }
        if hasFired, total >= threshold { return .exceeded }
        if total >= threshold * Self.warningFraction { return .warning }
        return .normal
    }
}

public enum DailyCostPreference {
    public static let trackingEnabledKey = "costTrackingEnabled"
    public static let dayKey = "dailyCostDay"
    public static let totalKey = "dailyCostTotal"
    public static let sessionsKey = "dailyCostSessions"
    public static let alertThresholdKey = "dailyCostAlertThreshold"
    public static let alertFiredKey = "dailyCostAlertFired"

    public static func load(
        from defaults: UserDefaults,
        now: Date,
        calendar: Calendar
    ) -> (totalCost: Double, sessionCosts: [String: Double], alertFired: Bool) {
        let sessions: [String: Double]
        if let data = defaults.data(forKey: sessionsKey),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            sessions = boundedSessionCosts(decoded)
        } else {
            sessions = [:]
        }
        guard defaults.string(forKey: dayKey)
            == DailyCoolnessPreference.dayIdentifier(for: now, calendar: calendar) else {
            return (0, sessions, false)
        }
        let total = defaults.double(forKey: totalKey)
        guard total.isFinite, total >= 0 else { return (0, sessions, false) }
        return (total, sessions, defaults.bool(forKey: alertFiredKey))
    }

    public static func save(
        totalCost: Double,
        sessionCosts: [String: Double],
        alertFired: Bool,
        to defaults: UserDefaults,
        now: Date,
        calendar: Calendar
    ) {
        defaults.set(DailyCoolnessPreference.dayIdentifier(for: now, calendar: calendar), forKey: dayKey)
        defaults.set(totalCost.isFinite ? max(0, totalCost) : 0, forKey: totalKey)
        defaults.set(alertFired, forKey: alertFiredKey)
        let boundedSessions = boundedSessionCosts(sessionCosts)
        if let data = try? JSONEncoder().encode(boundedSessions) {
            defaults.set(data, forKey: sessionsKey)
        }
    }

    /// The threshold is deliberately not day-scoped: it survives midnight rollover and a cost
    /// tracking disable/re-enable round trip.
    public static func loadThreshold(from defaults: UserDefaults) -> Double {
        DailyCostAlert.sanitize(defaults.double(forKey: alertThresholdKey))
    }

    public static func saveThreshold(_ threshold: Double, to defaults: UserDefaults) {
        defaults.set(DailyCostAlert.sanitize(threshold), forKey: alertThresholdKey)
    }

    public static func clear(from defaults: UserDefaults) {
        defaults.removeObject(forKey: dayKey)
        defaults.removeObject(forKey: totalKey)
        defaults.removeObject(forKey: sessionsKey)
        defaults.removeObject(forKey: alertFiredKey)
        defaults.removeObject(forKey: alertThresholdKey)
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
