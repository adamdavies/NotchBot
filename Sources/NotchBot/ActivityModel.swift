import AppKit
import Combine
import Foundation
import NotchBotCore
import UserNotifications

extension Notification.Name {
    static let notchBotCostTrackingDisabled = Notification.Name("NotchBotCostTrackingDisabled")
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
    @Published private(set) var activeSessions: [SessionActivity] = []
    @Published private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined

    private var reducer = ActivityReducer()
    private var coolnessTracker: DailyCoolnessTracker
    private var costTracker: DailyCostTracker
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
        enableBackgroundMaintenance: Bool = true
    ) {
        let initialNow = now ?? nowProvider()
        self.defaults = defaults
        self.calendar = calendar
        self.nowProvider = nowProvider
        self.sleep = sleep
        self.notifications = notifications
        coolnessDay = DailyCoolnessPreference.dayIdentifier(for: initialNow, calendar: calendar)
        let savedCount = DailyCoolnessPreference.load(from: defaults, now: initialNow, calendar: calendar)
        dailyCompletionCount = savedCount
        coolnessTracker = DailyCoolnessTracker(completionCount: savedCount)
        let savedCost = DailyCostPreference.load(from: defaults, now: initialNow, calendar: calendar)
        dailyCostTotal = savedCost.totalCost
        costTracker = DailyCostTracker(totalCost: savedCost.totalCost, sessionCosts: savedCost.sessionCosts)
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
        guard coolnessTier != .crown else { return "Max level" }
        return "\(Int((queueCoolnessProgress * 100).rounded()))% to next"
    }

    var dailyCostDisplayText: String {
        String(format: "~$%.2f today", dailyCostTotal)
    }

    func receive(_ event: AgentEvent) {
        let now = nowProvider()
        refreshDailyCoolness(now: now)
        guard (try? AgentEventValidator.validate(event, now: now)) != nil else { return }
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
        if costTracker.apply(event) {
            dailyCostTotal = costTracker.totalCost
            DailyCostPreference.save(
                totalCost: costTracker.totalCost,
                sessionCosts: costTracker.sessionCosts,
                to: defaults,
                now: now,
                calendar: calendar
            )
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

    func clear(_ session: SessionActivity) {
        receive(AgentEvent(
            source: session.source,
            kind: .cleared,
            sessionID: session.sessionID,
            timestamp: nowProvider()
        ))
    }

    func clearAllSessions() {
        let sessions = activeSessions
        let timestamp = nowProvider()
        for session in sessions {
            receive(AgentEvent(
                source: session.source,
                kind: .cleared,
                sessionID: session.sessionID,
                timestamp: timestamp
            ))
        }
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
        let sessionKey = session.id
        expiryTasks.removeValue(forKey: sessionKey)?.cancel()
        let change = reducer.acknowledgeAttention(source: session.source, sessionID: session.sessionID)
        publish(change)
    }

    private func performMaintenance(now: Date? = nil) {
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
        dailyCostTotal = 0
        DailyCostPreference.save(
            totalCost: 0,
            sessionCosts: costTracker.sessionCosts,
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
        calendarObservers.append(NotificationCenter.default.addObserver(
            forName: .notchBotCostTrackingDisabled,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.costTracker.reset()
                self?.dailyCostTotal = 0
            }
        })
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
    }

    private func key(for event: AgentEvent) -> SessionKey {
        SessionKey(event: event)
    }

    private func cancelOrphanedExpiryTasks() {
        let sessionIDs = Set(reducer.activities.map(\.id))
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
