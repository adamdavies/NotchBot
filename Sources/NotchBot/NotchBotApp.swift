import AppKit
import NotchBotCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = ActivityModel()
    let appearance = AppearanceModel()
    let displaySelection = DisplaySelectionModel()
    let integrations = IntegrationInstaller()
    private let eventServer = EventServer()
    private var panelController: NotchPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.refreshNotificationStatus()
        panelController = NotchPanelController(
            model: model,
            appearance: appearance,
            displaySelection: displaySelection
        )
        panelController?.show()

        do {
            try eventServer.start { [weak self] data in
                guard let event = try? JSONDecoder().decode(AgentEvent.self, from: data) else { return }
                Task { @MainActor in
                    self?.model.receive(event)
                }
            }
        } catch {
            NSLog("NotchBot event server failed to start: \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventServer.stop()
    }
}

@main
struct NotchBotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            NotchBotMenu(
                model: appDelegate.model,
                appearance: appDelegate.appearance,
                displaySelection: appDelegate.displaySelection,
                integrations: appDelegate.integrations
            )
        } label: {
            Image(nsImage: RobotAtlas.shared.menuBarIcon)
                .renderingMode(.template)
                .interpolation(.none)
                .frame(width: 18, height: 18)
        }
    }
}

private struct NotchBotMenu: View {
    @ObservedObject var model: ActivityModel
    @ObservedObject var appearance: AppearanceModel
    @ObservedObject var displaySelection: DisplaySelectionModel
    @ObservedObject var integrations: IntegrationInstaller

    var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("NotchBot")
                    .font(.headline)
                Text(statusText)
                    .foregroundStyle(.secondary)
                Text("Today: \(model.coolnessStatusText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Picker("Character", selection: $appearance.character) {
                    ForEach(NotchCharacter.allCases) { character in
                        Text(character.displayName).tag(character)
                    }
                }
                Picker("Display", selection: $displaySelection.selection) {
                    Text("Automatic").tag(DisplaySelection.automatic)
                    Text("All Displays").tag(DisplaySelection.all)
                    ForEach(displaySelection.options) { display in
                        Text(display.name).tag(DisplaySelection.display(display.id))
                    }
                    if displaySelection.hasUnavailableSelection {
                        Text("Unavailable Display").tag(displaySelection.selection)
                    }
                }
                Divider()
                Text(integrations.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if integrations.requiresUpdate {
                    Button("Update Integrations") { integrations.updateIntegrations() }
                } else {
                    Button("Install Integrations") { integrations.install() }
                }
                Button("Remove Integrations") {
                    integrations.uninstall()
                }
                notificationButton
                Button(integrations.costTrackingEnabled
                    ? "Disable Cost Tracking"
                    : "Enable Cost Tracking"
                ) {
                    if integrations.costTrackingEnabled {
                        integrations.disableCostTracking()
                    } else {
                        confirmCostTracking()
                    }
                }
                Button(integrations.launchesAtLogin ? "Disable Launch at Login" : "Enable Launch at Login") {
                    integrations.toggleLaunchAtLogin()
                }
                Divider()
                Menu("Debug") {
                    Menu("State Preview") {
                        debugOption("Live", selected: model.previewState == nil) {
                            model.setPreviewState(nil)
                        }
                        debugOption("Idle", selected: model.previewState == .idle) {
                            model.setPreviewState(.idle)
                        }
                        debugOption("Working", selected: model.previewState == .working) {
                            model.setPreviewState(.working)
                        }
                        debugOption("Needs Input", selected: model.previewState == .attention) {
                            model.setPreviewState(.attention)
                        }
                    }
                    Menu("Coolness Tier") {
                        debugOption("Live", selected: model.previewCoolnessTier == nil) {
                            model.setPreviewCoolnessTier(nil)
                        }
                        ForEach(CoolnessTier.allCases) { tier in
                            debugOption(tier.displayName, selected: model.previewCoolnessTier == tier) {
                                model.setPreviewCoolnessTier(tier)
                            }
                        }
                    }
                    if model.isPreviewing {
                        Divider()
                        Button("Stop Debug Preview") { model.cancelPreview() }
                    }
                }
                Divider()
                Button("Quit NotchBot") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(8)
    }

    private func confirmCostTracking() {
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Enable estimated cost tracking?"
            alert.informativeText = "NotchBot will collect estimated session costs from OpenCode and wrap your Claude Code status line command to read its session cost estimate. Your existing status line configuration (if any) will continue to work and will be restored when tracking is disabled.\n\nCost estimates are based on provider pricing and may not reflect enterprise discounts or subscription allowances."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Enable")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                integrations.enableCostTracking()
            }
        }
    }

    private var statusText: String {
        if model.isPreviewing {
            let state = model.previewState.map(stateName) ?? "Live State"
            let tier = model.previewCoolnessTier?.displayName ?? "Live Tier"
            return "Debug: \(state) · \(tier)"
        }
        return switch model.robotState {
        case .idle: "No active agents"
        case .working: "An agent is working"
        case .attention: "An agent needs attention"
        }
    }

    private func stateName(_ state: RobotState) -> String {
        switch state {
        case .idle: "Idle"
        case .working: "Working"
        case .attention: "Needs Input"
        }
    }

    @ViewBuilder
    private func debugOption(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    @ViewBuilder
    private var notificationButton: some View {
        switch model.notificationAuthorizationStatus {
        case .notDetermined:
            Button("Enable Notifications") { model.requestNotificationPermission() }
        case .denied:
            Button("Open Notification Settings") { model.openNotificationSettings() }
        case .authorized, .provisional, .ephemeral:
            Text("Notifications enabled")
                .font(.caption)
                .foregroundStyle(.secondary)
        @unknown default:
            EmptyView()
        }
    }
}
