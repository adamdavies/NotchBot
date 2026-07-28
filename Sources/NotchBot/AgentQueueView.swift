import NotchBotCore
import SwiftUI

struct AgentQueueView: View {
    @ObservedObject var model: ActivityModel
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bots")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text(queueSummary)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .frame(height: 42)

            Divider().overlay(.white.opacity(0.09))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.activeSessions.enumerated()), id: \.element.id) { index, session in
                        AgentQueueRow(session: session) { permission, decision in
                            model.respond(to: permission, for: session, with: decision)
                        }
                        .frame(height: rowHeight(for: session))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.acknowledgeAndFocus(session)
                        }

                        if index < model.activeSessions.count - 1 {
                            Divider()
                                .overlay(.white.opacity(0.06))
                                .padding(.leading, model.activeSessions[index + 1].isSubagent ? 54 : 36)
                        }
                    }
                }
            }
        }
        .frame(width: 380, height: queueHeight)
        .background(cardBackground)
        .contentShape(Rectangle())
        .onHover(perform: onHoverChanged)
    }

    private var cardBackground: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 4,
            bottomLeadingRadius: 14,
            bottomTrailingRadius: 14,
            topTrailingRadius: 4
        )
        .fill(Color.black.opacity(0.96))
        .overlay {
            UnevenRoundedRectangle(
                topLeadingRadius: 4,
                bottomLeadingRadius: 14,
                bottomTrailingRadius: 14,
                topTrailingRadius: 4
            )
            .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var queueSummary: String {
        let idleCount = model.activeSessions.filter { $0.state == .idle }.count
        if model.waitingAgentCount > 0 {
            return "\(model.activeAgentCount) active · \(model.waitingAgentCount) need you"
        }
        return "\(model.activeAgentCount) active · \(idleCount) idle"
    }

    private var queueHeight: CGFloat {
        42 + model.activeSessions.prefix(5).reduce(0) { $0 + rowHeight(for: $1) + 1 }
    }

    private func rowHeight(for session: SessionActivity) -> CGFloat {
        guard let permission = session.permission else { return 57 }
        return permission.context == nil ? 106 : 126
    }
}

private struct AgentQueueRow: View {
    let session: SessionActivity
    let onPermissionDecision: (AgentPermissionRequest, AgentPermissionDecision) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if session.isSubagent {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(width: 10)
            }

            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(sourceName)
                    if let projectName {
                        Text("·")
                        Text(projectName)
                    }
                    if session.state == .attention, let reason = session.reason {
                        Text("·")
                        Text(reason)
                    }
                }
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)

                if let permission = session.permission {
                    Text(permission.summary)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let context = permission.context {
                        Text(context)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }

                    HStack(spacing: 6) {
                        permissionButton("Allow Once", decision: .allowOnce, permission: permission)
                        if permission.canAlwaysAllow {
                            permissionButton("Always", decision: .alwaysAllow, permission: permission)
                        }
                        permissionButton("Decline", decision: .decline, permission: permission, destructive: true)
                    }
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 8)

            if session.permission == nil {
                Text(statusText)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(statusColor)
            }
        }
        .padding(.horizontal, 14)
    }

    private func permissionButton(
        _ title: String,
        decision: AgentPermissionDecision,
        permission: AgentPermissionRequest,
        destructive: Bool = false
    ) -> some View {
        Button(title) {
            onPermissionDecision(permission, decision)
        }
        .buttonStyle(.plain)
        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
        .foregroundStyle(destructive ? Color.red.opacity(0.9) : Color.white.opacity(0.9))
        .padding(.horizontal, 8)
        .frame(height: 23)
        .background(
            Capsule().fill(destructive ? Color.red.opacity(0.14) : Color.white.opacity(0.11))
        )
        .overlay {
            Capsule().stroke(destructive ? Color.red.opacity(0.3) : Color.white.opacity(0.15), lineWidth: 1)
        }
    }

    private var title: String {
        session.taskLabel ?? projectName ?? sourceName
    }

    private var projectName: String? {
        session.workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private var sourceName: String {
        session.source == .claude ? "Claude Code" : "OpenCode"
    }

    private var statusColor: Color {
        switch session.state {
        case .attention: .yellow
        case .working: Color(red: 0.34, green: 0.72, blue: 1)
        case .idle: .white.opacity(0.28)
        }
    }

    private var statusText: String {
        switch session.state {
        case .attention: "Needs you"
        case .working: "Working"
        case .idle: "Idle"
        }
    }
}
