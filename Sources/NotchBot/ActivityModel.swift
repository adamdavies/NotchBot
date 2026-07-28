import AppKit
import Combine
import Foundation
import NotchBotCore
import UserNotifications

@MainActor
final class ActivityModel: ObservableObject {
    @Published private(set) var robotState: RobotState = .idle
    @Published private(set) var primarySession: SessionActivity?
    @Published private(set) var attentionSequence = 0
    @Published private(set) var activeAgentCount = 0
    @Published private(set) var waitingAgentCount = 0
    @Published private(set) var latestSummary: LatestAgentSummary?
    @Published private(set) var previewState: RobotState?
    @Published private(set) var activeSessions: [SessionActivity] = []
    @Published private(set) var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined

    private var reducer = ActivityReducer()
    private var summaryStore = AgentSummaryStore()
    private var previewTask: Task<Void, Never>?
    private var expiryTasks: [String: Task<Void, Never>] = [:]
    private var maintenanceTask: Task<Void, Never>?
    private var responseExcerptsEnabled = false

    init() {
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                self?.performMaintenance()
            }
        }
    }

    deinit {
        maintenanceTask?.cancel()
        previewTask?.cancel()
        for task in expiryTasks.values {
            task.cancel()
        }
    }

    var displayedRobotState: RobotState {
        previewState ?? robotState
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
        previewState != nil
    }

    func receive(_ event: AgentEvent) {
        guard (try? AgentEventValidator.validate(event)) != nil, reducer.canApply(event) else { return }
        let sessionKey = key(for: event)
        if event.kind != .metadata {
            expiryTasks.removeValue(forKey: sessionKey)?.cancel()
        }
        let change = reducer.apply(event)
        publish(change)

        if responseExcerptsEnabled, event.summary != nil {
            latestSummary = summaryStore.apply(event)
        }

        if change.shouldNotify {
            attentionSequence += 1
            sendNotification(for: event)
        }
        if event.kind == .attention, event.expiresAfter != nil {
            expireAttention(event)
        }
    }

    func preview(_ state: RobotState) {
        if previewState == state {
            cancelPreview()
            return
        }

        previewTask?.cancel()
        previewState = state
        previewTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                return
            }
            self?.cancelPreview()
        }
    }

    func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewState = nil
    }

    func clearSummary() {
        summaryStore = AgentSummaryStore()
        latestSummary = nil
    }

    func setResponseExcerptsEnabled(_ enabled: Bool) {
        responseExcerptsEnabled = enabled
        if !enabled {
            clearSummary()
        }
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
        let content = UNMutableNotificationContent()
        content.title = event.source == .claude ? "Claude Code" : "OpenCode"
        content.body = event.reason ?? "Your agent is waiting for you."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func expireAttention(_ event: AgentEvent) {
        guard let duration = event.expiresAfter, duration.isFinite, (0...300).contains(duration) else { return }
        let sessionKey = key(for: event)
        if expiryTasks[sessionKey] == nil, expiryTasks.count >= ActivityReducer.maximumSessions,
           let oldestKey = expiryTasks.keys.first {
            expiryTasks.removeValue(forKey: oldestKey)?.cancel()
        }
        let nanoseconds = UInt64(duration * 1_000_000_000)
        expiryTasks[sessionKey] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
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
        guard session.state == .attention else { return }
        let sessionKey = session.id
        expiryTasks.removeValue(forKey: sessionKey)?.cancel()
        let change = reducer.acknowledgeAttention(source: session.source, sessionID: session.sessionID)
        publish(change)
    }

    private func performMaintenance(now: Date = Date()) {
        reducer.removeSessions(olderThan: now.addingTimeInterval(-30 * 60))
        latestSummary = summaryStore.removeLatest(olderThan: now.addingTimeInterval(-15 * 60))
        robotState = reducer.state
        primarySession = reducer.primarySession
        activeAgentCount = reducer.activeCount
        waitingAgentCount = reducer.attentionCount
        activeSessions = reducer.activities
    }

    private func publish(_ change: ActivityChange) {
        robotState = change.state
        primarySession = change.primarySession
        activeAgentCount = reducer.activeCount
        waitingAgentCount = reducer.attentionCount
        activeSessions = reducer.activities
    }

    private func key(for event: AgentEvent) -> String {
        "\(event.source.rawValue):\(event.sessionID)"
    }
}
