import AppKit
import NotchBotCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = ActivityModel()
    let integrations = IntegrationInstaller()
    private let eventServer = EventServer()
    private var panelController: NotchPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.requestNotificationPermission()
        panelController = NotchPanelController(model: model)
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
            NotchBotMenu(model: appDelegate.model, integrations: appDelegate.integrations)
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
    @ObservedObject var integrations: IntegrationInstaller

    var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("NotchBot")
                    .font(.headline)
                Text(statusText)
                    .foregroundStyle(.secondary)
                Divider()
                Text(integrations.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Install Integrations") { integrations.install() }
                Button("Remove Integrations") { integrations.uninstall() }
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
}
