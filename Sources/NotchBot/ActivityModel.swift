import AppKit
import Combine
import Foundation
import NotchBotCore
import UserNotifications

extension Notification.Name {
    static let notchBotCostTrackingEnabled = Notification.Name("NotchBotCostTrackingEnabled")
    static let notchBotCostTrackingDisabled = Notification.Name("NotchBotCostTrackingDisabled")
    /// Posted after the installer's removal transaction succeeds, so the in-memory timeline is
    /// dropped without writing a fresh file that would undo the removal.
    static let notchBotIntegrationsRemoved = Notification.Name("NotchBotIntegrationsRemoved")
}

struct ActivityModelNotificationDependencies {
    var send: @MainActor (_ identifier: String, _ title: String, _ body: String) -> Void
    var resolve: @MainActor (_ identifier: String) -> Void

    static let live = Self(
        send: { identifier, title, body in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            ))
        },
        resolve: { identifier in
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        }
    )
}

@MainActor
final class ActivityModel: ObservableObject {
    @Published private(set) var robotState: RobotState = .idle
    @Published private(set) var primarySession: SessionActivity?
    @Published private(set) var attentionSequence = 0
    @Published private(set) var activeAgentCount = 0
    @Published private(set) var waitingAgentCount = 0
    @Published private(set) var previewState: RobotState?
    @Published private(set) var previewCoolnessTier: CoolnessTier?
    @Published private(set) var dailyCompletionCount: Int
    @Published private(set) var dailyCostTotal: Double
    @Published private(set) var dailyCostAlertThreshold: Double
    @Published private(set) var activeSessions: [SessionActivity] = []
    @Published private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    /// Today's completed cycles, newest group first. Drives the Today view.
    @Published private(set) var completedSessionsToday: [SessionTimelineGroup] = []
    /// Set when the timeline could not be written. Persistence failure is deliberately non-fatal:
    /// the live queue and the in-memory rows keep working, and only surviving a restart is lost.
    @Published private(set) var timelineStorageError: String?

    private var reducer = ActivityReducer()
    private let timelineStore: SessionTimelineStoring
    private var timeline: SessionTimelineDocument
    private var coolnessTracker: DailyCoolnessTracker
    private var costTracker: DailyCostTracker
    private var costAlert: DailyCostAlert
    private var costTrackingEnabled: Bool
    private var expiryTasks: [SessionKey: Task<Void, Never>] = [:]
    private var maintenanceTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private let calendar: Calendar
    private let nowProvider: @MainActor () -> Date
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let notifications: ActivityModelNotificationDependencies
    private var coolnessDay: String
    private var dailyResetTask: Task<Void, Never>?
    private var calendarObservers: [NSObjectProtocol] = []
    private var wakeObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        calendar: Calendar = .autoupdatingCurrent,
        now: Date? = nil,
        nowProvider: @escaping @MainActor () -> Date = Date.init,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        notifications: ActivityModelNotificationDependencies = .live,
        // `nil` means the live store; it cannot be a default argument because that expression would
        // be evaluated outside this main-actor initializer.
        timelineStore: (any SessionTimelineStoring)? = nil,
        enableBackgroundMaintenance: Bool = true
    ) {
        let initialNow = now ?? nowProvider()
        self.defaults = defaults
        self.calendar = calendar
        self.nowProvider = nowProvider
        self.sleep = sleep
        self.notifications = notifications
        let timelineStore = timelineStore ?? SessionTimelineStore.live
        self.timelineStore = timelineStore
        let initialDay = DailyCoolnessPreference.dayIdentifier(for: initialNow, calendar: calendar)
        // Only a document for the current day is adopted; the store discards anything older, so
        // yesterday's rows never reappear after an overnight restart.
        var loadFailure: String?
        do {
            timeline = try timelineStore.load(day: initialDay) ?? SessionTimelineDocument(day: initialDay)
        } catch {
            timeline = SessionTimelineDocument(day: initialDay)
            loadFailure = error.localizedDescription
        }
        coolnessDay = initialDay
        let savedCount = DailyCoolnessPreference.load(from: defaults, now: initialNow, calendar: calendar)
        dailyCompletionCount = savedCount
        coolnessTracker = DailyCoolnessTracker(completionCount: savedCount)
        let savedCost = DailyCostPreference.load(from: defaults, now: initialNow, calendar: calendar)
        dailyCostTotal = savedCost.totalCost
        costTracker = DailyCostTracker(totalCost: savedCost.totalCost, sessionCosts: savedCost.sessionCosts)
        let savedThreshold = DailyCostPreference.loadThreshold(from: defaults)
        costAlert = DailyCostAlert(threshold: savedThreshold, hasFired: savedCost.alertFired)
        dailyCostAlertThreshold = savedThreshold
        costTrackingEnabled = defaults.bool(forKey: DailyCostPreference.trackingEnabledKey)
        completedSessionsToday = timeline.orderedGroups
        timelineStorageError = loadFailure
        // A snapshot of the baselines as they stood at launch, deliberately captured by value: a
        // session already running when NotchBot started must have its first observed cycle measured
        // from what it had already spent, not from zero.
        let baselinesAtLaunch = costTracker
        reducer.launchCostBaseline = { key in
            baselinesAtLaunch.cumulativeCost(source: key.source, sessionID: key.sessionID)
        }
        if enableBackgroundMaintenance {
            maintenanceTask = Task { [weak self, sleep] in
                while !Task.isCancelled {
                    try? await sleep(60_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.performMaintenance()
                }
            }
            scheduleDailyReset(now: initialNow)
            installDailyResetObservers()
        }
        installCostTrackingObserver()
        installIntegrationRemovalObserver()
    }

    var displayedRobotState: RobotState {
        previewState ?? robotState
    }

    var coolnessTier: CoolnessTier {
        CoolnessTier(completionCount: dailyCompletionCount)
    }

    var displayedCoolnessTier: CoolnessTier {
        previewCoolnessTier ?? coolnessTier
    }

    var displayedAgentCount: Int {
        guard let previewState else { return activeAgentCount }
        return previewState == .idle ? 0 : 1
    }

    var displayedWaitingAgentCount: Int {
        guard let previewState else { return waitingAgentCount }
        return previewState == .attention ? 1 : 0
    }

    var isPreviewing: Bool {
        previewState != nil || previewCoolnessTier != nil
    }

    var coolnessStatusText: String {
        let tier = coolnessTier
        guard let nextTier = CoolnessTier.allCases.first(where: { $0.threshold > dailyCompletionCount }) else {
            return "\(dailyCompletionCount) completed runs · \(tier.displayName)"
        }
        return "\(dailyCompletionCount) completed runs · \(tier.displayName) · \(nextTier.threshold - dailyCompletionCount) to \(nextTier.displayName)"
    }

    var queueCoolnessProgress: Double {
        guard let nextTier = CoolnessTier.allCases.first(where: { $0.threshold > dailyCompletionCount }) else {
            return 1
        }
        let completedInTier = dailyCompletionCount - coolnessTier.threshold
        let runsInTier = nextTier.threshold - coolnessTier.threshold
        return Double(completedInTier) / Double(runsInTier)
    }

    var queueCoolnessProgressText: String {
        guard CoolnessTier.allCases.contains(where: { $0.threshold > dailyCompletionCount }) else {
            return "Max level"
        }
        return "\(Int((queueCoolnessProgress * 100).rounded()))%"
    }

    var dailyCostDisplayText: String {
        String(format: "~$%.2f today", dailyCostTotal)
    }

    var dailyCostAlertLevel: DailyCostAlertLevel {
        costAlert.level(total: dailyCostTotal)
    }

    var dailyCostThresholdDisplayText: String? {
        guard costAlert.isEnabled else { return nil }
        return String(format: "Alert at $%.2f", costAlert.threshold)
    }

    /// Whether Today has anything to show. Kept separate from spend so the entry point survives the
    /// state a user who never enabled cost tracking is always in: completed runs, no tracked spend.
    var hasTodayHistory: Bool { !completedSessionsToday.isEmpty }

    /// Parents plus subagents — what the header counts as "completed".
    var todayCompletedRowCount: Int {
        completedSessionsToday.reduce(0) { $0 + $1.rowCount }
    }

    /// The footer pill's label, and the way into Today. Falls back to the run count when nothing was
    /// tracked, because "~$0.00 today" would claim a day of free work rather than an untracked one.
    var todayPillText: String {
        guard dailyCostTotal > 0 else {
            return todayCompletedRowCount == 1 ? "1 run today" : "\(todayCompletedRowCount) runs today"
        }
        return dailyCostDisplayText
    }

    var dailyCostMenuText: String {
        let total = String(format: "Today: ~$%.2f", dailyCostTotal)
        return "\(total) · \(dailyCostThresholdDisplayText ?? "No cost alert set")"
    }

    /// `value` is a plain USD amount; zero or negative disables the alert.
    func setDailyCostThreshold(_ value: Double) {
        costAlert.setThreshold(value)
        dailyCostAlertThreshold = costAlert.threshold
        DailyCostPreference.saveThreshold(costAlert.threshold, to: defaults)
        saveDailyCost(now: nowProvider())
    }

    func receive(_ event: AgentEvent) {
        let now = nowProvider()
        refreshDailyCoolness(now: now)
        guard (try? AgentEventValidator.validate(event, now: now)) != nil else { return }
        // Provider sessions already running when tracking is disabled may retain the old
        // integration until restart. Drop their late usage metadata before it can restore a meter.
        guard costTrackingEnabled || event.contextWindow == nil else { return }
        if event.kind == .requestResolved, let identifier = notificationIdentifier(for: event) {
            notifications.resolve(identifier)
        }
        if let rejection = reducer.rejectDescendantOfClearedSession(event) {
            publish(rejection)
            return
        }
        guard reducer.canApply(event) else { return }
        let sessionKey = key(for: event)
        if event.kind != .metadata {
            expiryTasks.removeValue(forKey: sessionKey)?.cancel()
        }
        let change = reducer.apply(event)
        publish(change)
        let isTopLevel = reducer.activity(source: event.source, sessionID: event.sessionID)
            .map { !$0.isSubagent } ?? (event.parentSessionID == nil)
        if coolnessTracker.apply(event, isTopLevel: isTopLevel) {
            dailyCompletionCount = coolnessTracker.completionCount
            DailyCoolnessPreference.save(
                completionCount: dailyCompletionCount,
                to: defaults,
                now: now,
                calendar: calendar
            )
        }
        let previousCostTotal = costTracker.totalCost
        if costTrackingEnabled, costTracker.apply(event) {
            dailyCostTotal = costTracker.totalCost
            let crossedThreshold = costAlert.evaluate(
                previousTotal: previousCostTotal,
                total: costTracker.totalCost
            )
            saveDailyCost(now: now)
            if crossedThreshold { sendCostAlertNotification() }
        }

        if change.shouldNotify {
            attentionSequence += 1
            sendNotification(for: event)
        }
        if event.kind == .attention, event.expiresAfter != nil, !event.isCompletionAttention {
            expireAttention(event)
        }
    }

    func setPreviewState(_ state: RobotState?) {
        previewState = state
    }

    func setPreviewCoolnessTier(_ tier: CoolnessTier?) {
        previewCoolnessTier = tier
    }

    func cancelPreview() {
        previewState = nil
        previewCoolnessTier = nil
    }

    func focusPrimaryTerminal() {
        guard let primarySession else {
            focusMostRecentTerminal()
            return
        }
        acknowledgeAttention(for: primarySession)
        focusTerminal(for: primarySession)
    }

    func focusTerminal(for session: SessionActivity) {
        guard let bundleIdentifier = session.terminalBundleIdentifier else {
            focusMostRecentTerminal()
            return
        }
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        if let app = candidates.first {
            app.activate(options: [.activateAllWindows])
        } else {
            focusMostRecentTerminal()
        }
    }

    func acknowledgeAndFocus(_ session: SessionActivity) {
        acknowledgeAttention(for: session)
        focusTerminal(for: session)
    }

    /// Dismisses one row. This is deliberately not a synthesized provider `.cleared` event: the user
    /// tidying the queue is not the provider reporting a session ended, so it records nothing in
    /// Today. A cycle that already completed stays there, because it was archived on completion.
    func clear(_ session: SessionActivity) {
        let now = nowProvider()
        refreshDailyCoolness(now: now)
        expiryTasks.removeValue(forKey: session.key)?.cancel()
        publish(reducer.dismiss(source: session.source, sessionID: session.sessionID, at: now))
    }

    func clearAllSessions() {
        let now = nowProvider()
        refreshDailyCoolness(now: now)
        for task in expiryTasks.values { task.cancel() }
        expiryTasks.removeAll()
        publish(reducer.dismissAll(at: now))
    }

    func respond(to permission: AgentPermissionRequest, for session: SessionActivity, with decision: AgentPermissionDecision) {
        guard session.permission?.responseToken == permission.responseToken else { return }
        let response = AgentPermissionResponse(responseToken: permission.responseToken, decision: decision)
        guard (try? UnixDatagramClient.send(response)) != nil else { return }
        let change = reducer.markPermissionSubmitted(
            source: session.source,
            sessionID: session.sessionID,
            responseToken: permission.responseToken
        )
        publish(change)
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshNotificationStatus()
            }
        }
    }

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                self?.notificationAuthorizationStatus = settings.authorizationStatus
            }
        }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.notchbot.app") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func focusMostRecentTerminal() {
        let identifiers = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "dev.warp.Warp-Stable",
            "com.mitchellh.ghostty",
            "net.kovidgoyal.kitty",
        ]
        let applications = NSWorkspace.shared.runningApplications.filter {
            guard let identifier = $0.bundleIdentifier else { return false }
            return identifiers.contains(identifier)
        }
        applications.first?.activate(options: [.activateAllWindows])
    }

    private func sendNotification(for event: AgentEvent) {
        notifications.send(
            notificationIdentifier(for: event) ?? UUID().uuidString,
            event.source == .claude ? "Claude Code" : "OpenCode",
            event.reason ?? "Your agent is waiting for you."
        )
    }

    private func sendCostAlertNotification() {
        notifications.send(
            "notchbot.cost.alert",
            "NotchBot",
            String(format: "Today's agent spend has passed $%.2f", costAlert.threshold)
        )
    }

    private func notificationIdentifier(for event: AgentEvent) -> String? {
        event.request.map {
            [event.source.rawValue, event.sessionID, $0.kind.rawValue, $0.id].joined(separator: "\u{1f}")
        }
    }

    private func expireAttention(_ event: AgentEvent) {
        guard let duration = event.expiresAfter, duration.isFinite, (0...300).contains(duration) else { return }
        let sessionKey = key(for: event)
        if expiryTasks[sessionKey] == nil, expiryTasks.count >= ActivityReducer.maximumSessions,
           let oldestKey = expiryTasks.keys.first {
            expiryTasks.removeValue(forKey: oldestKey)?.cancel()
        }
        let nanoseconds = UInt64(duration * 1_000_000_000)
        expiryTasks[sessionKey] = Task { [weak self, sleep] in
            do {
                try await sleep(nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let change = reducer.expireAttention(
                source: event.source,
                sessionID: event.sessionID,
                unchangedSince: event.timestamp
            )
            expiryTasks.removeValue(forKey: sessionKey)
            publish(change)
        }
    }

    private func acknowledgeAttention(for session: SessionActivity) {
        let sessionKey = session.key
        expiryTasks.removeValue(forKey: sessionKey)?.cancel()
        let change = reducer.acknowledgeAttention(source: session.source, sessionID: session.sessionID)
        publish(change)
    }

    /// Internal rather than private so the stale-cleanup sweep can be driven directly in tests.
    func performMaintenance(now: Date? = nil) {
        let now = now ?? nowProvider()
        refreshDailyCoolness(now: now)
        reducer.removeSessions(olderThan: now.addingTimeInterval(-30 * 60))
        cancelOrphanedExpiryTasks()
        robotState = reducer.state
        primarySession = reducer.primarySession
        activeAgentCount = reducer.activeCount
        waitingAgentCount = reducer.attentionCount
        activeSessions = reducer.activities
    }

    private func refreshDailyCoolness(now: Date = Date()) {
        let currentDay = DailyCoolnessPreference.dayIdentifier(for: now, calendar: calendar)
        guard coolnessDay != currentDay else { return }
        coolnessDay = currentDay
        coolnessTracker.reset()
        dailyCompletionCount = 0
        DailyCoolnessPreference.save(
            completionCount: 0,
            to: defaults,
            now: now,
            calendar: calendar
        )
        costTracker.beginNewDay()
        costAlert.beginNewDay()
        dailyCostTotal = 0
        saveDailyCost(now: now)
        // Called before the reducer sees an event, so a session that started yesterday and finishes
        // after midnight lands in the day it completed rather than the one it began in.
        resetTimeline(day: currentDay)
    }

    private func saveDailyCost(now: Date) {
        DailyCostPreference.save(
            totalCost: costTracker.totalCost,
            sessionCosts: costTracker.sessionCosts,
            alertFired: costAlert.hasFired,
            to: defaults,
            now: now,
            calendar: calendar
        )
    }

    private func scheduleDailyReset(now: Date) {
        dailyResetTask?.cancel()
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else { return }
        let nanoseconds = UInt64(max(1, startOfTomorrow.timeIntervalSince(now)) * 1_000_000_000)
        dailyResetTask = Task { [weak self, sleep] in
            do {
                try await sleep(nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let resetAt = nowProvider()
            refreshDailyCoolness(now: resetAt)
            scheduleDailyReset(now: resetAt)
        }
    }

    /// Registered independently of background maintenance: this is a user-driven reset, not a timer.
    private func installCostTrackingObserver() {
        calendarObservers.append(NotificationCenter.default.addObserver(
            forName: .notchBotCostTrackingEnabled,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.costTrackingEnabled = true
            }
        })
        calendarObservers.append(NotificationCenter.default.addObserver(
            forName: .notchBotCostTrackingDisabled,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.costTrackingEnabled = false
                self.costTracker.beginNewDay()
                self.costAlert = DailyCostAlert()
                self.dailyCostTotal = 0
                self.dailyCostAlertThreshold = 0
                // Context percentages live only in the reducer, so republish to take the meters
                // off screen immediately instead of waiting for the rows to expire.
                self.reducer.clearContextWindowUsage()
                // Dropping live cost availability too, so a figure captured before the opt-out
                // cannot reach a timeline row written afterwards.
                self.publish(self.reducer.clearCostTracking())
                self.scrubTimelineCosts()
            }
        })
    }

    private func installIntegrationRemovalObserver() {
        calendarObservers.append(NotificationCenter.default.addObserver(
            forName: .notchBotIntegrationsRemoved,
            // Scoped to this model's defaults, matching the cost-tracking observers: the installer
            // that owns those defaults is the only one whose removal this model should react to.
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The installer has already deleted the file as part of its removal transaction.
                // Only the in-memory copy is dropped here; writing a fresh empty document would
                // recreate exactly the file the user asked to be removed.
                self.timeline = SessionTimelineDocument(
                    day: DailyCoolnessPreference.dayIdentifier(
                        for: self.nowProvider(),
                        calendar: self.calendar
                    )
                )
                self.completedSessionsToday = []
                self.timelineStorageError = nil
            }
        })
    }

    private func installDailyResetObservers() {
        let names: [Notification.Name] = [
            .NSCalendarDayChanged,
            .NSSystemClockDidChange,
            .NSSystemTimeZoneDidChange,
        ]
        calendarObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let now = self.nowProvider()
                    self.refreshDailyCoolness(now: now)
                    self.scheduleDailyReset(now: now)
                }
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = self.nowProvider()
                self.refreshDailyCoolness(now: now)
                self.scheduleDailyReset(now: now)
            }
        }
    }

    private func publish(_ change: ActivityChange) {
        cancelOrphanedExpiryTasks()
        robotState = change.state
        primarySession = change.primarySession
        activeAgentCount = reducer.activeCount
        waitingAgentCount = reducer.attentionCount
        activeSessions = reducer.activities
        record(change.completedSessions)
    }

    /// Upserts terminal snapshots by cycle ID, so the same cycle reported twice — a repeated
    /// completion attention, or a clear following a completion — updates one row instead of adding
    /// a second.
    private func record(_ completedSessions: [CompletedSession]) {
        guard !completedSessions.isEmpty else { return }
        var changed = false
        for session in completedSessions {
            if timeline.upsert(session) { changed = true }
        }
        guard changed else { return }
        completedSessionsToday = timeline.orderedGroups
        persistTimeline()
    }

    private func persistTimeline() {
        do {
            try timelineStore.save(timeline)
            timelineStorageError = nil
        } catch {
            timelineStorageError = error.localizedDescription
        }
    }

    /// Clears the timeline in memory and on disk for a new day. Shares `refreshDailyCoolness` with
    /// the completion count and the daily cost total so all three roll over on exactly one boundary.
    private func resetTimeline(day: String) {
        timeline = SessionTimelineDocument(day: day)
        completedSessionsToday = []
        do {
            try timelineStore.removeAll()
            timelineStorageError = nil
        } catch {
            timelineStorageError = error.localizedDescription
        }
    }

    /// Matches the clearing of daily cost state on opt-out: figures gathered while tracking was on
    /// leave the rows already in Today too, instead of lingering there until midnight.
    private func scrubTimelineCosts() {
        guard timeline.removeCosts() else { return }
        completedSessionsToday = timeline.orderedGroups
        persistTimeline()
    }

    private func key(for event: AgentEvent) -> SessionKey {
        SessionKey(event: event)
    }

    private func cancelOrphanedExpiryTasks() {
        let sessionIDs = Set(reducer.activities.map(\.key))
        for key in expiryTasks.keys where !sessionIDs.contains(key) {
            expiryTasks.removeValue(forKey: key)?.cancel()
        }
    }

    func shutdown() {
        maintenanceTask?.cancel()
        maintenanceTask = nil
        dailyResetTask?.cancel()
        dailyResetTask = nil
        for task in expiryTasks.values { task.cancel() }
        expiryTasks.removeAll()
        for observer in calendarObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        calendarObservers.removeAll()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }
}
