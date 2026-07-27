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

    private var reducer = ActivityReducer()
    private var summaryStore = AgentSummaryStore()
    private var previewTask: Task<Void, Never>?

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
        let change = reducer.apply(event)
        robotState = change.state
        primarySession = change.primarySession
        activeAgentCount = reducer.sessionCount
        waitingAgentCount = reducer.attentionCount

        if event.summary != nil {
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

    func focusPrimaryTerminal() {
        guard let bundleIdentifier = primarySession?.terminalBundleIdentifier else {
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

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
            identifier: "\(event.source.rawValue)-\(event.sessionID)-\(event.timestamp.timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func expireAttention(_ event: AgentEvent) {
        Task { [weak self] in
            let duration = max(0, event.expiresAfter ?? 0)
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self else { return }
            let change = reducer.expireAttention(
                source: event.source,
                sessionID: event.sessionID,
                unchangedSince: event.timestamp
            )
            robotState = change.state
            primarySession = change.primarySession
            activeAgentCount = reducer.sessionCount
            waitingAgentCount = reducer.attentionCount
        }
    }
}
