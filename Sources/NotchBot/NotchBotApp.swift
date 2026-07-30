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
        model.setResponseExcerptsEnabled(integrations.assistantExcerptsEnabled)
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
                    model.clearSummary()
                }
                Toggle(
                    "Include Response Excerpts",
                    isOn: Binding(
                        get: { integrations.assistantExcerptsEnabled },
                        set: { enabled in
                            integrations.setAssistantExcerptsEnabled(enabled)
                            model.setResponseExcerptsEnabled(integrations.assistantExcerptsEnabled)
                        }
                    )
                )
                Text("Off by default. Running agent sessions may need restarting after changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                notificationButton
                Button(integrations.launchesAtLogin ? "Disable Launch at Login" : "Enable Launch at Login") {
                    integrations.toggleLaunchAtLogin()
                }
                Divider()
                Button("Preview Idle") { model.preview(.idle) }
                Button("Preview Working") { model.preview(.working) }
                Button("Preview Attention") { model.preview(.attention) }
                if model.isPreviewing {
                    Button("Stop Preview") { model.cancelPreview() }
                }
                Divider()
                Button("Quit NotchBot") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(8)
    }

    private var statusText: String {
        if model.isPreviewing {
            return "Previewing \(model.displayedRobotState.rawValue)"
        }
        return switch model.robotState {
        case .idle: "No active agents"
        case .working: "An agent is working"
        case .attention: "An agent needs attention"
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
