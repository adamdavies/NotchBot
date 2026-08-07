import NotchBotCore
import SwiftUI

struct AgentQueueView: View {
    @ObservedObject var model: ActivityModel
    @ObservedObject var navigation: PanelNavigationModel
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Bots")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                Spacer()
                Text(queueSummary)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                Button("Clear All") {
                    model.clearAllSessions()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.09)))
                .help("Clear all queue entries")
            }
            .padding(.horizontal, 18)
            .frame(height: 42)

            Divider().overlay(.white.opacity(0.07))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.activeSessions.enumerated()), id: \.element.id) { index, session in
                        AgentQueueRow(
                            session: session,
                            onClear: { model.clear(session) },
                            onPermissionDecision: { permission, decision in
                                model.respond(to: permission, for: session, with: decision)
                            }
                        )
                        .frame(height: rowHeight(for: session))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.acknowledgeAndFocus(session)
                        }

                        if index < model.activeSessions.count - 1 {
                            Divider()
                                .overlay(.white.opacity(0.05))
                                .padding(.leading, model.activeSessions[index + 1].isSubagent ? 54 : 36)
                        }
                    }
                }
            }

            QueueProgressFooter(model: model, navigation: navigation)
        }
        .frame(width: 420, height: queueHeight)
        .background(cardBackground)
        .contentShape(Rectangle())
        .onHover(perform: onHoverChanged)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 22)
            .fill(Color(red: 0.06, green: 0.06, blue: 0.067).opacity(0.94))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.45), radius: 25, y: 20)
    }

    private var queueSummary: String {
        let idleCount = model.activeSessions.filter { $0.state == .idle }.count
        if model.waitingAgentCount > 0 {
            return "\(model.activeAgentCount) running · \(model.waitingAgentCount) need you"
        }
        return "\(model.activeAgentCount) running · \(idleCount) idle"
    }

    private var queueHeight: CGFloat {
        42 + model.activeSessions.prefix(5).reduce(0) { $0 + rowHeight(for: $1) + 1 }
            + QueueProgressFooter.height
    }

    private func rowHeight(for session: SessionActivity) -> CGFloat {
        let activityHeight: CGFloat = session.activityDescription == nil ? 0 : 20
        // Reserved only when the meter is actually drawn, so rows below the threshold keep their
        // current height and the panel does not grow for sessions with plenty of context left.
        let meterHeight: CGFloat = ContextMeter.isVisible(session.contextUsedPercentage)
            ? ContextMeter.addedRowHeight : 0
        guard let permission = session.permission else { return 70 + activityHeight + meterHeight }
        return (permission.context == nil ? 120 : 150) + activityHeight + meterHeight
    }
}

/// Presentation rules for the per-row context-window meter.
///
/// The meter stays hidden below `visibilityThreshold`. A near-empty bar on every idle row would
/// cost vertical space in a panel that shows five rows at a time to say nothing actionable, so the
/// meter appears only once context is worth watching. Geometry and colours follow
/// `Design/NotchBot Panel.dc.html`; the strong-warning band is derived, as noted in `Design/README.md`.
enum ContextMeter {
    static let visibilityThreshold: Double = 50
    static let warningThreshold: Double = 75
    static let strongWarningThreshold: Double = 90

    /// 6pt VStack spacing + 2pt top inset + 11pt content.
    static let addedRowHeight: CGFloat = 19
    static let barHeight: CGFloat = 3
    static let contentHeight: CGFloat = 11

    static func isVisible(_ percentage: Double?) -> Bool {
        guard let percentage, percentage.isFinite else { return false }
        return percentage >= visibilityThreshold
    }

    static func tint(for percentage: Double) -> Color {
        if percentage >= strongWarningThreshold {
            return Color(red: 0.885, green: 0.285, blue: 0.280)
        }
        if percentage >= warningThreshold {
            return Color(red: 0.958, green: 0.499, blue: 0.276)
        }
        return Color(red: 0.298, green: 0.620, blue: 0.637)
    }

    /// The bar uses the unrounded value; only the text rounds, so a 74.6 reading cannot show "75%"
    /// next to a fill that is still in the neutral band.
    static func fillFraction(for percentage: Double) -> Double {
        min(1, max(0, percentage / 100))
    }

    static func label(for percentage: Double) -> String {
        "\(Int(percentage.rounded()))% ctx"
    }

    static func accessibilityValue(for percentage: Double) -> String {
        "\(Int(percentage.rounded()))% context used"
    }
}

private struct ContextMeterView: View {
    let percentage: Double

    var body: some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(Color.white.opacity(0.08))
                .frame(height: ContextMeter.barHeight)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(ContextMeter.tint(for: percentage))
                            .frame(width: proxy.size.width * ContextMeter.fillFraction(for: percentage))
                    }
                }
            Text(ContextMeter.label(for: percentage))
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
                .fixedSize()
        }
        .frame(height: ContextMeter.contentHeight)
        .padding(.top, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context window")
        .accessibilityValue(ContextMeter.accessibilityValue(for: percentage))
        .help(ContextMeter.accessibilityValue(for: percentage))
    }
}

private struct AgentQueueRow: View {
    let session: SessionActivity
    let onClear: () -> Void
    let onPermissionDecision: (AgentPermissionRequest, AgentPermissionDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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

                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if session.permission == nil {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(statusText)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.white.opacity(0.38))
                        if !session.isSubagent, let cost = session.costUSD, cost > 0 {
                            Text(String(format: "~$%.2f", cost))
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(.white.opacity(0.28))
                        }
                    }
                }

                Button(action: onClear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
                .accessibilityLabel("Clear \(title) from queue")
                .help("Clear this queue entry")
            }

            if let activityDescription = session.activityDescription {
                Text(activityDescription)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, session.isSubagent ? 28 : 18)
                    .accessibilityLabel("Current activity: \(activityDescription)")
            }

            HStack(spacing: 5) {
                Text(sourceName)
                if let projectName {
                    Text("·")
                    Text(projectName)
                }
                if (session.state == .attention || session.isAwaitingPermissionResolution), let reason = session.reason {
                    Text("·")
                    Text(session.state == .attention && session.permission == nil
                         && reason.localizedCaseInsensitiveContains("permission")
                         ? "Needs your attention" : reason)
                }
                if session.pendingRequestCount > 1 {
                    Text("·")
                    Text("\(session.pendingRequestCount) requests")
                }
            }
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            .padding(.leading, session.isSubagent ? 28 : 18)

            if let percentage = session.contextUsedPercentage, ContextMeter.isVisible(percentage) {
                ContextMeterView(percentage: percentage)
                    .padding(.leading, session.isSubagent ? 28 : 18)
            }

            if let permission = session.permission {
                Text(permission.summary)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, session.isSubagent ? 28 : 18)

                if let context = permission.context {
                    Text(context)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .padding(.leading, session.isSubagent ? 28 : 18)
                }

                HStack(spacing: 8) {
                    permissionButton("Allow Once", decision: .allowOnce, permission: permission, primary: true)
                    if permission.canAlwaysAllow {
                        permissionButton("Always", decision: .alwaysAllow, permission: permission)
                    }
                    permissionButton("Decline", decision: .decline, permission: permission, destructive: true)
                }
                .padding(.leading, session.isSubagent ? 28 : 18)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func permissionButton(
        _ title: String,
        decision: AgentPermissionDecision,
        permission: AgentPermissionRequest,
        primary: Bool = false,
        destructive: Bool = false
    ) -> some View {
        Button(title) {
            onPermissionDecision(permission, decision)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .foregroundStyle(destructive ? Color.red.opacity(0.9) : Color.white.opacity(0.9))
        .padding(.horizontal, 12)
        .frame(height: 25)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(
                primary ? Color(red: 0.22, green: 0.55, blue: 0.38)
                : destructive ? Color.red.opacity(0.14)
                : Color.white.opacity(0.08)
            )
        )
    }

    private var title: String {
        session.sessionTitle ?? projectName ?? sourceName
    }

    private var projectName: String? {
        session.workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private var sourceName: String {
        session.source == .claude ? "Claude Code" : "OpenCode"
    }

    private var statusColor: Color {
        return switch session.state {
        case .attention: Color(red: 0.82, green: 0.65, blue: 0.28)
        case .working: Color(red: 0.28, green: 0.52, blue: 0.82)
        case .idle: Color(red: 0.32, green: 0.68, blue: 0.48)
        }
    }

    private var statusText: String {
        if session.state == .idle, session.isAwaitingPermissionResolution {
            return "Attending"
        }
        return switch session.state {
        case .attention: "Needs you"
        case .working: "Working"
        case .idle: "Idle"
        }
    }
}
